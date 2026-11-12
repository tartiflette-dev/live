# frozen_string_literal: true

require "test_helper"

# Vérification du transcripteur d'un webinaire : une à la fois par webinaire,
# jamais une erreur LiveKit remontée.
class TranscriberPresenceJobTest < ActiveJob::TestCase
  test "une vérification à la fois par webinaire, les doublons abandonnés (deux dispatches = chaque phrase archivée deux fois)" do
    job = TranscriberPresenceJob.new(7)

    assert job.concurrency_limited?
    assert_equal 1, TranscriberPresenceJob.concurrency_limit
    assert_equal :discard, TranscriberPresenceJob.concurrency_on_conflict
    assert_equal "TranscriberPresenceJob/transcriber-presence-7", job.concurrency_key
  end

  test "une vérification qui ne joint pas LiveKit est journalisée, jamais levée" do
    webinar = Webinar.create!(title: "En direct", starts_at: 1.hour.ago, host_sub: "sub-a", state: "live", started_at: 1.hour.ago)
    previous = Rails.configuration.x.room_service_client_factory
    failing = Object.new
    failing.define_singleton_method(:list_participants) { |room:| raise RoomServiceClient::Error, "unavailable" }
    Rails.configuration.x.room_service_client_factory = -> { failing }
    flag = ENV["TRANSCRIPT_ENABLED"]
    ENV["TRANSCRIPT_ENABLED"] = "true"

    assert_nothing_raised { TranscriberPresenceJob.perform_now(webinar.id) }
  ensure
    Rails.configuration.x.room_service_client_factory = previous
    ENV["TRANSCRIPT_ENABLED"] = flag
  end

  # LiveKit injoignable n'observe rien : une interruption en cours n'est ni
  # close ni réalertée (Webinar::TranscriptionOutage).
  test "LiveKit injoignable : l'état de la transcription reste tel quel, aucun mail" do
    absent_since = 10.minutes.ago.change(usec: 0)
    webinar = Webinar.create!(title: "En direct", starts_at: 1.hour.ago, host_sub: "sub-a", state: "live",
                              started_at: 1.hour.ago, transcriber_absent_since: absent_since,
                              transcription_interrupted_at: 7.minutes.ago)
    previous = Rails.configuration.x.room_service_client_factory
    failing = Object.new
    failing.define_singleton_method(:list_participants) { |room:| raise RoomServiceClient::Error, "unavailable" }
    Rails.configuration.x.room_service_client_factory = -> { failing }
    flag = ENV["TRANSCRIPT_ENABLED"]
    ENV["TRANSCRIPT_ENABLED"] = "true"

    assert_no_enqueued_jobs(only: ActionMailer::MailDeliveryJob) { TranscriberPresenceJob.perform_now(webinar.id) }
    assert_equal absent_since, webinar.reload.transcription_interrupted_since
  ensure
    Rails.configuration.x.room_service_client_factory = previous
    ENV["TRANSCRIPT_ENABLED"] = flag
  end
end
