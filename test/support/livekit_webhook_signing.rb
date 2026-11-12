# Signe un corps de webhook comme livekit-server : JWT HS256 (iss = api key)
# portant le SHA-256 base64 du corps BRUT.
module LivekitWebhookSigning
  WEBHOOK_KEY    = "APItestkey"
  WEBHOOK_SECRET = "s" * 40

  def signed_authorization(body, key: WEBHOOK_KEY, secret: WEBHOOK_SECRET, exp: 5.minutes.from_now, sha: nil)
    claims = { iss: key, exp: exp.to_i, sha256: sha || Base64.strict_encode64(Digest::SHA256.digest(body)) }
    "Bearer #{JWT.encode(claims, secret, 'HS256')}"
  end

  # `id` et `created_at` (secondes) : identifiant et heure du fait, comme
  # livekit-server les pose (journal de présence, PresenceEvent).
  def webhook_body(event:, room: nil, identity: nil, kind: nil, track_sid: nil, source: nil, egress_info: nil, can_publish: false,
                   id: nil, created_at: nil)
    attrs = { event: event }
    attrs[:id] = id if id
    attrs[:created_at] = created_at.to_i if created_at
    attrs[:room] = LiveKit::Proto::Room.new(name: room) if room
    if identity
      participant_attrs = { identity: identity }
      # participant.kind : STANDARD (default) / INGRESS / EGRESS / SIP /
      # AGENT / CONNECTOR / BRIDGE. Les tests qui simulent un
      # enregistrement ou l'agent de transcription passent `kind: :EGRESS`
      # ou `kind: :AGENT` ; la garde participant_joined doit alors
      # IGNORER ces participants.
      participant_attrs[:kind] = kind if kind
      # Droit de publier du jeton (garde de l'accord à l'image, PublishPermission).
      participant_attrs[:permission] = LiveKit::Proto::ParticipantPermission.new(can_publish: true) if can_publish
      attrs[:participant] = LiveKit::Proto::ParticipantInfo.new(**participant_attrs)
    end
    attrs[:track] = LiveKit::Proto::TrackInfo.new(sid: track_sid, source: source) if track_sid
    attrs[:egress_info] = egress_info if egress_info
    LiveKit::Proto::WebhookEvent.new(**attrs).to_json
  end
end
