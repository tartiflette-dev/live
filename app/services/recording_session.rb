# frozen_string_literal: true

# RecordingSession — logique de démarrage / arrêt d'un enregistrement
# egress LiveKit, PARTAGÉE entre les deux points d'entrée :
#
#   • RecordingsController (Démarrer/Arrêter manuels)
#   • WebinarStatesController#go_live / #resume et LiveEnding (auto)
#
# L'extraction évite la duplication : les
# deux appelants répondent au MÊME acteur (l'animateur) qui déclenche
# l'enregistrement composite du direct — la question SRP est tranchée.
#
# Invariant fail-loud : toute erreur egress est PERSISTÉE sur le
# Recording (status :failed + error_message + ended_at), jamais avalée.
# L'appelant lit `recording.failed?` pour décider comment surfacer
# (flash controller, JSON payload) mais N'A PAS À gérer l'exception.
class RecordingSession
  # Valeur de retour quand `recordings.create!` lui-même échoue (validation,
  # contrainte DB) — le Recording n'existe pas en base, on ne peut pas le
  # marquer :failed. Duck-typée `Recording` sur le contrat consommé par les
  # contrôleurs : #failed? / #error_message (cf. RecordingsController#create,
  # WebinarStatesController#go_live). Trace `NB2`.
  CreationFailure = Struct.new(:error_message) do
    def failed?
      true
    end
  end

  # Un egress tournait encore après la fin du direct (constat en direct) :
  # rapporté à Rails.error (une ligne AppError, sans donnée personnelle)
  # pour qu'une récidive se voie ailleurs que dans le journal.
  class CapturingAfterEnd < StandardError; end

  # Démarre un enregistrement composite pour `webinar`.
  #
  # Le Recording est TOUJOURS créé (avant l'appel egress) — même sur
  # échec egress — pour tracer l'incident dans le listing recordings
  # et respecter l'invariant fail-loud. Un échec de `create!` lui-même
  # (ActiveRecord::RecordInvalid — cas limite : contrainte DB
  # inattendue, migration divergente) renvoie une `CreationFailure`
  # duck-typée : le contrôleur voit `recording.failed?` == true + un
  # `error_message` lisible, sans 500 non tracé.
  #
  # @param webinar [Webinar]
  # @param client [#start_room_composite] injecté (test stub), défaut =
  #   Rails.configuration.x.egress_client_factory.call
  # @return [Recording, CreationFailure] `failed?` distingue succès/échec
  def self.start_composite(webinar, client: default_client, room_client: nil)
    filename    = "#{Time.current.utc.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(6)}.mp4"
    relative    = "#{webinar.slug}/#{filename}"
    remote_path = "/data/#{relative}" # préfixe conteneur egress (volume /data)

    begin
      recording = webinar.recordings.create!(
        status:     :starting,
        started_at: Time.current,
        path:       relative
      )
    rescue ActiveRecord::RecordNotUnique
      # Course perdue contre un autre onglet/reload OU un actif existe
      # déjà (validation applicative dépassée) — protection centralisée
      # (review) :
      # tous les callers (ensure_active, RecordingsController#create,
      # WebinarStatesController#go_live) passent par start_composite et
      # sont donc protégés du 500 sur race. On retourne l'actif existant
      # (contrat symétrique à ensure_active).
      existing = webinar.recordings.active.composite.first
      return existing if existing
      # Sinon (course perdue puis vainqueur déjà terminé — cas limite) :
      # CreationFailure duck-typée, fail-loud lisible côté UI.
      return CreationFailure.new("création Recording refusée : conflit d'unicité (course)")
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error(
        "[recording_session] Recording create! failed webinar=#{webinar.slug}: #{e.message}"
      )
      return CreationFailure.new("création Recording refusée : #{e.message}")
    end

    begin
      # Egress requires the room even when no participant has joined yet.
      room_client ||= Rails.configuration.x.room_service_client_factory.call
      room_client.create_room(name: webinar.room_name)
      result = client.start_room_composite(
        room_name: webinar.room_name,
        filepath:  remote_path
      )
      # livekit-server répond EGRESS_STARTING : on reste `starting` jusqu'à
      # l'état ACTIVE (reconcile), sinon la scène affichait « REC » pendant
      # les ~15 s d'un egress qui avortait.
      status = result[:status] == :active ? :recording : :starting
      recording.update!(status: status, egress_id: result[:egress_id])
      # La fin du direct a pu passer pendant l'appel distant (scène rechargée
      # au moment de « Terminer ») : son arrêt n'a pas vu d'egress à stopper.
      # Rien ne capte après la fin.
      stop(recording, client: client) if webinar.reload.ended?
    rescue EgressClient::Error, RoomServiceClient::Error => e
      Rails.logger.error(
        "[recording_session] start failed webinar=#{webinar.slug} err=#{e.class}: #{e.message}"
      )
      recording.update!(status: :failed, error_message: e.message, ended_at: Time.current)
    end

    recording
  end

  # Garantit qu'un Recording actif existe pour `webinar` :
  #   • s'il en existe déjà un (starting|recording|stopping) → retour tel quel ;
  #   • sinon → tentative de démarrage via `start_composite`.
  #
  # Idempotent — appelé sur CHAQUE affichage de /w/:slug/stage (le host
  # revient sur la page, recharge, ouvre un 2e onglet). La protection
  # contre les doubles démarrages est empilée :
  #   (1) test `active.exists?` avant l'appel (chemin nominal) ;
  #   (2) validation `only_one_active_recording_per_webinar` (message lisible) ;
  #   (3) index unique partiel DB (race « deux SELECT concurrents voient
  #       tous les deux 0 puis INSERT ») → ActiveRecord::RecordNotUnique
  #       rescué ICI : on relit le vainqueur et on le retourne.
  #
  # Fail-loud : un échec egress reste PERSISTÉ (Recording :failed) — la
  # UI voit l'erreur via /recordings/status.json + polling REC.
  #
  # @return [Recording, CreationFailure, nil] Recording actif (nouveau ou
  #   existant), CreationFailure si create! a échoué, ou nil si la course
  #   a été perdue ET que la relecture ne trouve plus rien (cas limite :
  #   l'autre requête a démarré puis échoué très vite → aucun actif).
  def self.ensure_active(webinar, client: default_client, room_client: nil)
    # Guard ÉTAT : pas d'auto-start sur un webinaire terminé
    # (transition `ended` = direct clos, plus rien à enregistrer). On
    # RÉCONCILIE quand même l'existant pour fermer un reliquat le cas
    # échéant, mais on ne démarre PAS de nouveau Recording.
    # `draft` reste autorisé : un direct a déjà été animé en draft,
    # bloquer draft interdirait sa route réelle. `live` évidemment OK.
    reconcile(webinar, client: client)
    return nil if webinar.state.to_s == "ended"

    existing = webinar.recordings.active.composite.first
    return existing if existing

    # start_composite rescue lui-même RecordNotUnique :
    # aucun outer rescue nécessaire ici.
    start_composite(webinar, client: client, room_client: room_client)
  end

  # Réconcilie les Recordings ACTIFS d'un webinaire avec l'état réel côté
  # livekit-server. Un egress qui a terminé/échoué/aborté côté serveur
  # doit voir son Recording transitionner (done|failed), sinon la DB
  # ment et la contrainte unique bloque tout nouveau démarrage. Un egress
  # devenu ACTIF fait passer `starting` → `recording`.
  #
  # Idempotent, fail-safe : une erreur de réseau/twirp est LOGGUÉE et
  # laisse le Recording en l'état (invariant : jamais corrompre l'état
  # sur une panne transitoire — la prochaine réconciliation retentera).
  #
  # Appelé automatiquement :
  #   • par ensure_active AVANT décision (auto-start /stage et /join) ;
  #   • par RecordingsController#create avant tout démarrage ;
  #   • par RecordingsController#status AVANT sérialisation JSON (poll de la
  #     scène : 1 s pendant les 20 premières secondes d'une transition, 5 s
  #     sinon) ;
  #   • par ReconcileRecordingsJob, peu après la fin du direct (LiveEnding).
  #
  # Webinaire TERMINÉ : après la synchronisation, tout
  # Recording encore en captation est arrêté — un démarrage concurrent de
  # la fin (auto-démarrage d'une scène rechargée, piste publiée au dernier
  # moment) ne laisse aucun egress tourner après le direct.
  #
  # Accord à l'image : une piste séparée dont la
  # personne n'a plus d'accord en cours est arrêtée — défense en profondeur,
  # ConsentWithdrawal l'arrête déjà au retrait.
  #
  # Peut être invoqué à la main (rails runner) pour rattraper un
  # incident : `RecordingSession.reconcile(Webinar.find_by!(slug: '...'))`.
  #
  # @param webinar [Webinar]
  # @param client  [#list_egress, #stop] injection tests (default = factory)
  # @return [Integer] nombre de Recordings transitionnés (0 = tout est cohérent)
  def self.reconcile(webinar, client: default_client)
    transitioned = 0
    webinar.recordings.active.find_each do |rec|
      transitioned += 1 if reconcile_recording(rec, client: client)
    end
    transitioned + stop_capturing_after_end(webinar, client: client) + stop_tracks_without_consent(webinar, client: client)
  end

  # @return [Integer] nombre de pistes dont l'arrêt a été demandé
  def self.stop_tracks_without_consent(webinar, client:)
    webinar.recordings.tracks.capturing.to_a.count do |rec|
      next false if ParticipantConsent.covers?(webinar, rec.participant_identity)

      TrackRecordingSession.stop(rec, client: client) != :inactive
    end
  end

  # @return [Integer] nombre de Recordings dont l'arrêt a été demandé
  def self.stop_capturing_after_end(webinar, client:)
    return 0 unless webinar.reload.ended?

    webinar.recordings.from_egress.capturing.to_a.count do |rec|
      Rails.logger.warn("[recording_session] Recording #{rec.id} encore actif après la fin du direct webinar=#{webinar.slug} — arrêt")
      Rails.error.report(CapturingAfterEnd.new("Recording #{rec.id} (#{rec.kind})"),
                         handled: true, severity: :warning, source: "recording_session")
      stop(rec, client: client) != :inactive
    end
  end

  # Au-delà, un démarrage sans egress_id ne recevra plus de réponse : les
  # appels distants qui le précèdent (create_room, start) expirent en
  # 10 s chacun (timeout Faraday du SDK livekit).
  START_ANSWER_TIMEOUT = 2.minutes

  # @return [Boolean] true si la ligne a été transitionnée, false sinon.
  def self.reconcile_recording(rec, client:)
    return expire_unanswered_start(rec) if rec.egress_id.blank?

    info = client.list_egress(egress_id: rec.egress_id)

    # nil = livekit ne connaît pas cet egress (GC'd depuis longtemps, id
    # invalide, ou incohérence après un rebuild container). On considère
    # que l'enregistrement est perdu — on marque failed avec un message
    # explicite plutôt que de laisser un fantôme éternel.
    if info.nil?
      rec.update!(
        status:        :failed,
        error_message: "egress introuvable côté livekit-server (id=#{rec.egress_id}) — état DB corrigé",
        ended_at:      rec.ended_at || Time.current
      )
      return true
    end

    case info[:status]
    when :complete
      # Une piste ne passe done qu'avec son fichier vérifié, porté par le
      # webhook egress_ended : le poll la laisse en stopping.
      if rec.track?
        return false if rec.stopping?

        rec.update!(status: :stopping)
        return true
      end
      rec.update!(status: :done, ended_at: rec.ended_at || Time.current)
      true
    when :ending
      # En cours d'arrêt côté serveur — on garde `stopping` en DB (mapping
      # naturel). Si on n'était pas déjà stopping, on transitionne.
      if rec.stopping?
        false
      else
        rec.update!(status: :stopping)
        true
      end
    when :failed, :aborted, :limit_reached
      rec.update!(
        status:        :failed,
        error_message: [ info[:error], "egress #{info[:status]} côté serveur" ].compact.reject(&:blank?).first,
        ended_at:      rec.ended_at || Time.current
      )
      true
    when :active
      return false unless rec.starting?

      # Écriture conditionnelle : la ligne a été lue AVANT l'appel distant,
      # un arrêt concurrent ne doit pas être réécrit en `recording`.
      Recording.where(id: rec.id, status: "starting").update_all(status: "recording", updated_at: Time.current) == 1
    else # :starting (ou statut inconnu) → rien à corriger
      false
    end
  rescue EgressClient::Error => e
    Rails.logger.warn(
      "[reconcile] egress_id=#{rec.egress_id} err=#{e.class}: #{e.message} — Recording laissé en l'état"
    )
    false
  end

  # Démarrage resté sans egress_id (timeout Faraday non traduit par
  # EgressClient, processus ou job tué) : rien ne le fera plus aboutir, et
  # il bloquerait la scène sur « Démarrage… » comme l'index unique sur tout
  # nouveau composite. Vaut pour le composite et les pistes (un egress_ended
  # tardif reste rattrapable par FinalizeEgressJob) ; le montage participant,
  # sans egress par nature, n'est pas concerné. Écriture conditionnelle :
  # une réponse de start arrivée entre-temps l'emporte.
  def self.expire_unanswered_start(rec)
    return false if rec.participant? || !rec.starting?
    return false if rec.started_at.nil? || rec.started_at > START_ANSWER_TIMEOUT.ago

    message = "démarrage sans réponse du serveur d'enregistrement (> #{START_ANSWER_TIMEOUT.in_minutes.to_i} min) — état DB corrigé"
    Recording.where(id: rec.id, status: "starting", egress_id: nil)
             .update_all(status: "failed", error_message: message, ended_at: Time.current, updated_at: Time.current) == 1
  end

  # Arrête un Recording actif (starting|recording). No-op sur un
  # Recording déjà terminé (retourne :inactive).
  #
  # @param recording [Recording]
  # @param client [#stop]
  # @return [Symbol] :ok, :failed, :inactive
  #
  # Arrêt du composite : si l'opération ferme la fenêtre
  # d'enregistrement (webinaire pas live), les pistes individuelles
  # encore actives sont stoppées en cascade. Sans ça, le parcours
  # observé en direct (composite démarré/arrêté en draft)
  # laisserait toute piste rattrapée tourner jusqu'à `end_live`, qui
  # peut ne jamais arriver. Idempotent : TrackRecordingSession.stop
  # ignore une piste déjà terminée.
  def self.stop(recording, client: default_client)
    return TrackRecordingSession.stop(recording, client: client) if recording.track?
    return :inactive unless recording.recording? || recording.starting?

    recording.update!(status: :stopping)

    result = begin
      client.stop(egress_id: recording.egress_id) if recording.egress_id.present?
      recording.update!(status: :done, ended_at: Time.current)
      :ok
    rescue EgressClient::Error => e
      Rails.logger.error(
        "[recording_session] stop failed egress_id=#{recording.egress_id} err=#{e.class}: #{e.message}"
      )
      recording.update!(status: :failed, error_message: e.message, ended_at: Time.current)
      :failed
    end

    cascade_stop_tracks_if_window_closed(recording.webinar, client: client)
    result
  end

  # Après l'arrêt d'un composite, si la fenêtre d'enregistrement est
  # fermée (plus aucun composite actif ET webinaire pas live), on
  # arrête toutes les pistes individuelles encore actives — invariant
  # miroir de recording_window_open?. Appelée aussi par stop_all en
  # fin de direct (idempotent : les tracks déjà stoppées ignorent).
  def self.cascade_stop_tracks_if_window_closed(webinar, client:)
    return unless webinar

    return if TrackRecordingSession.recording_window_open?(webinar.reload)

    webinar.recordings.active.tracks.find_each do |track|
      TrackRecordingSession.stop(track, client: client)
    end
  end

  # Arrête TOUS les enregistrements egress actifs du webinaire (un montage
  # participant en cours poursuit) — chaque stop est tenté (jamais
  # court-circuité par un échec précédent), les erreurs sont collectées.
  # Appelé par LiveEnding (fin du direct) pour que la transition
  # `live → ended` s'applique quand même.
  #
  # @return [Array<Hash>] [{recording:, result: :ok|:failed|:inactive}, …]
  def self.stop_all(webinar, client: default_client)
    webinar.recordings.from_egress.active.map do |rec|
      { recording: rec, result: stop(rec, client: client) }
    end
  end

  def self.default_client
    Rails.configuration.x.egress_client_factory.call
  end
end
