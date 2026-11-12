class WebinarStatesController < ApplicationController
  # Cycle live du webinaire.
  #
  # 4 endpoints :
  #   • POST /webinars/:id/go_live  → draft → live, démarre l'egress composite
  #   • POST /webinars/:id/end      → live → ended, arrête TOUS les Recordings
  #   • POST /webinars/:id/resume → ended → live, les
  #                                   enregistrements repartent comme au go_live
  #   • GET  /w/:slug/state         → JSON public { state, starts_at, live_since }
  #
  # Auth :
  #   • go_live / end_live / resume = animateurs du webinaire
  #     (`authenticate_animateur!` + scope `where_animated_by`).
  #     Un non-animateur reçoit 404 (défense énumération, cohérent avec le reste).
  #   • show                = public, aucune auth ; visibility=draft ⇒ 404.
  #
  # Le nom d'action `end_live` (route `post :end, action: :end_live`) —
  # `def end` est un mot-clé Ruby.
  #
  # Fail-loud : un échec egress à l'ouverture du direct PERSISTE le
  # Recording en :failed + flash alerte, mais le webinaire passe QUAND MÊME
  # en :live (le direct ne dépend pas de l'enregistrement). Symétrique à
  # end_live : chaque stop est tenté (jamais court-circuité par une erreur
  # précédente), et la transition ended s'applique quand même.

  # `show` est public — pas de garde navigateur :
  # les pages spectateur restent servies à tous les navigateurs
  # que LiveKit sait faire tourner ; le state.json est consommé par la
  # même page).
  #
  # DOIT PRÉCÉDER `include AnimateurBrowserPolicy` : ActiveSupport::Concern
  # exécute le bloc `included do allow_browser ... **animateur_browser_policy_options end`
  # AU MOMENT de l'include ; la surcharge doit exister à ce moment-là,
  # sinon le splat capture la valeur par défaut du concern (`{}`) et la
  # garde `:modern` s'applique à TOUTES les actions (dont `show`) — un UA
  # ancien reçoit 406 sur /w/:slug/state.json au lieu du 200 attendu.
  # Pattern miroir de WebinarsController (correctif : déclarer la méthode
  # avant l'include).
  def self.animateur_browser_policy_options
    { only: [ :go_live, :end_live, :resume ] }
  end

  include AnimateurBrowserPolicy

  before_action :authenticate_animateur!, only: [ :go_live, :end_live, :resume ]
  before_action :set_host_webinar,        only: [ :go_live, :end_live, :resume ]

  # POST /webinars/:id/go_live — draft → live, puis enregistrements
  # (cf. open_recordings_and_redirect).
  def go_live
    @webinar.go_live!
    open_recordings_and_redirect("Direct démarré")
  rescue Webinar::TransitionError => e
    respond_with_transition_error(:go_live, e)
  end

  # POST /webinars/:id/resume — reprise d'un direct terminé (« j'ai même pas moyen de
  # remettre le truc en direct »). Les enregistrements reprennent par le
  # chemin de go_live, dans de NOUVEAUX fichiers : composite horodaté,
  # nouvelles pistes, nouveau montage par personne. Rien n'est écrasé.
  def resume
    @webinar.resume!
    open_recordings_and_redirect("Direct repris")
  rescue Webinar::TransitionError => e
    respond_with_transition_error(:resume, e)
  end

  # POST /webinars/:id/end — critère 'end_stops_recordings_fail_loud'.
  #
  # Chemin partagé avec la fin automatique (LiveEnding). La transition est
  # la garde d'entrée : un webinaire draft/ended avec
  # un Recording actif orphelin renvoie 409 SANS toucher aux enregistrements.
  # La transition ended reste appliquée quand un stop échoue (invariant
  # fail-loud) : les erreurs sont capturées par RecordingSession.stop_all et
  # portées par les résultats.
  def end_live
    results = LiveEnding.new(@webinar, egress_client: egress_client, room_client: room_service_client).call

    failed = results.select { |r| r[:result] == :failed }
    warnings = permission_warnings(@webinar).map { |warning| warning[:message] }
    if failed.any?
      messages = failed.filter_map { |r| r[:recording].reload.error_message }.uniq.join(" · ")
      redirect_to webinar_path(@webinar),
                  alert: ([ "Direct terminé, mais échec(s) d'arrêt d'enregistrement : #{messages}" ] + warnings).join(" "),
                  status: :see_other
    elsif warnings.any?
      redirect_to webinar_path(@webinar), alert: warnings.join(" "), status: :see_other
    else
      redirect_to webinar_path(@webinar), notice: "Direct terminé."
    end
  rescue Webinar::TransitionError => e
    respond_with_transition_error(:end_live, e)
  end

  # GET /w/:slug/state.json — critère 'public_state_endpoint'.
  # Draft visibility and operational warnings are private to the owning host.
  def show
    webinar = Webinar.find_by(slug: params[:slug])
    animator = webinar && webinar.animated_by?(current_user)
    if webinar.nil? || (webinar.visibility_draft? && !animator)
      head :not_found and return
    end

    payload = {
      state:      webinar.state,
      starts_at:  webinar.starts_at&.iso8601,
      live_since: webinar.started_at&.iso8601
    }
    # Les warnings opérationnels (permissions résiduelles) restent
    # réservés aux animateurs — un spectateur n'a rien à faire de ces
    # signaux.
    payload[:warnings] = permission_warnings(webinar) if animator
    response.headers["Cache-Control"] = "no-store"
    render json: payload
  end

  private

  def permission_warnings(webinar)
    unresolved = webinar.ended? && webinar.hand_raises.active.where(state: %w[granting granted revoking uncertain]).exists?
    return [] unless unresolved

    [ { code: "hand_permissions_uncertain",
        message: "Direct terminé, mais certaines autorisations de prise de parole n'ont pas pu être retirées. Réessayez leur révocation." } ]
  end

  # Scope d'animation (owner / project_host / guest_host) — un webinaire
  # sans rôle animable pour `current_user` remonte 404 (jamais 403 :
  # symétrie avec RecordingsController#set_webinar et
  # WebinarsController#show — révéler l'existence = leak).
  # Un invité contrôle go_live/end_live sur SES
  # webinaires.
  def set_host_webinar
    @webinar = Webinar.where_animated_by(current_user).find_by!(slug: params[:id])
  end

  # Transition refusée = état source incompatible (double go_live, end
  # sur draft/ended). Redirect + flash — un
  # `head :conflict` muet ne dit rien au host qui a double-cliqué ;
  # `redirect_to webinar_path(@webinar), status: :see_other` renvoie
  # 303 vers la page anime, où le layout affiche `flash[:alert]`. Le
  # code 409 se perd (redirect = 3xx) au profit de l'UX host — la
  # trace warning côté log conserve le signal pour l'opérateur.
  def respond_with_transition_error(action, error)
    Rails.logger.warn("[webinar_states##{action}] transition refused: #{error.message}")
    redirect_to webinar_path(@webinar),
                alert: "Transition refusée : #{error.message}",
                status: :see_other
  end

  # Cf. RecordingsController#egress_client — même hook d'injection
  # (Rails.configuration.x.egress_client_factory) pour permettre le stub
  # en test sans monkey-patch.
  def egress_client
    Rails.configuration.x.egress_client_factory.call
  end

  def room_service_client
    Rails.configuration.x.room_service_client_factory.call
  end

  # Ouverture du direct (go_live, reprise) — critère 'go_live_starts_recording'.
  #
  # Utilise `ensure_active` : si un Recording actif existe
  # déjà (typique : le host a d'abord visité /stage qui déclenche l'auto-
  # start), on RÉUTILISE l'existant au lieu de créer un doublon qui
  # violerait `only_one_active_composite`. « go_live démarre
  # l'enregistrement » se lit « go_live garantit qu'un enregistrement actif
  # existe ».
  #
  # Rattrapage pistes (cas réel) : un intervenant /
  # animateur qui a publié avant l'ouverture n'est jamais vu par le webhook
  # `track_published`. On interroge la salle maintenant que la fenêtre est
  # ouverte — idempotent par la revendication unique d'une piste active.
  def open_recordings_and_redirect(notice)
    recording = RecordingSession.ensure_active(@webinar, client: egress_client)
    TrackRecordingSession.backfill(@webinar, room_client: room_service_client)
    # Une reprise trouve la salle restée ouverte, sans le transcripteur
    # congédié à la fin (cas observé en production) : il est rappelé, comme à
    # l'ouverture.
    TranscriberPresenceJob.perform_later(@webinar.id)

    if recording && recording.failed?
      # Direct ouvert QUAND MÊME (invariant fail-loud) ; l'échec est
      # visible dans le flash + Recording failed listé côté recordings.
      redirect_to webinar_path(@webinar),
                  alert: "#{notice}, mais échec enregistrement : #{recording.error_message}",
                  status: :see_other
    else
      redirect_to webinar_path(@webinar), notice: "#{notice}."
    end
  end
end
