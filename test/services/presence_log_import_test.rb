require "test_helper"

# Cafés tenus avant le journal de présence : on rejoue les webhooks que le
# serveur LiveKit a envoyés, lus dans son journal (format réel de
# `docker logs livekit`, lignes « sent webhook »).
class PresenceLogImportTest < ActiveSupport::TestCase
  setup do
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 2.hours.ago, host_sub: "sub-marc")
    @other = Webinar.create!(title: "Café IA #8", starts_at: 6.days.ago, host_sub: "sub-marc")
    @alice = @webinar.registrations.create!(name: "Alice", email: "alice@example.test", confirmed_at: 1.day.ago)
    @speaker = @webinar.speakers.create!(name: "Alice", registration: @alice)
  end

  def sent(event, identity, at, id:, room: @webinar.room_name)
    entry = { level: "info", ts: at + 0.4, logger: "livekit.webhook", msg: "sent webhook", event: event, id: id,
              webhookTime: at, url: "https://live.example.test/webhooks/livekit", room: room, roomID: "RM_x",
              status: "204 No Content", statusCode: 204 }
    entry[:participant] = identity if identity
    entry.to_json
  end

  test "arrivées, départs, interruptions et fermeture ; ni l'enregistreur ni le transcripteur ; autres lignes ignorées" do
    t = 1_794_299_573
    lines = [
      sent("participant_joined", "viewer-#{@alice.id}", t, id: "EV_1"),
      sent("participant_joined", "EG_testPresence", t, id: "EV_2"),
      sent("participant_joined", "agent-AJ_testPresence", t, id: "EV_3"),
      sent("track_published", "viewer-#{@alice.id}", t, id: "EV_4"),
      { msg: "starting RTC session", room: @webinar.room_name, participant: "viewer-#{@alice.id}" }.to_json,
      "pas du JSON",
      sent("participant_connection_aborted", "speaker-#{@speaker.id}", t + 30, id: "EV_5"),
      sent("participant_left", "viewer-#{@alice.id}", t + 60, id: "EV_6"),
      sent("room_finished", nil, t + 90, id: "EV_7"),
      sent("participant_joined", "viewer-99", t, id: "EV_8", room: "salle-inconnue")
    ]

    added = PresenceLogImport.call(lines)

    assert_equal({ @webinar.slug => 4 }, added)
    events = @webinar.presence_events.chronological
    assert_equal [ [ "joined", "viewer-#{@alice.id}" ], [ "aborted", "speaker-#{@speaker.id}" ],
                   [ "left", "viewer-#{@alice.id}" ], [ "room_finished", nil ] ], events.pluck(:kind, :identity)
    assert_equal Time.zone.at(t), events.first.occurred_at
    assert_equal %w[livekit_log], events.pluck(:source).uniq
  end

  test "rejouable : un webhook déjà reçu en direct ou déjà importé ne compte qu'une fois" do
    t = 1_794_299_573
    PresenceEvent.record_room!(@webinar, "joined", "viewer-#{@alice.id}", at: Time.zone.at(t), livekit_event_id: "EV_1")
    lines = [ sent("participant_joined", "viewer-#{@alice.id}", t, id: "EV_1"), sent("participant_left", "viewer-#{@alice.id}", t + 5, id: "EV_2") ]

    assert_equal({ @webinar.slug => 1 }, PresenceLogImport.call(lines))
    assert_equal({}, PresenceLogImport.call(lines))
    assert_equal 2, @webinar.presence_events.count
  end

  test "la première arrivée d'un inscrit suit, la plus ancienne gagne, y compris par son lien intervenant" do
    t = 1_794_299_573
    @alice.update!(room_joined_at: Time.zone.at(t + 3600))

    PresenceLogImport.call([ sent("participant_joined", "speaker-#{@speaker.id}", t, id: "EV_1") ])

    assert_equal Time.zone.at(t), @alice.reload.room_joined_at
  end

  test "ligne sans heure : pas reprise" do
    line = { msg: "sent webhook", event: "participant_joined", id: "EV_1", room: @webinar.room_name,
             participant: "viewer-#{@alice.id}" }.to_json

    assert_equal({}, PresenceLogImport.call([ line ]))
  end

  test "limité aux cafés demandés" do
    t = 1_794_299_573
    lines = [ sent("participant_joined", "viewer-#{@alice.id}", t, id: "EV_1"),
              sent("room_finished", nil, t, id: "EV_2", room: @other.room_name) ]

    assert_equal({ @other.slug => 1 }, PresenceLogImport.call(lines, slugs: [ @other.slug ]))
  end
end
