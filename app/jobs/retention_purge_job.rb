class RetentionPurgeJob < ApplicationJob
  # RetentionPurgeJob — purge des données arrivées au bout de leur durée de
  # conservation.
  #
  # Tient les engagements de la politique de confidentialité
  # (app/views/legal/confidentialite.html.erb) :
  #
  #   • Inscriptions (nom + email + confirmations) : 12 mois après la
  #     date du webinaire, puis suppression. HandRaise (qui référence
  #     Registration via FK) est purgée avec, ainsi que la discussion du
  #     direct (Message : noms et textes des participants), la file Q&R
  #     qui en est extraite (QaItem, QaItemMessage : reformulations) et les
  #     réponses aux sondages (PollResponse : noms, réponses ; FK vers
  #     Registration), et le journal de présence (PresenceEvent : qui
  #     s'est connecté quand). L'adresse qu'un intervenant a déclarée au lien
  #     participants privé (Speaker#declared_email, non rattachée) suit le
  #     même terme ; un intervenant rattaché perd son rattachement (FK
  #     nullify).
  #   • Demandes d'inscription de l'API (RegistrationRequest : nom, email,
  #     profil, message, « préviens-moi ») : NON confirmées, effacées avec
  #     leurs inscriptions 30 jours après la demande (lien expiré au même
  #     terme) ; confirmées, 12 mois après la demande, une fois purgées les
  #     inscriptions qui y sont rattachées.
  #   • Recherches dans les replays (ReplaySearch : requête, auteur) : 12
  #     mois après la recherche ; avant, elles partent avec l'inscription
  #     (clé étrangère en cascade) ou le compte.
  #   • Abonnement à l'agenda personnel (CalendarSubscription : email, jeton) :
  #     suit la personne, supprimé quand il ne reste plus aucune inscription ni
  #     demande à son adresse, donc au même terme que la dernière.
  #   • Enregistrements (Recording + fichier MP4/WEBM sur disque, et sa
  #     version légère avec son marqueur et sa demande, LightVersion#purge!),
  #     transcription (TranscriptSegment), ce qui en est tiré pour le replay
  #     (chapitres et thèmes : ChapterSet ; index de recherche :
  #     ReplaySearchIndex) et accords à l'image qui les
  #     couvrent (ParticipantConsent, preuve gardée aussi longtemps que les
  #     enregistrements) : au plus 3 ans après la date du webinaire.
  #   • Intervenants (Speaker : nom, email, lien d'accès ; leurs préférences
  #     de périphériques) et adresses prévenues du dépôt de l'épisode
  #     (EpisodePublication#notified_emails) : 3 ans après la date du
  #     webinaire, avec les enregistrements.
  #   • Mesures des émetteurs caméra (CameraSample : identité LiveKit,
  #     résolution, encodeur) : CameraSample::RETENTION après la mesure.
  #   Les copies déposées dans Nextcloud et les extraits publiés ne sont pas
  #   effacés ici : ils sont retirés sur demande (docs/depublication.md).
  #
  # « Date du webinaire » = Webinar#starts_at (obligatoire), pas ended_at :
  # un webinaire programmé mais jamais tenu suit la même règle.
  #
  # Les Webinar ne sont JAMAIS supprimés (has_many
  # :registrations/:recordings/:transcript_segments
  # dependent: :restrict_with_exception) — on vide les données datées
  # autour.
  #
  # Idempotent : rejoué, delete_all sur un scope vide renvoie 0 ; un
  # fichier déjà supprimé renvoie ENOENT (silencieux). Journalisation =
  # compteurs seuls, jamais nom ni email (RGPD + politique interne).
  #
  # Garde fichier : `Recording#absolute_path` est l'UNIQUE résolveur des
  # originaux (LightVersion revérifie de même ses dérivés sous `_leger/` et
  # `_replays/<slug>/`) ;
  # il refuse tout chemin qui sortirait de `<RECORDINGS_ROOT>/<slug>/`
  # (cleanpath + double vérification préfixe). Un path forgé → nil, le
  # fichier n'est jamais touché. On n'appelle JAMAIS FileUtils.rm_rf.

  queue_as :default

  REGISTRATION_RETENTION = 12.months
  RECORDING_RETENTION    = 3.years

  def perform(now: Time.current)
    reg_count, hand_count, message_count, poll_response_count, qa_count, presence_count = purge_registrations(now - REGISTRATION_RETENTION)
    search_count                            = ReplaySearch.where(created_at: ...(now - ReplaySearch::RETENTION)).delete_all
    request_count                           = purge_registration_requests(now)
    subscription_count                      = purge_calendar_subscriptions
    rec_count, file_count, transcript_count, consent_count = purge_recordings_and_transcripts(now - RECORDING_RETENTION)
    speaker_count = purge_speakers(now - RECORDING_RETENTION)
    camera_sample_count = CameraSample.expired(now).delete_all

    Rails.logger.info(
      "retention_purge registrations=#{reg_count} hand_raises=#{hand_count} messages=#{message_count} qa_items=#{qa_count} " \
      "poll_responses=#{poll_response_count} presence_events=#{presence_count} replay_searches=#{search_count} " \
      "registration_requests=#{request_count} calendar_subscriptions=#{subscription_count} " \
      "recordings=#{rec_count} files_deleted=#{file_count} transcript_segments=#{transcript_count} " \
      "participant_consents=#{consent_count} speakers=#{speaker_count} camera_samples=#{camera_sample_count}"
    )
  end

  private

  def purge_registrations(cutoff)
    webinar_ids = Webinar.where(starts_at: ...cutoff).pluck(:id)
    return [ 0, 0, 0, 0, 0, 0 ] if webinar_ids.empty?

    # FK hand_raises.registration_id et poll_responses.registration_id →
    # registrations, qa_item_messages → messages / qa_items : on vide d'abord
    # les tables qui pointent (sinon violation d'intégrité). Toutes visent des
    # Webinar antérieurs à la coupure ; les questions des sondages (sans
    # donnée personnelle) restent avec le webinaire.
    qa_items      = QaItem.where(webinar_id: webinar_ids)
    QaItemMessage.where(qa_item_id: qa_items.select(:id)).delete_all
    qa_count      = qa_items.delete_all
    hand_count    = HandRaise.where(webinar_id: webinar_ids).delete_all
    message_count = Message.where(webinar_id: webinar_ids).delete_all
    poll_response_count = PollResponse.where(poll_id: Poll.where(webinar_id: webinar_ids).select(:id)).delete_all
    presence_count = PresenceEvent.where(webinar_id: webinar_ids).delete_all
    reg_count     = Registration.where(webinar_id: webinar_ids).delete_all
    Speaker.where(webinar_id: webinar_ids).where.not(declared_email: nil).update_all(declared_email: nil, link_token: nil)
    [ reg_count, hand_count, message_count, poll_response_count, qa_count, presence_count ]
  end

  # Après `purge_registrations` : une demande dont un café est encore dans
  # la fenêtre garde ses inscriptions, donc la demande (FK).
  def purge_registration_requests(now)
    cutoff = now - REGISTRATION_RETENTION
    expired = RegistrationRequest.unconfirmed_expired(now)
    Registration.where(registration_request_id: expired.select(:id), confirmed_at: nil).delete_all
    expired.where.missing(:registrations).delete_all +
      RegistrationRequest.where(created_at: ...cutoff).where.missing(:registrations).delete_all
  end

  # Après les deux purges précédentes : une adresse sans inscription ni
  # demande restante n'a plus rien qui justifie son lien d'agenda.
  def purge_calendar_subscriptions
    CalendarSubscription.where.not(email: Registration.select(:email))
                        .where.not(email: RegistrationRequest.select(:email)).delete_all
  end

  def purge_recordings_and_transcripts(cutoff)
    webinar_ids = Webinar.where(starts_at: ...cutoff).pluck(:id)
    return [ 0, 0, 0, 0 ] if webinar_ids.empty?

    file_count = 0
    Recording.where(webinar_id: webinar_ids).find_each do |recording|
      file_count += 1 if delete_file(recording.absolute_path)
      LightVersion.new(recording).purge!
    end
    # Copie de diffusion d'un replay : sa ligne part en cascade avec la vidéo
    # de référence, son fichier est supprimé ici, avant ; de même le montage
    # (adopté ou non), son marqueur et sa demande.
    Replay.where(webinar_id: webinar_ids).find_each do |replay|
      file_count += 1 if delete_file(replay.derived_file)
      ReplayMontage.new(replay).purge!
    end
    SpotlightChange.where(webinar_id: webinar_ids).delete_all

    rec_count        = Recording.where(webinar_id: webinar_ids).delete_all
    transcript_count = TranscriptSegment.where(webinar_id: webinar_ids).delete_all
    ChapterSet.where(webinar_id: webinar_ids).delete_all
    ReplaySearchIndex.purge(webinar_ids)
    consent_count    = ParticipantConsent.where(webinar_id: webinar_ids).delete_all
    [ rec_count, file_count, transcript_count, consent_count ]
  end

  # Les accords à l'image n'ont pas de clé étrangère vers Speaker : la
  # preuve a déjà suivi les enregistrements.
  def purge_speakers(cutoff)
    webinar_ids = Webinar.where(starts_at: ...cutoff).pluck(:id)
    return 0 if webinar_ids.empty?

    speakers = Speaker.where(webinar_id: webinar_ids)
    DevicePreference.where(owner_type: "Speaker", owner_id: speakers.select(:id)).delete_all
    EpisodePublication.where(webinar_id: webinar_ids).update_all(notified_emails: [])
    speakers.delete_all
  end

  # Supprime UNIQUEMENT le chemin résolu par son modèle (Recording#absolute_path
  # borné sous `<RECORDINGS_ROOT>/<slug>/`, Replay#derived_file sous
  # `_replays/<slug>/`, extension DERIVED_EXTENSIONS). Ne touche jamais au
  # dossier parent, jamais récursivement. Un chemin nil (blank, hors préfixe
  # ou autre extension) ou un fichier déjà absent → no-op.
  #
  # @return [Boolean] true si un fichier a été effectivement supprimé.
  def delete_file(resolved)
    return false if resolved.nil?
    return false unless File.file?(resolved)

    File.delete(resolved)
    true
  rescue Errno::ENOENT
    false
  end
end
