# frozen_string_literal: true

# Replays : un café terminé avec sa vue d'ensemble sur disque (sous un
# RECORDINGS_ROOT temporaire, EpisodePublicationHelpers), le replay publié,
# et les comptes qui le regardent (inscriptions : AnnouncementFixtures).
module ReplayHelpers
  include EpisodePublicationHelpers

  # Composite de 56 min 38 s (09:31:06 → 10:27:44), octets `bytes`.
  def replay_cafe(published: true, bytes: "0123456789" * 10)
    webinar = ended_cafe
    add_recording(webinar, kind: "composite", file: "composite-#{webinar.slug}.mp4", bytes: bytes)
    replay = Replay.publish!(webinar)
    replay.unpublish! unless published
    replay
  end

  # Compte undust sans aucun groupe ni webinaire : un spectateur.
  def spectator_user(email: "spectatrice@example.test", sub: "sub-spectatrice")
    User.create!(email: email, oidc_sub: sub)
  end

  def session_key
    SecureRandom.uuid
  end
end
