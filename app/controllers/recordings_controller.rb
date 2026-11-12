class RecordingsController < ApplicationController
  # Enregistrements du direct (egress LiveKit).
  #
  # 3 endpoints animateur (host-only, isolé par host_sub) :
  #   • POST   /webinars/:webinar_id/recordings                → start egress
  #   • POST   /webinars/:webinar_id/recordings/:id/stop       → stop egress
  #   • GET    /webinars/:webinar_id/recordings                → liste + UI
  #   • GET    /webinars/:webinar_id/recordings/:id/download   → send_file
  #
  # Autorisation : `authenticate_animateur!` (session Pocket ID) puis
  # SCOPE par host_sub — l'accès à un webinaire d'un autre animateur =
  # 404 (défense énumération, cf. WebinarsController#show).
  #
  # Fail-loud : toute erreur egress (creds, twirp, réseau) transitionne le
  # Recording en `failed` avec `error_message`, ET propage à l'UI (flash
  # ou JSON payload). Jamais de faux succès.

  include AnimateurBrowserPolicy

  # Conteneurs que l'egress écrit : composite MP4, pistes H264→MP4,
  # VP8→WebM, Opus→Ogg (toujours audio seul).
  MEDIA_TYPES = {
    ".mp4"  => "video/mp4",
    ".m4a"  => "audio/mp4",
    ".webm" => "video/webm",
    ".ogg"  => "audio/ogg"
  }.freeze
  before_action :authenticate_participant!
  before_action :set_webinar
  before_action :set_recording, only: %i[stop download]

  # done_when : "Le listing n'expose les fichiers qu'à l'animateur du
  # webinaire" — set_webinar (scope host_sub) fait le travail : un
  # animateur qui GET /webinars/<slug d'un autre>/recordings reçoit un
  # 404 avant même d'atteindre cette action.
  # Le composite (direct mixé) d'abord, puis un bloc par
  # personne avec ses pistes séparées (caméra, micro, écran).
  def index
    @recordings = @webinar.recordings.composite.recent_first
    @active_recording = @webinar.recordings.active.composite.first
    @tracks_by_participant = @webinar.recordings.tracks.recent_first.group_by(&:participant_identity)
    # Accord de chaque personne pour les extraits et shorts
    # (ce qui sert au montage).
    @excerpt_consents = ExcerptConsents.new(@webinar)
    @participant_names = participant_names(@tracks_by_participant.keys | @excerpt_consents.identities)
    # Montage par personne — Recordings synthétiques `kind='participant'` : un
    # montage par lot de pistes d'une personne (répétition, séance, reprise du
    # direct), le plus récent d'abord.
    @participant_muxes = @webinar.recordings.participants
                                  .group_by(&:participant_identity)
    # Le lien transcript (.txt) n'apparaît que si au moins un
    # segment existe — pas de bouton qui téléchargerait un fichier vide.
    @has_transcript = @webinar.transcript_segments.exists?
  end

  # done_when 'start_stop_egress' : la première moitié.
  # Retour HTML = redirect vers #index (formulaire HTML) ; échec HTML =
  # redirect avec flash[:alert] pour rendre l'erreur visible (invariant
  # fail-loud). Retour JSON = état du recording actif après tentative,
  # consommé par <RecordingControl> côté scène.
  #
  # Logique egress extraite dans `RecordingSession`,
  # partagée avec WebinarStatesController#go_live et
  # WebinarsController#stage (auto-start).
  def create
    # Réconciliation d'abord : un « actif » fantôme (egress terminé
    # côté serveur, DB en retard) ne DOIT PAS empêcher un start
    # légitime. reconcile ferme le reliquat, puis on décide.
    RecordingSession.reconcile(@webinar, client: egress_client)

    # Direct terminé : rien ne capte après la fin. On
    # enregistre de nouveau en REPRENANT le direct, jamais par un composite
    # isolé qui tournerait sans pistes ni fin programmée.
    refusal = if @webinar.ended?
      "Direct terminé : reprenez le direct pour enregistrer de nouveau."
    elsif @webinar.recordings.active.composite.exists?
      "Un enregistrement est déjà en cours pour ce webinaire."
    end
    if refusal
      respond_to do |format|
        format.html { redirect_to webinar_recordings_path(@webinar), alert: refusal }
        format.json { render json: recording_status_payload, status: :conflict }
      end
      return
    end

    # start_composite est SAFE : il rescue RecordNotUnique et retourne
    # l'existant en cas de course perdue (bloquant #3). Aucun 500 possible
    # sur cet appel — l'échec egress reste PORTÉ par le Recording (failed).
    recording = RecordingSession.start_composite(@webinar, client: egress_client)
    # Rattrapage pistes (cas réel) : si l'animateur
    # démarre le composite SANS passer en direct (parcours observé :
    # webinaire en draft, composite OK, 0 piste), on interroge
    # la salle maintenant que la fenêtre est ouverte — idempotent par
    # l'index unique sur la piste active.
    TrackRecordingSession.backfill(@webinar, room_client: room_service_client) if recording && !recording.failed?

    respond_to do |format|
      format.html do
        if recording.failed?
          redirect_to webinar_recordings_path(@webinar),
                      alert: "Échec démarrage enregistrement : #{recording.error_message}",
                      status: :see_other
        else
          redirect_to webinar_recordings_path(@webinar), notice: "Enregistrement démarré."
        end
      end
      format.json do
        # 200 même si egress a échoué : le payload PORTE l'erreur (status
        # :failed + error_message). Le client doit AFFICHER le message,
        # jamais retenter en boucle sur un 500 muet.
        render json: recording_status_payload
      end
    end
  end

  # done_when 'recording_status_endpoint' — GET .../recordings/status.json.
  # Endpoint léger consommé par <RecordingControl> pour le poll côté scène.
  # Toujours 200 : `recording: null` = aucun recording en cours ; sinon
  # le bloc {id, status, error_message, stop_url}. La liste complète
  # (index) reste HTML pour la page recordings — pas de duplication de
  # contrat.
  #
  # RÉCONCILIATION au poll : on
  # relit l'état côté livekit-server pour tout Recording actif avant de
  # sérialiser — un egress terminé côté serveur (source closed, timeout
  # room, échec) fait transitionner la DB puis le payload reflète l'état
  # réel. Le poll (5 s côté React) converge donc sans intervention.
  def status
    RecordingSession.reconcile(@webinar, client: egress_client)
    render json: recording_status_payload
  end

  # done_when 'start_stop_egress' : la seconde moitié.
  # POST (jamais GET — action mutative). Route dédiée `stop` par choix :
  # DELETE serait ambigu (on ne supprime PAS le Recording, on l'arrête).
  #
  # Logique egress extraite dans `RecordingSession#stop`.
  def stop
    # Un intervenant n'arrête que SA piste : le lien speaker donne le
    # pilotage du composite, jamais celui des pistes des autres.
    # 404 plutôt que 403 : pas d'énumération.
    head :not_found and return unless track_stoppable_by_participant?

    unless @recording.recording? || @recording.starting? || (@recording.track? && @recording.stopping?)
      # Second clic sur « Arrêter » : le
      # premier a déjà clos l'enregistrement. En JSON, 409 + état réel —
      # une redirection deviendrait côté fetch un faux « session expirée ».
      respond_to do |format|
        format.html do
          redirect_to webinar_recordings_path(@webinar),
                      alert: "Enregistrement non actif (statut : #{@recording.status})."
        end
        format.json { render json: recording_status_payload, status: :conflict }
      end
      return
    end

    result = RecordingSession.stop(@recording, client: egress_client)
    @recording.reload

    respond_to do |format|
      format.html do
        if result == :failed
          redirect_to webinar_recordings_path(@webinar),
                      alert: "Échec arrêt enregistrement : #{@recording.error_message}",
                      status: :see_other
        elsif result == :pending
          redirect_to webinar_recordings_path(@webinar), notice: "Arrêt demandé ; confirmation distante en attente."
        else
          redirect_to webinar_recordings_path(@webinar), notice: "Enregistrement arrêté."
        end
      end
      format.json do
        # Le stop réussi transitionne recording→done ; un échec reste PORTÉ
        # par le payload (status :failed + message).
        render json: recording_status_payload
      end
    end
  end

  # Téléchargement streamé — send_file, path VALIDÉ (défense en profondeur :
  # (a) Recording#absolute_path exige préfixe `<webinar.slug>/` + reste sous
  # recordings_root (test unitaire), (b) ici on reconstruit via
  # File.expand_path(rel, root) — brakeman reconnaît ce pattern comme borné,
  # et le check start_with? refuse tout traversal résiduel.
  # Export plat du transcript multi-locuteur. Un fichier .txt
  # UTF-8, lignes `[HH:MM:SS] Nom : texte`, chronologique. Host-only
  # (authenticate_participant! fallback → animateur ; les intervenants
  # signés ne sont PAS whitelistés sur transcript — l'export est un
  # artefact d'archive, pas une commande salle).
  def transcript
    body = TranscriptSegment.formatted_text(@webinar.transcript_segments.chronological)
    filename = "transcript-#{@webinar.slug}.txt"
    send_data body,
              type: "text/plain; charset=utf-8",
              disposition: "attachment",
              filename: filename
  end

  def download
    path = safe_download_path
    if path.nil? || !File.file?(path)
      head :not_found and return
    end

    # send_file (pas send_data) → streamé via X-Sendfile si configuré, chunké
    # sinon. `disposition: attachment` force le download plutôt qu'un rendu
    # inline navigateur.
    # Une piste garde son conteneur natif (.mp4/.webm/.ogg) : le type suit
    # l'extension réelle, jamais un video/mp4 supposé.
    send_file path,
              type: MEDIA_TYPES.fetch(File.extname(path), "application/octet-stream"),
              disposition: "attachment",
              filename: File.basename(path)
  end

  private

  # Auth couple animateur / intervenant.
  #
  # Cas réel observé en direct : l'animateur anime EN PRATIQUE via
  # `/w/:slug/join?t=<token>` (identité LiveKit `host-b28b5bdb…` observée
  # ce jour depuis /join). Contraindre le pilotage recording à
  # l'animateur signé Pocket ID interdit à toute la route réelle des
  # webinaires — donc, dans les faits, à l'animateur — de démarrer/arrêter le
  # direct depuis la salle. Deux rôles ont un droit LÉGITIME au pilotage :
  #   • l'animateur signé (session Pocket ID, scope host_sub) ;
  #   • l'intervenant validé par un token de purpose:webinar/speaker
  #     via `Webinar.find_for_speaker(slug:, token:)` — MÊME contrat que
  #     RoomParticipant#resolve_role, sécurité re-validée à
  #     CHAQUE appel côté serveur (invariant re-signature).
  #
  # Actions concernées :
  #   • index / download : animateur SEULEMENT (privilège de lecture,
  #     archives et bibliothèque du direct — pas un contrôle en scène).
  #   • create / stop / status : animateur OU intervenant.
  #
  # Un token invalide + aucune session → fallback authenticate_animateur!
  # → redirect_to sign_in (comportement conservé pour les tests existants
  # anonyme→sign_in ; le porteur d'un token valide n'atteint jamais ce
  # fallback).
  def authenticate_participant!
    # L'export transcript reste host-only (jamais via lien speaker).
    if action_name.in?(%w[create stop status]) && speaker_token_valid?
      # Token accepté — bypass authenticate_animateur! (aucune session
      # requise). @participant_webinar est posé pour set_webinar.
      return
    end
    authenticate_animateur!
  end

  # Valide `params[:t]` contre le slug de l'URL — même contrat que
  # WebinarsController#join et RoomParticipant#resolve_role. En
  # cas d'échec, false (l'appelant décide du fallback : ici on retombe
  # sur authenticate_animateur!).
  def speaker_token_valid?
    token = params[:t].to_s
    return false if token.blank?

    result = Webinar.find_for_speaker(slug: params[:webinar_id], token: token)
    return false unless result

    @participant_webinar = result[0]
    @participant_speaker = result[1]
    true
  end

  # Scope host_sub — un webinaire qui n'appartient pas à `current_user`
  # remonte 404 (jamais 403 : la vue de `403 vs 404` révèle l'existence).
  # Le test `download_rejects_non_host` couvre le cas.
  #
  # Si l'auth speaker a réussi (`@participant_webinar` posé), on utilise
  # ce webinaire tel quel — Webinar.find_for_speaker a DÉJÀ borné à un
  # slug spécifique (l'invariant de re-signature côté serveur).
  #
  # Distinction de CAPACITÉ selon l'action.
  #   • index / download / transcript = LIRE l'archive → `where_managed_by`
  #     (owner / project_host). Un invité connecté reçoit 404
  #     (« PAS d'accès aux enregistrements, aux transcripts »).
  #   • create / stop / status = pilotage TEMPS RÉEL → `where_animated_by`
  #     (owner / project_host / guest_host) — l'invité démarre et arrête
  #     l'enregistrement de SON direct.
  def set_webinar
    if @participant_webinar
      @webinar = @participant_webinar
    else
      scope = if action_name.in?(%w[create stop status])
        Webinar.where_animated_by(current_user)
      else
        Webinar.where_managed_by(current_user)
      end
      @webinar = scope.find_by!(slug: params[:webinar_id])
    end
  end

  def set_recording
    @recording = @webinar.recordings.find(params[:id])
  end

  # Identité LiveKit de `identities` → nom lisible : l'animateur
  # propriétaire, les co-animateurs connectés (identité `host-<sub>` distincte), les intervenants nominatifs
  # (révoqués compris : leurs pistes passées restent nommées), puis les
  # spectateurs à qui la parole a été donnée.
  def participant_names(identities)
    names = { "host-#{@webinar.host_sub}" => "Animateur" }
    host_subs = identities.filter_map { |id| id[/\Ahost-(.+)\z/, 1] }
    User.where(oidc_sub: host_subs).each do |u|
      names["host-#{u.oidc_sub}"] = u.oidc_sub == @webinar.host_sub ? "Animateur" : (u.email.presence || "Animateur")
    end
    @webinar.speakers.each { |speaker| names["speaker-#{speaker.id}"] = speaker.name }
    viewer_ids = identities.filter_map { |identity| identity[/\Aviewer-(\d+)\z/, 1] }
    @webinar.registrations.where(id: viewer_ids).each do |registration|
      names["viewer-#{registration.id}"] = "#{registration.name} (spectateur)"
    end
    names
  end

  def track_stoppable_by_participant?
    return true unless @recording.track? && @participant_webinar

    @participant_speaker.present? &&
      @recording.participant_identity == "speaker-#{@participant_speaker.id}"
  end

  # Injection via Rails.configuration.x pour permettre le stub en test
  # (test_helper pose un fake EgressClient sur la classe). En prod le
  # défaut instancie la vraie classe qui lit ENV.
  def egress_client
    Rails.configuration.x.egress_client_factory.call
  end

  def room_service_client
    Rails.configuration.x.room_service_client_factory.call
  end

  # Contrat JSON consommé par <RecordingControl> (React, scène animateur).
  #
  # `recording` = le composite (« vue d'ensemble ») le plus pertinent, ou
  # null : JAMAIS une piste ni un montage participant. Le bouton pilote le
  # composite ; lui montrer une piste faisait mentir la scène (constat en
  # direct : « REC (démarrage) » affiché pendant le montage ffmpeg d'après
  # direct, « Arrêter » qui stoppait la piste d'une seule personne). Un
  # `failed` reste visible jusqu'au prochain démarrage.
  #
  # `stop_url` inclus SEULEMENT quand la transition stop est légitime
  # (starting|recording) — le client ne peut pas construire l'URL en
  # dur (l'id n'est pas connu du front sans ce champ).
  #
  # `tracks_recording` = nombre de pistes individuelles en captation, tous
  # participants : la scène distingue « vue d'ensemble en échec, pistes
  # individuelles en cours » d'un échec total.
  def recording_status_payload
    composite = displayed_composite
    {
      recording: composite ? serialize_recording(composite) : nil,
      tracks_recording: @webinar.recordings.tracks.capturing.count,
      # Direct terminé : la scène ne propose plus d'enregistrer (create
      # refuse, cf. ci-dessus).
      webinar_state: @webinar.state,
      # Consentement : une personne
      # est enregistrée si un composite tourne (toute piste qu'elle
      # publie est captée dans le mix) OU si une piste de SON identité
      # est active. `recording:` ne regarde que le composite : le flag
      # garde la pastille allumée quand ses pistes tournent encore (en
      # direct, l'arrêt du composite ne ferme pas la fenêtre des pistes).
      participant_recording: participant_being_recorded?
    }
  end

  # Identité LiveKit du consommateur courant du endpoint :
  #   • animateur (session Pocket ID) → host-<sub>
  #   • intervenant (token speaker ?t=) → speaker-<id>
  # Nil quand on ne peut PAS décider (jamais utilisé en production : les
  # before_actions garantissent l'une des deux voies).
  def current_participant_identity
    return "speaker-#{@participant_speaker.id}" if @participant_speaker
    return "host-#{current_user.oidc_sub}"      if current_user&.oidc_sub.present?

    nil
  end

  def participant_being_recorded?
    composite_active = @webinar.recordings.active.composite.exists?
    identity = current_participant_identity
    track_active = identity.present? &&
      @webinar.recordings.active.tracks.where(participant_identity: identity).exists?
    composite_active || track_active
  end

  # Composite ACTIF d'abord, sinon le plus récent (jamais un composite terminé qui masquerait l'actif).
  def displayed_composite
    composites = @webinar.recordings.composite
    composites.active.recent_first.first || composites.recent_first.first
  end

  def serialize_recording(rec)
    stoppable = Recording::CAPTURING_STATUSES.include?(rec.status.to_s)
    # Propage le token speaker éventuel dans stop_url : l'intervenant
    # doit pouvoir arrêter avec les mêmes credentials que ceux qui lui
    # ont permis le start. Le token sera RE-VALIDÉ côté serveur au POST
    # /stop (jamais confiance dans l'URL présentée par le client).
    stop_params = { t: params[:t].presence }.compact
    {
      id:            rec.id,
      status:        rec.status,
      error_message: rec.error_message,
      stop_url:      stoppable ? stop_webinar_recording_path(@webinar, rec, **stop_params) : nil
    }
  end

  # Résolution du chemin fichier pour download — reconstruction locale au
  # controller (jamais un attribut modèle passé directement à send_file).
  # File.expand_path(relative, absolute_root) borne littéralement le
  # résultat sous une racine trusted. Le check start_with? refuse tout
  # `..` évalué qui ferait sortir du dossier du webinaire.
  #
  # Deux sous-arbres légitimes :
  #   • composite / track → `<RECORDINGS_ROOT>/<slug>/…` (écrit par
  #     l'egress LiveKit) ;
  #   • participant mux → `<RECORDINGS_ROOT>/_participants/<slug>/…`
  #     (écrit par Rails ; dossier egress en 0750 bloquait ffmpeg). Le
  #     préfixe `_participants` commence par `_` qui est hors du regex
  #     de slug Webinar → aucune collision possible avec un slug légitime.
  # Le préfixe autorisé est dérivé du `kind` du Recording — jamais du
  # path lui-même, pour que le check reste défensif en profondeur
  # (invariant partagé avec `Recording#absolute_path`).
  def safe_download_path
    return nil if @recording.path.blank?

    base         = Recording.recordings_root.to_s
    allowed_root = @recording.kind.to_s == "participant" ?
      File.expand_path(File.join(Recording::PARTICIPANTS_SUBDIR, @webinar.slug), base) :
      File.expand_path(@webinar.slug, base)
    full         = File.expand_path(@recording.path.to_s, base)

    return nil unless full.start_with?("#{allowed_root}/")

    full
  end
end
