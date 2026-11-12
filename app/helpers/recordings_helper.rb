module RecordingsHelper
  EXCERPT_CONSENT_STATES = { allowed: "etat--succes", animation: "etat--neutre" }.freeze

  # Durée d'un enregistrement (DurationFormat). Tiret si l'enregistrement
  # n'est pas terminé.
  def duree_enregistrement(recording)
    return "—" unless recording.started_at && recording.ended_at

    DurationFormat.short(recording.ended_at - recording.started_at)
  end

  # Accord d'une personne pour les extraits et shorts (ExcerptConsents) :
  # tout ce qui n'est pas autorisé est un écart pour le montage.
  def excerpt_consent_badge(consents, identity)
    status = consents.status(identity)
    tag.span(consents.label(identity), class: [ "etat", EXCERPT_CONSENT_STATES.fetch(status, "etat--ecart") ],
             data: { role: "excerpt-consent", status: status })
  end
end
