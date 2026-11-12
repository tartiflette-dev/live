# Retrait de l'accord à l'image depuis la salle (bouton « Retirer mon accord ») : l'accord en cours est horodaté retiré, ses
# pistes séparées en cours d'enregistrement s'arrêtent, la salle retire à la
# personne le droit de publier, et l'animateur propriétaire est prévenu par
# mail (les délais de dépublication partent de ce mail). La personne repasse
# spectatrice. Le client a déjà coupé et dépublié ses pistes
# (participant_consent.jsx) : ce retrait serveur couvre le client qui ne
# l'aurait pas fait.
#
# Pistes séparées : leur arrêt ne dépend pas de LiveKit. Dès `withdrawn_at`,
# aucune ne démarre plus (TrackRecordingSession.recordable?), celles en cours
# sont arrêtées ici, et la réconciliation arrête toute piste restée sans
# accord.
#
# Composite (replay) et transcription prennent tout ce qui est publié dans
# la salle : ils cessent de recevoir la personne quand LiveKit lui retire le
# droit de publier (PublishPermission#close!, ou la main refermée pour un
# spectateur). Si la salle ne répond pas, PublishingRevocationJob réessaie,
# puis alerte l'animateur propriétaire. Un nouveau jeton ne rend pas ce droit :
# PublishPermission le ferme à qui n'a pas d'accord en cours.
class ConsentWithdrawal
  def initialize(webinar, holder, client: nil, egress_client: nil)
    @webinar = webinar
    @holder = holder
    @client = client
    @egress_client = egress_client
  end

  # @return [ParticipantConsent, nil] l'accord retiré ; nil s'il n'y en
  #   avait pas en cours (retrait déjà fait : rien à refaire)
  def call
    consent = ParticipantConsent.current_for(@holder, webinar: @webinar)
    return unless consent&.withdraw!

    stop_track_recordings(consent.participant_identity)
    ConsentMailer.withdrawn(consent).deliver_later
    revoke_publishing_or_retry
    consent
  end

  # Retire le droit de publier si la règle ne le permet plus, relue sous le
  # verrou des mains levées (HandRaiseControl#close_publication_unless_allowed) :
  # un spectateur qui a encore la parole la rend (sa main refermée retire la
  # permission), sinon la permission est fermée. Absente de la salle, la
  # personne n'a rien à retirer.
  # @raise [RoomServiceClient::Error] salle injoignable
  def revoke_publishing!
    HandRaiseControl.new(@webinar, client: @client).close_publication_unless_allowed(@holder)
  rescue RoomServiceClient::RemoteError => error
    raise unless error.code == "not_found"
  end

  private

  def stop_track_recordings(identity)
    @webinar.recordings.tracks.active.where(participant_identity: identity).find_each do |recording|
      TrackRecordingSession.stop(recording, client: egress_client)
    end
  end

  def revoke_publishing_or_retry
    revoke_publishing!
  rescue RoomServiceClient::Error => error
    Rails.logger.warn(
      "[consent_withdrawal] permission non retirée, nouvel essai en file webinar=#{@webinar.id} " \
      "holder=#{@holder.class.name}-#{@holder.id} err=#{error.class}"
    )
    PublishingRevocationJob.perform_later(@webinar, @holder)
  end

  def egress_client
    @egress_client ||= RecordingSession.default_client
  end
end
