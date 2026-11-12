class WebinarsController < ApplicationController
  include CurrentRegistration
  include PresenceCapture
  # (CRUD) et rendu HTML des 3 pages salle.
  # Un seul controller par CHOIX DÉLIBÉRÉ : la logique "webinaire" (find,
  # autorisation par host_sub, résolution slug → webinar) est cohésive.
  #
  # LES PAGES SALLE (stage/viewer/join) RENDENT HTML — le token LiveKit
  # n'est PLUS servi ici (leçon initiale : émettre HTML+token en même temps
  # ouvrait la porte à un data-attr modifiable). Le composant React
  # (`app/javascript/rooms/room.jsx`) appelle POST /api/token au montage,
  # et le rôle est DÉCIDÉ SERVEUR (RoomParticipant#resolve_role, appelé par Api::TokensController).

  # Auth animateur exigée pour tout ce qui touche la table (CRUD) ET pour
  # la scène (le host doit être identifié pour recevoir un token roomAdmin).
  # Public : viewer (inscription requise pour la salle) et join (speaker signé — auth par TOKEN,
  # pas par session).
  # Pages salle (viewer/join/stage) ET aperçu `show` rendent HTML, point.
  # Cas réel : un aperçu WhatsApp (`User-Agent: WhatsApp/2`,
  # `Accept: application/json`) sur `/w/:slug/join` provoquait 500
  # ActionView::MissingTemplate puis ErrorsController 500 à nouveau.
  # On répond 406 pour tout format non HTML — pas de rendu partiel, pas
  # d'exception.
  before_action :require_html_format, only: [ :show, :viewer, :join, :stage ]
  before_action :authenticate_animateur!, except: [ :viewer, :join ]
  # Création d'un webinaire = animateur du projet seulement
  # (« ANIMATEURS INVITÉS … PAS
  # d'accès … ni à la création de webinaires »). 404 pour un invité
  # connecté (défense énumération).
  before_action :authorize_project_host!, only: [ :new, :create ]

  # Pages salle = layout `room` (plein écran, sans chrome) ; le reste
  # = layout `application` (chrome des pages animateur).
  layout :pick_layout

  # Garde navigateur :modern sur les pages animateur SEULEMENT — viewer et
  # join sont publics (cf. ApplicationController, AnimateurBrowserPolicy).
  def self.animateur_browser_policy_options
    { except: [ :viewer, :join ] }
  end
  include AnimateurBrowserPolicy

  # Le speaker link est signé par purpose (cf. Webinar#find_for_speaker) :
  # la protection CSRF classique n'a pas de sens (GET, action idempotente
  # côté serveur). Aucun skip explicite requis car GET est déjà exempt.

  def index
    # Un animateur du projet voit tout ; un propriétaire voit ses webinaires
    # et ceux où il est co-animateur ; un invité pur voit uniquement les
    # webinaires sur lesquels on l'a ajouté.
    @webinars = Webinar.where_animated_by(current_user).order(starts_at: :desc)
  end

  def new
    @webinar = Webinar.new(starts_at: 1.hour.from_now)
    @packs   = Pack.hosted_by(current_user.oidc_sub).order(:name)
  end

  def create
    @webinar = Webinar.new(webinar_params)
    # host_sub = identité Pocket ID courante — JAMAIS un input formulaire
    # (défense contre l'injection : sinon un animateur pourrait poser un
    # webinaire "au nom" d'un autre sub).
    @webinar.host_sub = current_user.oidc_sub

    # Défense pack_id : le select est peuplé côté server
    # avec les packs du host courant, mais un client peut POSTer un
    # `pack_id` arbitraire. Rendre 422 si le pack appartient à un autre
    # host (au lieu de 404, cohérent avec render :new — les autres champs
    # sont préservés dans le form).
    if webinar_params[:pack_id].present? &&
       !Pack.hosted_by(current_user.oidc_sub).exists?(id: webinar_params[:pack_id])
      @webinar.errors.add(:pack_id, :invalid)
      @packs = Pack.hosted_by(current_user.oidc_sub).order(:name)
      return render :new, status: :unprocessable_entity
    end

    if @webinar.save
      redirect_to webinar_path(@webinar), notice: "Webinaire créé."
    else
      @packs = Pack.hosted_by(current_user.oidc_sub).order(:name)
      render :new, status: :unprocessable_entity
    end
  end

  # Animator overview (owner / project_host / guest_host). Les sections
  # exposées côté vue sont filtrées par capacité :
  # un invité ne voit NI les inscrits, NI les enregistrements, NI les
  # intervenants, NI la liste des co-animateurs.
  def show
    @webinar = animated_scope.find_by!(slug: params[:id])
    @role = @webinar.role_for(current_user)
    @stage_url     = stage_webinar_url(slug: @webinar.slug)
    @spectator_url = public_webinar_url(slug: @webinar.slug)
    @my_attendance = @webinar.host_attendance_for(current_user)

    if @webinar.can_manage_speakers?(current_user)
      @speakers = @webinar.speakers.order(created_at: :asc, id: :asc)
    end
    if @webinar.can_manage_hosts?(current_user)
      @webinar_hosts = @webinar.webinar_hosts.order(created_at: :asc)
      @host_invitations = @webinar.host_invitations.order(created_at: :desc, id: :desc)
      @carryover_hosts = @webinar.carryover_hosts.to_a
      @presence_roster = @webinar.host_presence_roster
    end
    if @webinar.can_manage_recordings?(current_user)
      @publication = @webinar.episode_publication
      @publication_configured = EpisodePublication.configured_for?(@webinar)
      @publication_hold = EpisodePublication.automatic_hold(@webinar) if @publication_configured
      @videos_to_review = @publication_configured && @publication&.approvable?
    end
  end

  # Salle SCÈNE — page HTML pour animateur AUTHENTIFIÉ propriétaire du
  # webinaire. Le composant React monté appelle POST /api/token qui
  # ré-émet un token host à CHAQUE requête (invariant re-signature :
  # jamais de JWT figé dans un favori).
  #
  # AUTO-START enregistrement : dès que
  # l'animateur pose le pied sur la scène, on garantit qu'un Recording
  # actif existe — cas réel : direct lancé sans
  # egress, 2 min perdues à démarrer le recording via `rails runner`.
  # `ensure_active` est idempotent (garde applicative + index unique
  # partiel + rescue RecordNotUnique) : reload, 2e onglet, alt-tab retour
  # → aucun doublon. Un échec egress est PERSISTÉ (Recording :failed) et
  # remonté à la UI via /recordings/status.json + indicateur REC — la
  # page /stage rend TOUJOURS (le direct doit rester possible sans
  # enregistrement, invariant miroir de WebinarStatesController#go_live).
  def stage
    @webinar = animated_scope.find_by!(slug: params[:slug])
    @speaker_token = nil
    @regie_url = webinar_regie_path(@webinar)
    RecordingSession.ensure_active(@webinar)
    render_room
  end

  # Public page: confirmed viewers enter a live room; everyone else sees
  # the registration page. Draft visibility remains private to animators
  # (owner / project_host / guest_host).
  def viewer
    @webinar = Webinar.find_by!(slug: params[:slug])
    if @webinar.visibility_draft? && !@webinar.animated_by?(current_user)
      head :not_found and return
    end

    @voice = @webinar.voice
    registration = current_registration
    # Inscrit reconnu ; l'animation connectée entrera en host
    # (Api::TokensController) même si ce navigateur porte une inscription.
    if registration
      identity = @webinar.animated_by?(current_user) ? "host-#{current_user.oidc_sub}" : "viewer-#{registration.id}"
      note_presence_attempt(@webinar, "page_opened", identity)
    end
    @viewer_room = @webinar.live? && registration.present?
    if @viewer_room
      @speaker_token = nil
      # Inscrit qui n'a jamais choisi « J'observe » ou « Je participe » (site
      # partenaire qui ne transmet pas le choix…) : la salle le demande avant
      # d'entrer, une fois (ParticipationsController). Jamais à l'animation,
      # dont le jeton est host quelle que soit l'inscription du navigateur.
      @registration_to_ask = registration unless registration.participation_chosen? || @webinar.animated_by?(current_user)
      render :room
    else
      render :pre_live
    end
  end

  # Salle INTERVENANT — le lien nominatif ou signé est validé ICI (404
  # si altérée) ET REVALIDÉE côté /api/token (défense en profondeur : le
  # token qui atterrit dans le DOM ne suffit pas à obtenir un token
  # LiveKit speaker sans une seconde validation serveur).
  #
  # AUTO-START enregistrement :
  # même geste que sur /stage — l'animateur anime EN PRATIQUE via /join?t=…
  # (identité `host-<hex>` observée en production). Ne pas
  # auto-démarrer ici = même incident (2 min perdues, start
  # via `rails runner`) reproduit sur la route réelle. Idempotence
  # empilée : reconcile + garde applicative + validation modèle +
  # index unique partiel DB.
  def join
    # Grâce passée → nil ici, donc 404 AVANT ensure_active : un ancien lien
    # ne relance pas une captation. Pendant la grâce (et tant que le direct
    # est en cours), le lien résout et l'enregistrement est réconcilié.
    @webinar, @speaker = Webinar.find_for_speaker(slug: params[:slug], token: params[:t])
    if @webinar.nil?
      head :not_found and return
    end
    # Navigateur retiré de ce webinaire (RoomRemoval) : refusé, même avec un
    # lien valide. Ce GET ne pose aucun cookie d'identité : le jeton de l'URL
    # suffit pour entrer.
    return render_room_removed if room_removed?(@webinar)

    @speaker_token = params[:t]
    # Animateur connecté qui passe par son lien (cas réel) : son
    # jeton LiveKit est host (Api::TokensController), il a le lien vers la
    # régie. Un intervenant sans session animateur ne l'a pas. Au journal de
    # présence, la page est ouverte sous l'identité qui entrera.
    animator = @webinar.can_animate?(current_user)
    @regie_url = webinar_regie_path(@webinar) if animator
    note_presence_attempt(@webinar, "page_opened", animator ? "host-#{current_user.oidc_sub}" : "speaker-#{@speaker.id}")
    RecordingSession.ensure_active(@webinar)
    render_room
  end

  private

  # Scène ou lien intervenant d'un direct TERMINÉ : pas
  # de salle à rejoindre — l'animateur y était déconnecté aussitôt, sans explication.
  # La page dit que le direct est terminé, ce qui a été
  # enregistré (pour qui gère les enregistrements) et propose à l'animation
  # de le reprendre. `ensure_active` a déjà réconcilié : rien ne capte plus.
  def render_room
    return render(:room) unless @webinar.ended?

    @can_resume = @webinar.can_animate?(current_user)
    if @webinar.can_manage_recordings?(current_user)
      @composite_recordings = @webinar.recordings.composite.recent_first
      @participant_muxes = @webinar.recordings.participants.to_a
    end
    render :ended
  end

  # Layout dépendant de l'action ET, pour `viewer`, de l'état du webinaire :
  # la salle plein écran exige un direct et une inscription confirmée.
  # Hors live, `viewer` rend :pre_live sous le chrome standard.
  def pick_layout
    case action_name
    when "stage", "join"
      "room"
    when "viewer"
      @viewer_room ? "room" : "application"
    else
      "application"
    end
  end

  def webinar_params
    # Whitelist stricte : slug, state, host_sub, room_name NE SONT JAMAIS
    # settables par l'utilisateur (générés/injectés côté serveur).
    params.require(:webinar).permit(:title, :starts_at, :description, :visibility, :kind, :price_cents, :pack_id)
  end

  # Scope de résolution d'un webinaire animable par `current_user`. Point
  # d'entrée unique du contrôle d'accès CRUD/stage : si le user n'a aucun
  # rôle, le `find_by!` lève 404 (défense énumération, invariant du
  # reste de l'app).
  def animated_scope
    Webinar.where_animated_by(current_user)
  end

  # Les pages salle et l'aperçu rendent EXCLUSIVEMENT du HTML. Un
  # consommateur qui demande explicitement un autre format (aperçu de
  # lien WhatsApp/Gmail, scanner, Accept forgé) reçoit 406 — mieux
  # qu'un 500 MissingTemplate.
  def require_html_format
    return if request.format.html? || request.format.all?

    head :not_acceptable
  end
end
