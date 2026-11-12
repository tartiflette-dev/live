require "test_helper"

# Journal de présence : un webhook rejoué ne compte qu'une fois, une page
# rechargée ne fait qu'une tentative, et rien d'autre qu'une personne n'y entre.
class PresenceEventTest < ActiveSupport::TestCase
  setup do
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.ago, host_sub: "sub-marc")
  end

  test "un fait de salle au même identifiant LiveKit n'est noté qu'une fois" do
    at = Time.zone.parse("2026-11-10 09:32:53")
    first = PresenceEvent.record_room!(@webinar, "joined", "viewer-17", at: at, livekit_event_id: "EV_abc")

    assert_nil PresenceEvent.record_room!(@webinar, "joined", "viewer-17", at: at, livekit_event_id: "EV_abc", source: "livekit_log")
    assert_equal [ first ], @webinar.presence_events.to_a
    assert_equal "livekit", first.source
  end

  test "une tentative par personne et par fenêtre de deux minutes" do
    at = Time.zone.parse("2026-11-10 09:20:00")
    PresenceEvent.record_attempt!(@webinar, "page_opened", "viewer-7", at: at)
    PresenceEvent.record_attempt!(@webinar, "page_opened", "viewer-7", at: at + 90.seconds)
    PresenceEvent.record_attempt!(@webinar, "token_issued", "viewer-7", at: at + 90.seconds)
    PresenceEvent.record_attempt!(@webinar, "page_opened", "viewer-8", at: at + 90.seconds)
    PresenceEvent.record_attempt!(@webinar, "page_opened", "viewer-7", at: at + 3.minutes)

    assert_equal [ %w[page_opened viewer-7], %w[token_issued viewer-7], %w[page_opened viewer-8], %w[page_opened viewer-7] ],
                 @webinar.presence_events.chronological.pluck(:kind, :identity)
  end

  test "ni l'enregistreur, ni le transcripteur, ni une identité forgée" do
    %w[EG_testPresence agent-AJ_testPresence viewer-0 viewer-abc speaker-legacy-x].each do |identity|
      assert_not PresenceEvent.human_identity?(identity), identity
      assert_nil PresenceEvent.record_attempt!(@webinar, "page_opened", identity)
      assert_raises(ActiveRecord::RecordInvalid) { PresenceEvent.record_room!(@webinar, "joined", identity, at: Time.current) }
    end
    assert PresenceEvent.human_identity?("host-b28b5bdb-bfa4")
    assert PresenceEvent.record_room!(@webinar, "room_finished", nil, at: Time.current)
  end

  test "heure du fait selon LiveKit, sinon heure de réception" do
    assert_equal Time.zone.at(1_794_299_398), PresenceEvent.webhook_time({ "created_at" => "1794299398" })
    freeze_time do
      assert_equal Time.current, PresenceEvent.webhook_time({})
      assert_equal Time.current, PresenceEvent.webhook_time({ "created_at" => "0" })
    end
  end
end
