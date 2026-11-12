class StartTrackEgressJob < ApplicationJob
  queue_as :default

  def perform(webinar_id, track_sid, identity, source)
    return unless ENV["TRACK_EGRESS_ENABLED"] == "true"
    webinar = Webinar.find_by(id: webinar_id)
    return unless webinar

    TrackRecordingSession.start(webinar: webinar, track_sid: track_sid, identity: identity, source: source)
  end
end
