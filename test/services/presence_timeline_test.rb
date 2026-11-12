require "test_helper"

# « Voir qui s'est connecté quand… une espèce de courbe de présence… est-ce
# que les gens ont essayé de se connecter ou pas » — sur le déroulé d'un
# direct réel (heures du journal LiveKit, noms inventés).
class PresenceTimelineTest < ActiveSupport::TestCase
  setup do
    @host = User.create!(email: "luc@example.test", oidc_sub: "sub-luc")
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: at("9:30"), host_sub: @host.oidc_sub)
    @webinar.update!(state: "ended", started_at: at("9:32"), ended_at: at("10:51"))
    @alice = registration("Alice")              # spectatrice, puis intervenante (lien privé)
    @bruno = registration("Bruno")              # reconnexions difficiles
    @chloe = registration("Chloé")              # spectatrice tout du long
    @denis = registration("Denis")              # a ouvert la page, jamais entré
    @elise = registration("Élise")              # jamais venue
    @fanny = registration("Fanny", confirmed: false)
    @alice_speaker = @webinar.speakers.create!(name: "Alice", registration: @alice)
    @guest = @webinar.speakers.create!(name: "Invité")

    host = "host-sub-luc"
    alice = "viewer-#{@alice.id}"
    log [ "9:30:08", "joined", host ],
        [ "9:32:54", "joined", alice ], [ "9:33:04", "left", alice ], [ "9:33:04", "joined", alice ],
        [ "9:33:28", "joined", "viewer-#{@chloe.id}" ],
        [ "9:33:39", "joined", "viewer-#{@bruno.id}" ], [ "9:36:16", "left", "viewer-#{@bruno.id}" ],
        [ "9:36:34", "aborted", "viewer-#{@bruno.id}" ], [ "9:36:35", "joined", "viewer-#{@bruno.id}" ],
        [ "9:39:01", "left", "viewer-#{@bruno.id}" ],
        [ "9:34:35", "joined", "speaker-#{@guest.id}" ],
        [ "9:35:00", "joined", "speaker-#{@alice_speaker.id}" ], [ "9:35:08", "left", alice ],
        [ "9:40:00", "page_opened", "viewer-#{@denis.id}" ],
        [ "10:30:10", "left", "speaker-#{@alice_speaker.id}" ], [ "10:30:14", "left", "viewer-#{@chloe.id}" ],
        [ "10:51:42", "left", "speaker-#{@guest.id}" ],
        [ "10:52:02", "room_finished", nil ]
  end

  def at(clock)
    Time.zone.parse("2026-11-10 #{clock}")
  end

  def registration(name, confirmed: true)
    @webinar.registrations.create!(name: name, email: "#{I18n.transliterate(name).downcase}@example.test",
                                   confirmed_at: (1.day.ago if confirmed))
  end

  def log(*facts)
    facts.each do |clock, kind, identity|
      @webinar.presence_events.create!(kind: kind, identity: identity, occurred_at: at(clock), source: "livekit_log")
    end
  end

  def row(result, name)
    result.attendees.find { |attendee| attendee.person.name == name }
  end

  test "une ligne par personne, ses arrivées et départs, l'animation comprise" do
    result = PresenceTimeline.new(@webinar).call

    assert_equal [ "luc", "Alice", "Chloé", "Bruno", "Invité" ], result.attendees.map { |attendee| attendee.person.name }
    assert_equal [ [ at("9:32:54"), at("10:30:10") ] ], row(result, "Alice").intervals,
                 "spectatrice puis intervenante par son lien privé : une seule présence, sans trou"
    assert_equal :intervenant, row(result, "Alice").person.role
    assert_equal [ [ at("9:33:39"), at("9:36:16") ], [ at("9:36:35"), at("9:39:01") ] ], row(result, "Bruno").intervals
    assert_equal %w[aborted], row(result, "Bruno").attempts.map(&:kind)
    assert_equal [ [ at("9:30:08"), at("10:52:02") ] ], row(result, "luc").intervals,
                 "sans départ reçu, la fermeture de la salle clôt la présence"
    assert_equal :animation, row(result, "luc").person.role
    assert_nil row(result, "Invité").person.registration
  end

  test "courbe : présents dans le temps, au plus fort" do
    result = PresenceTimeline.new(@webinar).call

    assert_equal [ at("9:30:08"), 1 ], result.curve.first
    assert_equal [ at("9:34:35"), 5 ], result.peak
    assert_not_includes result.curve.map(&:first), at("9:35:00"), "Alice ne compte qu'une fois en passant intervenante"
    assert_equal [ at("10:52:02"), 0 ], result.curve.last
    assert_equal [ at("9:30"), at("10:52:02") ], result.window
  end

  test "salle rouverte l'après-midi : les graphiques restent sur le café, le tableau garde tout" do
    log [ "16:44:04", "joined", "host-sub-luc" ], [ "16:44:12", "left", "host-sub-luc" ]

    result = PresenceTimeline.new(@webinar).call

    assert_equal [ at("9:30"), at("11:51") ], result.window
    assert_equal [ at("9:30"), at("16:44:12") ], result.full_window
    assert_equal [ at("16:44:04"), at("16:44:12") ], row(result, "luc").intervals.last
  end

  test "inscrits venus, qui a essayé sans entrer, qui n'est jamais venu" do
    result = PresenceTimeline.new(@webinar).call

    assert_equal [ @denis ], result.tried.map { |attendee| attendee.person.registration }
    assert_equal %w[page_opened], result.tried.first.attempts.map(&:kind)
    assert_equal [ @denis, @elise ], result.never_came, "avoir essayé n'est pas être venu"
    assert_equal [ 5, 1 ], [ result.expected_count, result.unconfirmed_count ]
    assert result.attempts_captured
    assert_equal %w[livekit_log], result.sources
  end

  test "inscription effacée depuis : la présence reste comptée, sans nom" do
    @chloe.retire!

    result = PresenceTimeline.new(@webinar).call

    anonymous = result.attendees.select { |attendee| attendee.person.anonymous? }
    assert_equal 1, anonymous.size
    assert_equal :inscrit, anonymous.first.person.role
    assert_equal 5, result.peak.last
  end

  test "direct en cours : une présence ouverte court jusqu'à maintenant" do
    @webinar.update!(state: "live", ended_at: nil)
    PresenceEvent.where(webinar: @webinar, kind: "room_finished").delete_all
    PresenceEvent.where(webinar: @webinar, identity: "viewer-#{@chloe.id}", kind: "left").delete_all

    result = PresenceTimeline.new(@webinar, now: at("10:40")).call

    chloe = row(result, "Chloé")
    assert chloe.ongoing
    assert_equal at("10:40"), chloe.intervals.last.last
    assert_equal at("10:40"), result.window.last
  end

  test "rien de relevé : vide, et tous les attendus sont « jamais venus »" do
    PresenceEvent.where(webinar: @webinar).delete_all

    result = PresenceTimeline.new(@webinar).call

    assert result.empty?
    assert_empty result.curve
    assert_nil result.window
    assert_equal 5, result.never_came.size
    assert_not result.attempts_captured
  end

  test "reconnexion datée de la même seconde, arrivée notée avant le départ : une seule présence continue" do
    PresenceEvent.where(webinar: @webinar).delete_all
    viewer = "viewer-#{@chloe.id}"
    log [ "9:33:00", "joined", viewer ], [ "9:40:00", "joined", viewer ], [ "9:40:00", "left", viewer ], [ "10:30:00", "left", viewer ]

    assert_equal [ [ at("9:33"), at("10:30") ] ], row(PresenceTimeline.new(@webinar).call, "Chloé").intervals
  end

  test "départ sans arrivée relevée : venu, arrivée inconnue, hors de la courbe" do
    PresenceEvent.where(webinar: @webinar).delete_all
    log [ "9:30:08", "joined", "host-sub-luc" ], [ "10:30:14", "left", "viewer-#{@chloe.id}" ], [ "10:51:42", "left", "host-sub-luc" ]

    result = PresenceTimeline.new(@webinar).call

    chloe = row(result, "Chloé")
    assert_equal [ [ nil, at("10:30:14") ] ], chloe.partial
    assert_empty chloe.intervals
    assert_not_includes result.never_came, @chloe
    assert_equal 1, result.peak.last
  end

  test "inscrit noté venu sur son inscription, absent du journal : venu, départ inconnu" do
    @elise.update!(room_joined_at: at("9:45"))

    result = PresenceTimeline.new(@webinar).call

    assert_equal [ [ at("9:45"), nil ] ], row(result, "Élise").partial
    assert_equal [ @denis ], result.never_came
    assert_includes result.sources, "registration"
  end

  test "tentatives seules (café à venir) : pas de fenêtre, l'inscrit qui a essayé reste « jamais venu »" do
    PresenceEvent.where(webinar: @webinar).delete_all
    @webinar.update!(state: "draft", started_at: nil, ended_at: nil)
    log [ "9:10:00", "page_opened", "viewer-#{@denis.id}" ]

    result = PresenceTimeline.new(@webinar, now: at("9:20")).call

    assert_nil result.window
    assert_empty result.attendees
    assert_equal [ @denis ], result.tried.map { |attendee| attendee.person.registration }
    assert_includes result.never_came, @denis
    assert_not result.all_came?
  end

  test "expulsé par la garde : son départ ne le fait pas entrer, quel que soit l'ordre noté" do
    [ %w[refused left], %w[left refused] ].each do |kinds|
      PresenceEvent.where(webinar: @webinar).delete_all
      log [ "9:30:08", "joined", "host-sub-luc" ], *kinds.map { |kind| [ "9:40:00", kind, "viewer-#{@denis.id}" ] }

      result = PresenceTimeline.new(@webinar).call

      assert_nil row(result, "Denis"), kinds.inspect
      assert_equal [ @denis ], result.tried.map { |attendee| attendee.person.registration }, kinds.inspect
      assert_includes result.never_came, @denis, kinds.inspect
    end
  end
end
