require "test_helper"

# Régie : « la liste des inscrits et s'ils sont présents ou non ».
class RoomAttendanceTest < ActiveSupport::TestCase
  setup do
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.ago, host_sub: "sub-marc")
    @alice = @webinar.registrations.create!(name: "Alice", email: "alice@example.test", confirmed_at: 1.day.ago)
    @bruno = @webinar.registrations.create!(name: "Bruno", email: "bruno@example.test", confirmed_at: 1.day.ago,
                                            participation: "participant")
    @chloe = @webinar.registrations.create!(name: "chloé", email: "chloe@example.test", confirmed_at: 1.day.ago)
    @denis = @webinar.registrations.create!(name: "Denis", email: "denis@example.test")
    @bruno_speaker = @webinar.speakers.create!(name: "Bruno", registration: @bruno)
  end

  def snapshot(*identities, room: "open")
    { room: room, participants: identities.map { |identity| { identity: identity } } }
  end

  def statuses(result)
    result[:registrations].to_h { |item| [ item[:name], item[:status] ] }
  end

  test "présent en spectateur comme en intervenant rattaché, venu puis parti, absent ; présents d'abord" do
    @chloe.update!(room_joined_at: 10.minutes.ago)

    result = RoomAttendance.new(@webinar, snapshot: snapshot("viewer-#{@alice.id}", "speaker-#{@bruno_speaker.id}", "host-sub-marc")).call

    assert_equal "open", result[:room]
    assert_equal({ "Alice" => "present", "Bruno" => "present", "chloé" => "left", "Denis" => "absent" }, statuses(result))
    assert_equal %w[Alice Bruno chloé Denis], result[:registrations].map { |item| item[:name] }
    assert_equal [ 4, 2, 3 ], result.values_at(:registered, :present, :came)
    denis = result[:registrations].last
    assert_equal false, denis[:confirmed]
    assert_equal "participant", result[:registrations].second[:participation]
  end

  test "un inscrit vu dans la salle est noté venu, et sa première arrivée n'est jamais réécrite" do
    first = 30.minutes.ago.change(usec: 0)
    @bruno.update!(room_joined_at: first)

    RoomAttendance.new(@webinar, snapshot: snapshot("viewer-#{@alice.id}", "speaker-#{@bruno_speaker.id}")).call

    assert_not_nil @alice.reload.room_joined_at
    assert_equal first, @bruno.reload.room_joined_at
    assert_nil @chloe.reload.room_joined_at

    result = RoomAttendance.new(@webinar, snapshot: snapshot).call
    assert_equal "left", statuses(result)["Alice"]
  end

  test "identités d'un autre webinaire, intervenant sans inscription, inconnues : personne n'est présent" do
    other = Webinar.create!(title: "Autre", starts_at: 1.hour.ago, host_sub: "sub-eve")
    foreign = other.registrations.create!(name: "Eve", email: "eve@example.test", confirmed_at: 1.day.ago)
    unregistered = @webinar.speakers.create!(name: "Invité")

    result = RoomAttendance.new(@webinar, snapshot: snapshot("viewer-#{foreign.id}", "speaker-#{unregistered.id}",
                                                             "viewer-0", "viewer-abc", "speaker-legacy-x")).call

    assert_equal 0, result[:present]
    assert_nil foreign.reload.room_joined_at
  end

  test "intervenant révoqué encore dans la salle : ni présent ni noté venu" do
    @bruno_speaker.revoke!

    result = RoomAttendance.new(@webinar, snapshot: snapshot("speaker-#{@bruno_speaker.id}")).call

    assert_equal "absent", statuses(result)["Bruno"]
    assert_nil @bruno.reload.room_joined_at
  end

  test "salle fermée (LiveKit ne la connaît pas) : personne de présent, venus conservés" do
    @alice.update!(room_joined_at: 1.hour.ago)

    result = RoomAttendance.new(@webinar, snapshot: { room: "closed", participants: [] }).call

    assert_equal [ 0, 1 ], result.values_at(:present, :came)
  end

  test "tri par nom sans accents : Élodie parmi les E" do
    @webinar.registrations.create!(name: "Élodie", email: "elodie@example.test", confirmed_at: 1.day.ago)

    names = RoomAttendance.new(@webinar, snapshot: snapshot).call[:registrations].map { |item| item[:name] }

    assert_equal %w[Alice Bruno chloé Denis Élodie], names
  end

  test "rien à noter : aucune écriture à la relecture" do
    @alice.update!(room_joined_at: 1.hour.ago)
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      RoomAttendance.new(@webinar, snapshot: snapshot("viewer-#{@alice.id}")).call
    end

    assert queries.none? { |sql| sql.match?(/\AUPDATE/i) }, queries.grep(/UPDATE/i).inspect
  end

  test "salle illisible : personne n'est dit présent, les venus restent connus" do
    @alice.update!(room_joined_at: 5.minutes.ago)

    result = RoomAttendance.new(@webinar, snapshot: snapshot("viewer-#{@bruno.id}", room: "unavailable")).call

    assert_equal "unavailable", result[:room]
    assert_equal({ "Alice" => "left", "Bruno" => "absent", "chloé" => "absent", "Denis" => "absent" }, statuses(result))
    assert_nil @bruno.reload.room_joined_at
  end

  test "une inscription effacée (pierre tombale) n'est pas listée" do
    @denis.update_columns(retired_email_digest: "digest")

    result = RoomAttendance.new(@webinar, snapshot: snapshot).call

    assert_not_includes result[:registrations].map { |item| item[:name] }, "Denis"
    assert_equal 3, result[:registered]
  end

  test "note_arrival : webhook participant_joined, spectateur ou intervenant rattaché" do
    RoomAttendance.note_arrival(@webinar, "viewer-#{@alice.id}")
    RoomAttendance.note_arrival(@webinar, "speaker-#{@bruno_speaker.id}")
    RoomAttendance.note_arrival(@webinar, "host-sub-marc")

    assert_not_nil @alice.reload.room_joined_at
    assert_not_nil @bruno.reload.room_joined_at
    assert_nil @chloe.reload.room_joined_at
  end

  test "première arrivée : une arrivée plus ancienne (journal LiveKit rejoué) remplace, une plus récente jamais" do
    first = 2.hours.ago.change(usec: 0)
    @alice.update!(room_joined_at: 1.hour.ago.change(usec: 0))

    RoomAttendance.note_arrival(@webinar, "viewer-#{@alice.id}", at: first)
    RoomAttendance.note_arrival(@webinar, "viewer-#{@alice.id}", at: 10.minutes.ago)

    assert_equal first, @alice.reload.room_joined_at
  end
end
