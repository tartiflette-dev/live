Rails.application.routes.draw do
  post "/webhooks/livekit", to: "webhooks/livekit#create"
  # Segments de transcript poussés par transcriber/.
  post "/webhooks/transcripts", to: "webhooks/transcripts#create"
  get "/webhooks/transcripts/enabled", to: "webhooks/transcripts#enabled"
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
  # Rapports de violation de la CSP (config/initializers/
  # content_security_policy.rb) : anonyme, borné, journal assaini.
  post "/csp-reports", to: "csp_reports#create", as: :csp_reports
  # Sonde de la synchro CRM (supervision, Bearer CRM_STATUS_TOKEN ; fermée
  # sans jeton) — docs/registrations-api.md §Sonde.
  get "/internal/crm_status", to: "internal/crm_status#show", as: :internal_crm_status
  # Files du relais de messagerie (jeton REGISTRATION_RELAY_TOKEN en en-tête ;
  # fermées sans jeton) — docs/registrations-api.md §Relais de messagerie : inscriptions
  # au groupe des co-organisateurs (chemins historiques `registration_messages`,
  # appelés tels quels par le relais), annonces à la communauté.
  get  "/internal/registration_messages/pending", to: "internal/registration_messages#pending",
                                                  as: :internal_pending_registration_messages
  post "/internal/registration_messages/:id/relayed", to: "internal/registration_messages#relayed",
                                                      as: :internal_relayed_registration_message,
                                                      constraints: { id: /\d+/ }
  # Annonces sous le même préfixe : une seule famille de points internes pour
  # le relais (même jeton, même base d'URL côté relais), sans nouveau préfixe à
  # ouvrir ni à documenter.
  get  "/internal/registration_messages/announcements/pending", to: "internal/community_announcements#pending",
                                                                as: :internal_pending_community_announcements
  post "/internal/registration_messages/announcements/:id/announced", to: "internal/community_announcements#announced",
                                                                      as: :internal_announced_community_announcement,
                                                                      constraints: { id: /\d+/ }

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # ------------------------------------------------------------
  # Auth animateur — Pocket ID OIDC.
  #
  # `POST /auth/pocket_id` = request phase (montée par le middleware
  # OmniAuth dans config/initializers/omniauth.rb, CSRF-safe via
  # `omniauth-rails_csrf_protection`). Retour = GET
  # `/auth/pocket_id/callback`.
  # ------------------------------------------------------------
  # Thème — bascule clair/sombre (cookie) et pages d'erreur hors-session
  # (exceptions_app → ErrorsController ; /erreur/:code = recette visuelle).
  post "theme", to: "themes#update", as: :theme
  get  "/erreur/:code", to: "errors#show", as: :erreur, constraints: { code: /\d{3}/ }

  get    "sign_in",                 to: "sessions#new",           as: :sign_in
  delete "sign_out",                to: "sessions#destroy",       as: :sign_out
  get    "/auth/pocket_id/callback", to: "sessions#oidc_callback", as: :oidc_callback
  get    "/auth/failure",            to: "sessions#oidc_failure",  as: :oidc_failure
  # Connexion de développement : 404 hors DevLogin (lib/dev_login.rb).
  post   "dev_login",               to: "sessions#dev_login",     as: :dev_login

  # ------------------------------------------------------------
  # CRUD animateur. `id` = slug (URL lisible, cf.
  # Webinar#assign_slug_and_room). Pas de destroy en v1 — refus d'ajouter
  # un chemin destructif sans use-case (YAGNI).
  # ------------------------------------------------------------
  resources :webinars, only: [ :index, :new, :create, :show ], param: :id do
    # Cycle live. Host-only, controller dédié
    # WebinarStatesController. `end_live` cible action Ruby renommée
    # (`def end` = mot-clé). URL conservée `/webinars/:id/end`.
    member do
      post :go_live, to: "webinar_states#go_live"
      post :end,     to: "webinar_states#end_live", as: :end
      post :resume,  to: "webinar_states#resume"
    end

    # Édition par le propriétaire : date, titre, description ; `unpublish` =
    # annuler (WebinarEditionsController).
    resource :edition, only: [ :show, :update ], controller: "webinar_editions" do
      post :unpublish
    end

    # Programme (sujet, intervenants annoncés, animateur du jour) : toute
    # l'animation (WebinarProgramsController).
    resource :program, only: [ :show, :update ], controller: "webinar_programs"

    # ------------------------------------------------------------
    # Enregistrements. Host-only (scoped par
    # host_sub côté controller). Le param `webinar_id` est le SLUG
    # (cf. WebinarsController), cohérent avec le param parent `:id`.
    #
    # `stop` = POST dédié (jamais DELETE — l'action ne supprime pas le
    # Recording, elle transitionne son status). `download` = GET streamé
    # avec path validé strictement (défense traversal).
    # ------------------------------------------------------------
    resources :recordings, only: [ :index, :create ] do
      member do
        post :stop
        get  :download
      end
      collection do
        # Consommé par <RecordingControl>
        # (scène animateur) — JSON, host-only via authenticate_animateur!
        # + scope host_sub côté controller. L'action `render json:` ignore
        # le format ; on n'active donc pas `defaults: { format: :json }`
        # qui ferait DISPARAÎTRE l'extension `.json` des URL générées
        # (comportement du url_generator Rails, cf. test).
        get :status
        # Export plat du transcript multi-locuteur (.txt).
        # Host-only, scope host_sub.
        get :transcript
      end
    end

    resources :hand_raises, only: [ :index ] do
      post :grant, on: :member
      post :revoke, on: :member
    end

    resources :speakers, only: [ :create, :update ] do
      post :revoke, on: :member
      post :regenerate, on: :member
    end

    # Publication de l'épisode dans Nextcloud :
    # lancer / relancer le dépôt (create), « Valider et partager » les
    # vidéos en relecture (update) depuis la page du webinaire.
    resource :publication, only: [ :create, :update ], controller: "webinar_publications"

    # Discussion du direct — panneau « Questions » de l'animation
    # (MessageModerationsController, scope where_animated_by). Le client
    # compose `<data-message-moderation-url>/<id>/<action>` (room.html.erb
    # pose le préfixe /webinars/:slug/messages) : garder cette forme.
    resources :messages, only: [], controller: "message_moderations" do
      member do
        post :answer
        post :pin
        post :unpin
      end
    end

    # Mise en avant d'un intervenant pendant le direct.
    # Animation seulement (controller) ; l'état est diffusé par les
    # métadonnées de la salle LiveKit.
    resource :spotlight, only: [ :create, :destroy ], controller: "webinar_spotlights"

    # Régie : les commandes du direct
    # dans un onglet à part, sans vidéo ; la salle de l'animation est
    # celle des participants. Animation seulement (controller).
    # `status` = lecture JSON de la salle LiveKit (présents, scène, mise
    # en avant) et de l'état du direct, relue par la page.
    resource :regie, only: [ :show ], controller: "webinar_regies" do
      get :status
    end

    # Modération du direct depuis la régie : couper
    # le micro ou retirer un participant désigné par son identité LiveKit
    # (`speaker-<id>`, `viewer-<id>` seulement). Animation seulement
    # (WebinarParticipantsController). Le client compose
    # `<data-participants-url>/<identité>/<action>` : garder cette forme.
    resources :participants, only: [], param: :identity, controller: "webinar_participants" do
      member do
        post :mute
        post :remove
      end
    end

    # File Q&R extraite du chat (QaItemsController) : console
    # de régie, animation seulement.
    resources :qa_items, only: [ :index, :create, :update ] do
      member { %i[answer dismiss reopen display hide].each { |action| post action } }
    end

    # ----------------------------------------------------------
    # Lien d'invitation intervenant PARTAGÉ.
    # Singleton host-only (généré/régénéré/désactivé sur /webinars/:id).
    # - POST    create  = génère OU régénère (invalide l'ancien)
    # - DELETE  destroy = désactive (NULL)
    # Régénération depuis la régie (`regeneration`, JSON) : toute l'animation,
    # co-animateur compris pendant le direct, et seulement un lien actif
    # (WebinarShareLinkRegenerationsController).
    # ----------------------------------------------------------
    resource :share_link, only: [ :create, :destroy ], controller: "webinar_share_links" do
      resource :regeneration, only: [ :create ], controller: "webinar_share_link_regenerations"
    end

    # Co-animateurs invités. CRUD minimal :
    # create / destroy. Owner et project_host seulement (controller).
    # `carry_over` = reprise, cochée, des co-animateurs du webinaire
    # précédent du même propriétaire (jamais automatique).
    resources :hosts, only: [ :create, :destroy ], controller: "webinar_hosts" do
      post :carry_over, on: :collection
    end

    # Liens animateur : création et révocation,
    # owner et project_host seulement (controller). La page publique est /a.
    resources :host_invitations, only: [ :create ], controller: "webinar_host_invitations" do
      post :revoke, on: :member
    end

    # `attendance` (JSON) : inscrits et présence dans la salle, relus par le
    # bloc « Inscrits » de la régie (RoomAttendance). Même périmètre que la
    # liste : propriétaire et animateurs du projet, jamais le co-animateur invité.
    resources :registrations, only: [ :index ], controller: "webinar_registrations" do
      get :attendance, on: :collection
    end

    # Page « Présence » (WebinarRoomPresencesController, PresenceTimeline) :
    # qui s'est connecté quand, courbe des présents, tentatives sans entrée.
    # Consultation seule, même périmètre que la liste des inscrits.
    resource :room_presence, only: [ :show ], controller: "webinar_room_presences"

    # Présence de l'animateur connecté (propriétaire ou co-animateur), sans
    # passer par le mail (WebinarPresencesController).
    resource :presence, only: [ :create ], controller: "webinar_presences"

    # Envois groupés (WebinarAnnouncementsController) : composer, aperçu
    # avec le nombre de destinataires, envoi confirmé, journal, reprise.
    # Seule voie d'envoi aux inscrits et aux listes : aucune API.
    resources :announcements, only: [ :index, :new, :create ], controller: "webinar_announcements" do
      post :preview, on: :collection
      post :resume, on: :member
    end

    # Replay réservé aux personnes identifiées, côté animation
    # (WebinarReplaysController) : publier, retirer, demander le montage
    # piloté par la parole, statistiques de visionnage. Propriétaire et
    # animateurs du projet seulement.
    resource :replay, only: [ :show ], controller: "webinar_replays" do
      post :publish
      post :unpublish
      post :montage
    end

    # Chapitres du replay (WebinarChaptersController) : relire, corriger et
    # valider la proposition du LLM local avant qu'elle soit montrée aux
    # spectateurs, en redemander une. Même animation que le replay.
    resource :chapters, only: [ :show, :update ], controller: "webinar_chapters" do
      post :propose
      post :unvalidate
    end

    # Sondages du direct, côté animation (PollsController) :
    # plan, lancement, résultats. Consommé par le composant régie
    # rooms/poll_console.jsx.
    resources :polls, only: [ :index, :show, :create, :update, :destroy ] do
      patch :reorder, on: :collection
      member do
        post :open
        post :close
        post :show_results
        post :hide_results
      end
    end
  end

  # ------------------------------------------------------------
  # 3 URLs webinaire.
  #
  # ORDRE IMPORTANT : /w/:slug/stage et /w/:slug/join AVANT /w/:slug
  # (Rails matche par ordre de déclaration ; sans ça `/w/foo/stage`
  # serait attrapé par `/w/:slug` avec slug="foo/stage").
  #
  #   /w/:slug/stage → scène animateur (auth, token host RE-SIGNÉ à
  #                    chaque hit : jamais de JWT figé dans un favori)
  #   /w/:slug/join  → intervenant (token signé Rails, purpose :speaker)
  #   /w/:slug       → spectateur public (pas d'auth, canPublish=false)
  # ------------------------------------------------------------
  # Replays : réservés à un compte connecté (tous les replays publiés) ou à
  # une inscription confirmée (le replay de son webinaire), cf. ReplayAccess.
  # Le lien personnel d'un inscrit est /w/:slug/replay?t=<jeton> : jeton en
  # query (filter_parameters), GET sans effet, accès ouvert au POST du
  # bouton (`access`). Vidéo servie avec contrôle d'accès et requêtes Range,
  # sous-titres WebVTT, battements du lecteur (ReplayViewsController).
  get  "/replays",                    to: "replays#index",          as: :replays
  get  "/w/:slug/replay",             to: "replays#show",           as: :public_webinar_replay
  post "/w/:slug/replay/acces",       to: "replays#access",         as: :public_webinar_replay_access
  get  "/w/:slug/replay/video",       to: "replay_media#video",     as: :public_webinar_replay_video
  get  "/w/:slug/replay/sous-titres.vtt", to: "replay_media#subtitles", as: :public_webinar_replay_subtitles,
                                          format: false
  post "/w/:slug/replay/battements",  to: "replay_views#create",    as: :public_webinar_replay_beats
  # Replay interactif : sondages du direct auxquels le spectateur répond,
  # questions ancrées à l'instant de la vidéo (ReplayInteraction). Toutes
  # les questions, direct et replay, côté animation : /questions.
  get  "/w/:slug/replay/sondages",    to: "replay_polls#index",     as: :public_webinar_replay_polls
  post "/w/:slug/replay/sondages/:id/reponses", to: "replay_polls#respond", as: :public_webinar_replay_poll_responses
  post "/w/:slug/replay/questions",   to: "replay_questions#create", as: :public_webinar_replay_questions
  get  "/questions",                  to: "questions#index",        as: :questions
  get "/w/:slug/stage", to: "webinars#stage",             as: :stage_webinar
  get "/w/:slug/join",  to: "webinars#join",              as: :join_webinar
  # /w/:slug/state.json = état public JSON. Doit
  # précéder /w/:slug (sinon `state` serait capturé comme slug=state).
  get "/w/:slug/state", to: "webinar_states#show",        as: :public_webinar_state,
                       defaults: { format: :json }
  # Agenda public : /agenda = page des dates,
  # /agenda.ics = ancien flux public, fermé (410), /w/:slug.ics = un seul
  # événement, déclaré AVANT /w/:slug : sinon `.ics` tomberait sur
  # webinars#viewer, qui ne rend que du HTML (406).
  # /agenda/next.json = prochaines dates en JSON, lu en cross-origin par
  # tartiflette.dev : chemin littéral, seul format, déclaré AVANT le flux
  # personnel /agenda/<jeton>.ics (jeton masqué des journaux, TokenPathMask).
  get "/agenda/next.json", to: "agenda#next_dates",       as: :agenda_next,
                          format: false, defaults: { format: :json }
  get "/agenda/:token",  to: "calendar_feeds#show",       as: :personal_agenda,
                          format: true, constraints: { format: :ics, token: /[A-Za-z0-9_-]+/ }
  get "/agenda",        to: "agenda#index",               as: :agenda
  get "/w/:slug",       to: "agenda#show",                as: :webinar_calendar,
                       format: true, constraints: { format: :ics }
  get "/w/:slug",       to: "webinars#viewer",            as: :public_webinar

  # ------------------------------------------------------------
  # API émission token LiveKit.
  #
  # POST /api/token — appelée par le composant React `rooms/room.jsx`
  # au montage. Rôle décidé SERVEUR (session animateur / lien speaker
  # signé / défaut viewer), un `role` param client est IGNORÉ (test
  # `token_endpoint_role_enforcement`).
  #
  # /!\ NE PAS définir de route `/rtc` ici — ce path est routé par
  # le proxy de déploiement (kamal-proxy) AVANT l'app, vers livekit-server
  # directement. Une route Rails `/rtc` casserait le signal.
  # ------------------------------------------------------------
  post "/api/token", to: "api/tokens#create", as: :api_token

  # Préférences de périphériques du participant courant.
  # Écriture seule : la lecture est
  # livrée avec le token. Propriétaire décidé SERVEUR (RoomParticipant).
  patch "/api/device_preferences", to: "api/device_preferences#update", as: :api_device_preferences

  # Accord à l'image du participant courant :
  # donné avant la première activation de la caméra ou du micro (POST),
  # retiré depuis la salle (DELETE). Porteur décidé SERVEUR (RoomParticipant).
  post   "/api/participant_consent", to: "api/participant_consents#create", as: :api_participant_consent
  delete "/api/participant_consent", to: "api/participant_consents#destroy"

  # Mesures de l'émetteur caméra de qui publie (toutes les 10 s) : alerte
  # régie sous 720p et diagnostic après coup. Auteur décidé SERVEUR
  # (RoomParticipant), écriture seule.
  post "/api/camera_samples", to: "api/camera_samples#create", as: :api_camera_samples

  # ------------------------------------------------------------
  # Packs animateur.
  # index / new / create seulement — pas de destroy (hors du périmètre des
  # packs : un pack n'est jamais supprimé depuis l'app), pas de show
  # (aucun use-case). Isolation par host_sub côté controller.
  # ------------------------------------------------------------
  resources :packs, only: [ :index, :new, :create ]

  # Vues transverses de l'animation du projet (animateurs du projet
  # seulement, authorize_project_host!) : thèmes abordés à travers les cafés,
  # journal des recherches des spectateurs, fiche d'une personne sur tous les
  # replays. `:id` d'une personne = « r<inscription> » ou « u<compte> »,
  # jamais son adresse dans l'URL.
  namespace :animation do
    get "themes",        to: "themes#index",   as: :themes
    get "recherches",    to: "searches#index", as: :searches
    get "personnes/:id", to: "people#show",    as: :person
  end

  # ------------------------------------------------------------
  # Racine — catalogue PUBLIC.
  # Anonyme = 200, liste les webinaires publiés en direct, en retard
  # puis à venir (cf. CatalogueController#index). La table animateur
  # reste sur /webinars (authenticate_animateur! côté WebinarsController,
  # inchangé).
  # ------------------------------------------------------------
  root "catalogue#index"

  # Politique de confidentialité — conditionne l'ouverture des inscriptions.
  get "/confidentialite", to: "legal#confidentialite", as: :confidentialite

  # Consentement : un spectateur à
  # qui on donne la parole publie une piste et doit voir l'indicateur
  # « enregistrement en cours ». GET read-only sur /w/:slug/recordings/status.json,
  # autorisé par le cookie d'inscription confirmée (CurrentRegistration).
  # Pas de stop_url ni de start_url — pilotage réservé au contrôleur
  # host-only /webinars/:webinar_id/recordings/status.
  get "/w/:slug/recordings/status", to: "public_webinar_recordings#status",
                                    as: :public_webinar_recording_status

  # Discussion du direct (MessagesController) : animateur, intervenant
  # nominatif ou inscription confirmée — décidé serveur à chaque appel.
  get "/w/:slug/messages", to: "messages#index", as: :public_webinar_messages
  post "/w/:slug/messages", to: "messages#create"
  # Sondages du direct, côté participants (PollParticipationsController) :
  # mêmes participants que la discussion ; pop-up rooms/poll_overlay.jsx.
  get  "/w/:slug/polls/current",       to: "poll_participations#current", as: :current_public_webinar_poll
  post "/w/:slug/polls/:id/responses", to: "poll_participations#respond", as: :public_webinar_poll_responses
  get "/w/:slug/qa/current", to: "qa_displays#show", as: :public_qa_display
  get "/w/:slug/hand_raises", to: "hand_raises#status", as: :public_hand_raises
  post "/w/:slug/hand_raises", to: "hand_raises#create"
  delete "/w/:slug/hand_raises", to: "hand_raises#destroy"
  # Choix « J'observe » / « Je participe » à l'entrée de la salle
  # (ParticipationsController) : l'inscription de ce navigateur seulement.
  patch "/w/:slug/participation", to: "participations#update", as: :public_webinar_participation
  post "/w/:slug/registrations", to: "registrations#create", as: :public_webinar_registrations
  # « Ce n'est pas moi » (ordinateur partagé, deuxième adresse) : ce
  # navigateur oublie son inscription à ce webinaire. POST seulement (CSRF),
  # ne lève jamais un retrait (NotMeController).
  post "/w/:slug/not_me", to: "not_me#create", as: :public_webinar_not_me
  # GET = page à bouton sans effet (déjà confirmée : accès direct), POST =
  # confirmation (scanners de liens). Le jeton du chemin est masqué des
  # journaux (config/initializers/registration_token_logging.rb).
  get  "/r/:token", to: "registrations#confirm", as: :confirm_registration
  post "/r/:token", to: "registrations#confirm_registration"

  # API d'inscription cross-origin (site statique partenaire,
  # docs/registrations-api.md). Le lien du mail est
  # `/confirmer?t=` : jeton en QUERY STRING (filter_parameters), GET sans effet
  # (scanners de liens), confirmation au POST du button_to.
  post  "/api/registrations", to: "api/registrations#create", as: :api_registrations
  match "/api/registrations", to: "api/registrations#preflight", via: :options
  get   "/confirmer", to: "registration_requests#show",    as: :registration_request
  post  "/confirmer", to: "registration_requests#confirm", as: :confirm_registration_request

  # ----------------------------------------------------------
  # Lien d'invitation intervenant partagé — URL publique.
  # Jeton opaque passé en PARAMÈTRE DE REQUÊTE `t` (pas
  # dans le chemin), cohérent avec /w/:slug/join?t= et neutralisé par
  # filter_parameters (/\At\z/) dans les logs RAILS seulement — un
  # segment de chemin, lui, serait écrit en clair dans la ligne
  # « Started GET "/i/<jeton>" » (filter_parameters ne couvre QUE la
  # query/body). filter_parameters ne couvre NI le proxy (son journal garde
  # la query `t=…` en clair) NI l'agent de collecte des journaux : c'est leur
  # configuration qui doit vider la query.
  # GET = formulaire « Votre nom », POST = crée le Speaker
  # nominatif + cookie chiffré + redirect vers /w/:slug/join?t=<speaker.token>.
  # ----------------------------------------------------------
  get  "/i", to: "invitations#show",   as: :invitation
  post "/i", to: "invitations#create", as: :invitation_create

  # Rattachement d'un intervenant du lien participants privé à l'inscription
  # de l'adresse qu'il a déclarée (RegistrationMailer#speaker_link) : GET =
  # page à bouton sans effet (scanners de liens), POST = rattache. Jeton en
  # query `t`, comme /i et /confirmer.
  get  "/rattacher", to: "speaker_links#show",   as: :speaker_link
  post "/rattacher", to: "speaker_links#create", as: :confirm_speaker_link

  # Lien animateur — URL publique, jeton en query
  # `t` pour les mêmes raisons que /i. GET seul, sans effet : le bouton de la
  # page POSTe vers /auth/pocket_id, l'acceptation a lieu au callback OIDC.
  get "/a", to: "host_invitations#show", as: :host_invitation

  # Présence d'un animateur, liens de son mail (HostAttendanceMailer) : GET =
  # page sans effet (scanners de liens), POST = réponse. Jeton en query `t`.
  get  "/presence", to: "host_attendances#show",   as: :host_attendance
  post "/presence", to: "host_attendances#create", as: :answer_host_attendance

  # ----------------------------------------------------------
  # Consentement marketing — jeton DÉDIÉ, à usage unique, expirable,
  # EN QUERY STRING `t` (filter_parameters) pour ne pas apparaître dans
  # les logs. GET = page de confirmation SANS effet (immunisée aux
  # scanners de liens Outlook Safe Links / Gmail), POST = mutation
  # protégée CSRF via button_to. Lien de retrait équivalent sous /mc/withdraw.
  # ----------------------------------------------------------
  get  "/mc",              to: "marketing_consents#show",     as: :marketing_consent
  post "/mc",              to: "marketing_consents#create",   as: :confirm_marketing_consent
  post "/mc/decline",      to: "marketing_consents#decline",  as: :decline_marketing_consent
  get  "/mc/withdraw",     to: "marketing_withdrawals#show",  as: :marketing_withdrawal
  post "/mc/withdraw",     to: "marketing_withdrawals#create", as: :confirm_marketing_withdrawal
  # Fin du « préviens-moi du prochain Café IA » (lien des envois groupés) :
  # GET sans effet, POST protégé CSRF via button_to (NotifyNextStopsController).
  get  "/prochain/stop",   to: "notify_next_stops#show",      as: :notify_next_stop
  post "/prochain/stop",   to: "notify_next_stops#create",    as: :confirm_notify_next_stop
end
