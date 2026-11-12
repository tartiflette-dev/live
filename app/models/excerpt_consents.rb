# Qui peut figurer dans les extraits et shorts d'un webinaire :
# la réponse que lisent le montage, sur la page
# Enregistrements, et le dossier d'épisode (EpisodeManifest : README et
# `<épisode>-extraits.json`).
#
# Une personne n'y figure que si son DERNIER accord (ParticipantConsent)
# porte la case des extraits et n'a pas été retiré ; les accords précédents
# restent dans l'historique (« retiré le…, redonné le… »). L'animation de
# droit (propriétaire, animateurs du projet) est couverte par la politique
# de confidentialité ; un co-animateur invité donne son accord comme les
# autres. Personne enregistrée sans accord (avant la fenêtre de
# consentement, ou client périmé) : extraits non autorisés.
class ExcerptConsents
  LABELS = {
    allowed: "extraits autorisés",
    refused: "extraits non autorisés",
    withdrawn: "accord retiré",
    missing: "aucun accord : extraits non autorisés",
    animation: "animation : couverte par la politique"
  }.freeze

  def initialize(webinar)
    @webinar = webinar
  end

  # Identités LiveKit concernées : les personnes enregistrées (pistes,
  # assemblages, transcription) et celles qui ont donné un accord.
  def identities
    @identities ||= (recorded_identities + consents_by_identity.keys).uniq.sort
  end

  def status(identity)
    return :animation if permission.exempt_identity?(identity)

    history(identity).last&.excerpt_status || :missing
  end

  # Accords de `identity`, du premier au dernier.
  def history(identity)
    consents_by_identity.fetch(identity, [])
  end

  # État, suivi de l'historique quand l'accord a été retiré puis redonné.
  def label(identity)
    events = history(identity).each_with_index.flat_map do |consent, index|
      [ (index.positive? ? "redonné le #{moment(consent.consented_at)}" : nil),
        (consent.withdrawn_at ? "retiré le #{moment(consent.withdrawn_at)}" : nil) ]
    end.compact
    base = LABELS.fetch(status(identity))
    history(identity).size > 1 ? "#{base} (#{events.join(', ')})" : base
  end

  private

  def moment(time)
    time.in_time_zone("Europe/Paris").strftime("%d/%m/%Y à %-H:%M")
  end

  def permission
    @permission ||= PublishPermission.new(@webinar)
  end

  def consents_by_identity
    @consents_by_identity ||= @webinar.participant_consents.order(:consented_at, :id).group_by(&:participant_identity)
  end

  def recorded_identities
    @webinar.recordings.unscope(:order).where.not(participant_identity: [ nil, "" ]).distinct.pluck(:participant_identity) +
      @webinar.transcript_segments.distinct.pluck(:participant_identity)
  end
end
