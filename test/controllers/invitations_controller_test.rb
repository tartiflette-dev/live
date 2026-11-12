require "test_helper"

class InvitationsControllerTest < ActionDispatch::IntegrationTest
  # Lien participants privé (ex-lien d'invitation intervenant partagé),
  # point d'entrée public : nom, mail obligatoire, choix.
  include ActiveJob::TestHelper

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  setup do
    @host = User.create!(email: "inv-host@example.com", oidc_sub: "inv-sub-host")
    @webinar = Webinar.create!(title: "Café intervenants", starts_at: 1.day.from_now, host_sub: @host.oidc_sub, visibility: "published")
    @token = @webinar.generate_share_token!
    # IP unique par test → bucket rate_limit isolé. Le store fichier
    # (RegistrationRateLimitStore) est partagé entre workers parallèles
    # ET entre tests consécutifs ; nettoyer le path serait fragile, une
    # IP unique neutralise la collision de façon déterministe.
    @ip = "10.#{rand(0..255)}.#{rand(0..255)}.#{rand(1..254)}"
    @prev_key    = ENV["LIVEKIT_API_KEY"]
    @prev_secret = ENV["LIVEKIT_API_SECRET"]
    @prev_privacy = ENV["REGISTRATION_PRIVACY_URL"]
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/confidentialite"
  end

  teardown do
    ENV["LIVEKIT_API_KEY"]    = @prev_key
    ENV["LIVEKIT_API_SECRET"] = @prev_secret
    ENV["REGISTRATION_PRIVACY_URL"] = @prev_privacy
  end

  # ---- show (GET /i/:share_token) ----

  test "GET shows the form when token is valid and webinar is live" do
    get invitation_path(t: @token)
    assert_response :success
    assert_select "form[action=?]", invitation_create_path(t: @token)
    assert_select "input[name='invitation[name]']"
  end

  test "GET announces the topic and speakers of the café when they are set" do
    get invitation_path(t: @token)
    assert_select "[data-role='webinar-program']", count: 0

    @webinar.update!(topic: "Agents IA", announced_speakers: [ "Karim", "Anne" ])
    get invitation_path(t: @token)
    assert_select "[data-role='invitation-form'] [data-role='webinar-program']" do
      assert_select "h2", text: "Agents IA"
      assert_select "[data-role='program-speakers']", text: "Karim et Anne"
    end
  end

  test "GET returns 404 on unknown or disabled token" do
    get invitation_path(t: "not-a-token")
    assert_response :not_found

    @webinar.disable_share_token!
    get invitation_path(t: @token)
    assert_response :not_found
  end

  test "GET returns 404 after the share link was regenerated" do
    old = @token
    @webinar.generate_share_token!
    get invitation_path(t: old)
    assert_response :not_found
  end

  test "GET stays open during the grace after the live ends" do
    @webinar.update!(state: "live", started_at: 1.hour.ago)
    @webinar.end!
    get invitation_path(t: @token)
    assert_response :success
  end

  test "GET returns 410 once the grace after the end has passed" do
    @webinar.update!(state: "live", started_at: 1.hour.ago)
    @webinar.end!
    travel_to(@webinar.ended_at + Webinar::LINK_ACCESS_GRACE + 1.second) do
      get invitation_path(t: @token)
    end
    assert_response :gone
    assert_select "[data-role=invitation-ended]", /n’est plus actif/
  end

  test "GET returns 410 for a draft never closed past planned end plus grace" do
    @webinar.update!(starts_at: 3.days.ago)
    get invitation_path(t: @token)
    assert_response :gone
  end

  test "GET stays open while the webinar is live, even past the planned bound" do
    @webinar.update!(starts_at: 10.days.ago, state: "live", started_at: 10.days.ago)
    get invitation_path(t: @token)
    assert_response :success
  end

  # ---- create (POST /i/:share_token) ----

  test "POST creates a Speaker, sets cookie, and redirects to join link" do
    assert_difference "Speaker.count", 1 do
      post invitation_create_path(t: @token), params: entry("Lucie")
    end
    created = @webinar.speakers.order(:id).last
    assert_equal "Lucie", created.name
    assert_redirected_to join_webinar_path(slug: @webinar.slug, t: created.token)
  end

  test "reopening the shared link with the same cookie reuses the Speaker" do
    post invitation_create_path(t: @token), params: entry("Lucie")
    created = @webinar.speakers.order(:id).last

    # Rouvrir le lien partagé = GET /i/:token → redirect vers son lien perso.
    get invitation_path(t: @token)
    assert_redirected_to join_webinar_path(slug: @webinar.slug, t: created.token)

    # POST re-soumis = idem, SANS créer un deuxième Speaker.
    assert_no_difference "Speaker.count" do
      post invitation_create_path(t: @token), params: entry("Autre")
    end
    assert_redirected_to join_webinar_path(slug: @webinar.slug, t: created.token)
  end

  # Un intervenant retiré depuis la régie renvoyait
  # le formulaire /i du même navigateur et repartait en speaker-2, actif.
  test "intervenant retiré : le lien partagé rouvert du même navigateur refuse, sans nouvel intervenant" do
    post invitation_create_path(t: @token), params: entry("Intrus")
    removed = @webinar.speakers.order(:id).last
    removed.remove_from_room!

    get invitation_path(t: @token)
    assert_response :forbidden
    assert_select "[data-role='room-removed']", text: /vous a retiré de/
    assert_select "input[name='invitation[name]']", count: 0

    assert_no_difference "Speaker.count" do
      post invitation_create_path(t: @token), params: entry("Intrus bis")
    end
    assert_response :forbidden
    assert_select "[data-role='room-removed']"
    assert_equal [ removed ], @webinar.speakers.to_a
  end

  # Règle RoomRemoval : un SPECTATEUR retiré rouvrait
  # /i depuis le même navigateur et devenait intervenant, publication comprise.
  test "spectateur retiré : le lien partagé refuse, pas d'intervenant, pas de jeton" do
    registration = @webinar.registrations.create!(name: "Intrus", email: "intrus@example.test")
    post confirm_registration_path(registration.token)
    registration.reload.remove_from_room!

    get invitation_path(t: @token)
    assert_response :forbidden
    assert_select "[data-role='room-removed']"

    assert_no_difference "Speaker.count" do
      post invitation_create_path(t: @token), params: entry("Intrus")
    end
    assert_response :forbidden
    post "/api/token", params: { slug: @webinar.slug }, as: :json
    assert_response :forbidden
  end

  # Retirer ≠ révoquer : révoqué par le propriétaire, le
  # même navigateur revoit le formulaire et reçoit un nouveau lien.
  test "intervenant seulement révoqué par le propriétaire : le lien partagé redonne le formulaire" do
    post invitation_create_path(t: @token), params: entry("Lucie", email: "lucie@example.test")
    @webinar.speakers.order(:id).last.revoke!

    get invitation_path(t: @token)
    assert_response :success
    assert_select "input[name='invitation[name]']"
    assert_difference "Speaker.count", 1 do
      post invitation_create_path(t: @token), params: entry("Lucie", email: "lucie@example.test")
    end
    assert_redirected_to join_webinar_path(slug: @webinar.slug, t: @webinar.speakers.order(:id).last.token)
  end

  test "un cookie d'intervenant inconnu de ce webinaire retombe sur le formulaire" do
    other = Webinar.create!(title: "Autre café", starts_at: 1.day.from_now, host_sub: @host.oidc_sub, visibility: "published")
    other_token = other.generate_share_token!
    post invitation_create_path(t: other_token), params: entry("Lucie")
    other.speakers.last.revoke!

    get invitation_path(t: @token)
    assert_response :success
    assert_select "input[name='invitation[name]']"
  end

  test "POST returns 404 on invalid, regenerated, or disabled token" do
    assert_no_difference "Speaker.count" do
      post invitation_create_path(t: "not-a-token"), params: entry("X")
    end
    assert_response :not_found

    old = @token
    @webinar.generate_share_token!
    assert_no_difference "Speaker.count" do
      post invitation_create_path(t: old), params: entry("X")
    end
    assert_response :not_found
  end

  test "POST still creates during the grace after the live ends" do
    @webinar.update!(state: "live", started_at: 1.hour.ago)
    @webinar.end!
    assert_difference "Speaker.count", 1 do
      post invitation_create_path(t: @token), params: entry("Encore")
    end
    assert_response :see_other
  end

  test "POST returns 410 and does not create once the grace has passed" do
    @webinar.update!(state: "live", started_at: 1.hour.ago)
    @webinar.end!
    assert_no_difference "Speaker.count" do
      travel_to(@webinar.ended_at + Webinar::LINK_ACCESS_GRACE + 1.second) do
        post invitation_create_path(t: @token), params: entry("X")
      end
    end
    assert_response :gone
  end

  test "POST rejects blank name with 422 and shows the form again" do
    assert_no_difference "Speaker.count" do
      post invitation_create_path(t: @token), params: entry("  ")
    end
    assert_response :unprocessable_entity
    assert_select "form[action=?]", invitation_create_path(t: @token)
  end

  test "POST only permits name, email, choice — token, webinar_id, revoked_at ignored" do
    post invitation_create_path(t: @token),
         params: { invitation: entry("Mallory")[:invitation].merge(token: "attacker", webinar_id: 999, revoked_at: Time.current) }
    created = @webinar.speakers.order(:id).last
    assert_not_equal "attacker", created.token
    assert_nil created.revoked_at
    assert_equal @webinar.id, created.webinar_id
  end

  test "capacity cap blocks creation (service unavailable)" do
    (Webinar::SPEAKER_LIMIT).times { |i| @webinar.speakers.create!(name: "N#{i}") }
    assert_no_difference "Speaker.count" do
      post invitation_create_path(t: @token), params: entry("Un de trop")
    end
    assert_response :service_unavailable
  end

  test "rate limit kicks in after 10 submissions from the same IP" do
    # Les 10 premières peuvent créer (ou échouer en 422 sur noms vides).
    10.times do |i|
      post invitation_create_path(t: @token), params: entry("RL#{i}")
      assert_not_equal 429, response.status
    end
    post invitation_create_path(t: @token), params: entry("RL-overflow")
    assert_response :too_many_requests
  end

  test "the shared invitation never grants host privileges" do
    post invitation_create_path(t: @token), params: entry("Lucie")
    created = @webinar.speakers.order(:id).last

    # Simule l'appel que fera le composant React au montage de /join.
    post "/api/token",
         params: { slug: @webinar.slug, speaker_token: created.token, role: "host" },
         as: :json
    assert_response :success
    body = response.parsed_body
    assert_equal "speaker", body.fetch("role"),
      "un Speaker créé via lien partagé ne doit JAMAIS obtenir le rôle host"
    assert_equal "speaker-#{created.id}", body.fetch("identity"),
      "identité stable = enregistré et transcrit"
  end

  test "share token never appears in Rails logs (query param, not path segment)" do
    # Correctif de sécurité : jeton en PARAMÈTRE DE
    # REQUÊTE `t`, pas en segment de chemin. Rails logge « Started POST
    # "/i" » (sans la query filtrée), et filter_parameters masque `t`
    # dans Parameters: → le jeton N'APPARAÎT NULLE PART dans les logs.
    io = StringIO.new
    custom = ActiveSupport::TaggedLogging.new(Logger.new(io))
    previous_rails = Rails.logger
    previous_ac    = ActionController::Base.logger
    begin
      Rails.logger = custom
      ActionController::Base.logger = custom
      get invitation_path(t: @token)
      assert_response :success
      post invitation_create_path(t: @token), params: entry("LogCheck")
      assert_response :see_other
    ensure
      Rails.logger = previous_rails
      ActionController::Base.logger = previous_ac
    end

    log = io.string
    assert_not log.empty?, "les logs doivent avoir capturé la requête"
    # Rails applique filter_parameters AUSSI à la ligne `Started …` :
    # la query string `?t=<jeton>` sort masquée `?t=[FILTERED]`.
    # Un jeton en SEGMENT DE CHEMIN (ex. /i/<jeton>) sortirait en clair.
    assert_includes log, "/i?t=[FILTERED]"
    assert_not_includes log, @token,
      "le share_token NE DOIT PAS apparaître dans les logs (ligne Started ou Parameters)"
    # Et pour les paramètres loggés : on doit lire [FILTERED].
    assert_match(/"t"\s*=>\s*"\[FILTERED\]"/, log)
    # Le lien perso aussi (redirection /join?t=<speaker.token>) : `t`
    # est filtré → aucune valeur `t=` lisible ne doit apparaître.
    assert_no_match(/t=[A-Za-z0-9_-]{20,}/, log,
      "aucune valeur de jeton en clair dans la ligne de redirection")
  end

  test "cap holds under concurrent entries (atomic with_lock)" do
    # Correctif de sécurité : la vérification du plafond
    # et la création vivent sous `webinar.with_lock` (InvitationEntry#save)
    # → une entrée concurrente attend la fin de la section critique.
    # Rempli à LIMIT - 1, huit entrées participantes simultanées : sans
    # verrou, plusieurs passeraient la garde `count < LIMIT`.
    (Webinar::SPEAKER_LIMIT - 1).times { |i| @webinar.speakers.create!(name: "fill-#{i}") }

    results = 8.times.map do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          InvitationEntry.new(webinar: Webinar.find(@webinar.id), name: "race-#{i}",
                              email: "race-#{i}@example.test", participation: "participant").save
        end
      end
    end.map(&:value)

    assert_equal Webinar::SPEAKER_LIMIT, @webinar.reload.speakers.count, "le plafond doit tenir sous création concurrente"
    assert_equal 1, results.count(:speaker), "exactement 1 entrée doit créer"
    assert_equal 7, results.count(:full), "les 7 autres doivent voir :full"
  end

  # ---- lien participants privé : mail obligatoire et choix ----

  test "le formulaire demande nom, mail et choix, participant coché d'office" do
    get invitation_path(t: @token)

    assert_response :success
    assert_select "input[type=email][name='invitation[email]'][required]"
    assert_select "input[type=radio][name='invitation[participation]'][value=participant][checked]"
    assert_select "input[type=radio][name='invitation[participation]'][value=spectator]:not([checked])"
    assert_select "label.radio", text: "Je participe — caméra et micro, tout de suite"
    assert_select "label.radio", text: "J'observe — j'ai le chat"
  end

  test "participant à l'adresse neuve : inscription créée, intervenant non rattaché tant que la boîte n'est pas prouvée, rien au CRM" do
    assert_enqueued_emails 2 do
      post invitation_create_path(t: @token), params: entry("Basile", email: " Basile@Example.test ")
    end

    speaker = @webinar.speakers.find_by!(name: "Basile")
    registration = @webinar.registrations.find_by!(email: "basile@example.test")
    assert_nil speaker.registration
    assert_equal "basile@example.test", speaker.declared_email
    assert_redirected_to join_webinar_path(slug: @webinar.slug, t: speaker.token)
    assert_equal [ @webinar, "basile@example.test", "Basile" ], [ registration.webinar, registration.email, registration.name ]
    assert registration.participant?
    assert_not registration.confirmed?
    assert_nil registration.crm_enrolled_at
    assert_nil registration.instant_access_at, "l'intervenant publie par son lien, pas par l'inscription"
    assert_nil cookies[:registration_id]
  end

  # Le lien privé envoie lui aussi un mail à l'adresse
  # saisie ; la limite par destinataire vaut pour lui comme pour le formulaire.
  test "même adresse saisie deux fois depuis deux réseaux : une seule confirmation, le lien intervenant (preuve) repart" do
    assert_enqueued_emails 2 do
      post invitation_create_path(t: @token), params: entry("Mallory", email: "victime@example.test")
    end
    reset! # autre navigateur : sans le cookie du premier envoi
    @ip = "10.#{rand(0..255)}.#{rand(0..255)}.#{rand(1..254)}"
    assert_enqueued_emails 1 do
      post invitation_create_path(t: @token), params: entry("Mallory 2", email: "victime@example.test")
    end
    assert_enqueued_email_with RegistrationMailer, :speaker_link, args: ->(args) { args.last.email == "victime@example.test" }
  end

  test "spectateur pendant le direct : budget de sécurité refusé, pas d'accès immédiat, le mail ordinaire part" do
    @webinar.update!(state: "live", started_at: Time.current)

    assert_enqueued_emails 1 do
      with_mail_throttle_refusing(:security) do
        post invitation_create_path(t: @token), params: entry("Mallory", email: "victime@example.test", participation: "spectator")
      end
    end

    assert_not @webinar.registrations.find_by!(email: "victime@example.test").instant_access?
    assert_nil cookies[:registration_id]
  end

  # Le lien intervenant et la première confirmation sont
  # des mails de preuve, des renvois épuisés ne les empêchent pas.
  test "participant : les renvois épuisés n'empêchent ni la première confirmation ni le lien intervenant" do
    RecipientMailThrottle::DAILY_TOTAL_CAP.times do |index|
      RecipientMailThrottle.default.claim("victime@example.test", "confirmation:ancien-#{index}")
    end

    assert_enqueued_emails 2 do
      post invitation_create_path(t: @token), params: entry("Basile", email: "victime@example.test")
    end
  end

  test "spectateur pendant le direct : les mails ordinaires épuisés n'empêchent pas l'accès immédiat" do
    @webinar.update!(state: "live", started_at: Time.current)
    RecipientMailThrottle::DAILY_TOTAL_CAP.times do |index|
      RecipientMailThrottle.default.claim("victime@example.test", "confirmation:ancien-#{index}")
    end

    assert_enqueued_emails 1 do
      post invitation_create_path(t: @token), params: entry("Mallory", email: "victime@example.test", participation: "spectator")
    end

    assert @webinar.registrations.find_by!(email: "victime@example.test").instant_access?
  end

  test "spectateur pendant le direct : tous les budgets refusés, ni accès immédiat ni mail" do
    @webinar.update!(state: "live", started_at: Time.current)

    assert_no_enqueued_emails do
      with_mail_throttle_refusing do
        post invitation_create_path(t: @token), params: entry("Mallory", email: "victime@example.test", participation: "spectator")
      end
    end

    assert_not @webinar.registrations.find_by!(email: "victime@example.test").instant_access?
  end

  # Sécurité : saisir l'adresse d'une inscrite ne rattache rien à sa
  # fiche. L'intervenant publie ; elle seule peut confirmer depuis sa boîte.
  test "adresse déjà inscrite, depuis un navigateur sans son cookie : intervenant non rattaché, demande de rattachement à l'adresse" do
    existing = @webinar.registrations.create!(name: "Mathilde Courtois", email: "mathilde@example.test", confirmed_at: 1.day.ago)

    assert_enqueued_email_with RegistrationMailer, :speaker_link, args: ->(args) { args.last == existing } do
      post invitation_create_path(t: @token), params: entry("Mathilde", email: "MATHILDE@example.test")
    end

    speaker = @webinar.speakers.find_by!(name: "Mathilde")
    assert_redirected_to join_webinar_path(slug: @webinar.slug, t: speaker.token), "il entre sur scène tout de suite, comme avant ; il publie dès son accord à l'image"
    assert_nil speaker.registration
    assert_equal "mathilde@example.test", speaker.declared_email
    assert_equal [ "Mathilde Courtois", "spectator" ], [ existing.reload.name, existing.participation ]
    assert_equal 1, @webinar.registrations.count
  end

  test "adresse déjà inscrite, preuve par le cookie de cette inscription (posé par un POST) : rattaché, sans mail" do
    existing = @webinar.registrations.create!(name: "Mathilde Courtois", email: "mathilde@example.test", confirmed_at: 1.day.ago)
    post confirm_registration_path(existing.token)
    assert_response :redirect

    assert_no_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
      post invitation_create_path(t: @token), params: entry("Mathilde", email: "mathilde@example.test")
    end

    assert_equal existing, @webinar.speakers.find_by!(name: "Mathilde").registration
  end

  test "adresse déjà inscrite, preuve par le mail : la page ne rattache rien, son bouton rattache" do
    existing = @webinar.registrations.create!(name: "Mathilde Courtois", email: "mathilde@example.test", confirmed_at: 1.day.ago)
    post invitation_create_path(t: @token), params: entry("Mathilde", email: "mathilde@example.test")
    speaker = @webinar.speakers.find_by!(name: "Mathilde")

    get speaker_link_path(t: speaker.link_token)
    assert_response :success
    assert_nil speaker.reload.registration, "un scanner de liens ne rattache rien"

    post confirm_speaker_link_path(t: speaker.link_token)
    assert_response :success
    assert_equal existing, speaker.reload.registration
  end

  test "spectateur pendant le direct : inscription seule, salle ouverte sur cet appareil, mail parti" do
    @webinar.update!(state: "live", started_at: 5.minutes.ago)

    assert_no_difference "Speaker.count" do
      assert_enqueued_with(job: ActionMailer::MailDeliveryJob) do
        post invitation_create_path(t: @token), params: entry("Inès", participation: "spectator")
      end
    end

    registration = @webinar.registrations.find_by!(name: "Inès")
    assert_redirected_to public_webinar_path(@webinar.slug)
    assert registration.spectator?
    assert registration.instant_access?
    assert_not registration.confirmed?
    get public_webinar_path(@webinar.slug)
    assert_select "#livekit-room[data-viewer-hand-raises-url]"
  end

  test "spectateur avant la fenêtre du direct : la salle attend le lien du mail" do
    post invitation_create_path(t: @token), params: entry("Inès", participation: "spectator")

    assert_response :success
    assert_nil @webinar.registrations.find_by!(name: "Inès").instant_access_at
    assert_nil cookies[:registration_id]
  end

  test "sans mail valide : 422, rien de créé" do
    [ "", "pas-un-mail" ].each do |email|
      assert_no_difference [ "Speaker.count", "Registration.count" ] do
        post invitation_create_path(t: @token), params: { invitation: { name: "Lucie", email: email, participation: "participant" } }
      end
      assert_response :unprocessable_entity
      assert_select "[role=alert]"
    end
  end

  test "choix inconnu : 422, rien de créé" do
    assert_no_difference [ "Speaker.count", "Registration.count" ] do
      post invitation_create_path(t: @token), params: entry("Lucie", participation: "host")
    end
    assert_response :unprocessable_entity
  end

  test "adresse retirée de la salle par l'animation : refusée depuis un autre navigateur, sous les deux choix" do
    @webinar.registrations.create!(name: "Intrus", email: "intrus@example.test", confirmed_at: 1.hour.ago).remove_from_room!

    %w[participant spectator].each do |participation|
      assert_no_difference [ "Speaker.count", "Registration.count" ] do
        post invitation_create_path(t: @token), params: entry("Intrus", email: "intrus@example.test", participation: participation)
      end
      assert_response :forbidden
      assert_select "[data-role='room-removed']"
    end
  end

  test "sans politique de confidentialité configurée : 503, rien de créé" do
    ENV["REGISTRATION_PRIVACY_URL"] = nil

    assert_no_difference [ "Speaker.count", "Registration.count" ] do
      post invitation_create_path(t: @token), params: entry("Lucie")
    end
    assert_response :service_unavailable
  end

  test "plafond d'intervenants atteint : le formulaire reste offert et le choix spectateur passe" do
    Webinar::SPEAKER_LIMIT.times { |i| @webinar.speakers.create!(name: "N#{i}") }

    get invitation_path(t: @token)
    assert_response :success
    assert_no_difference "Speaker.count" do
      post invitation_create_path(t: @token), params: entry("Inès", participation: "spectator")
    end
    assert_response :success
    assert @webinar.registrations.exists?(name: "Inès")
  end

  private

  # Une adresse neuve par défaut : chaque envoi crée sa propre inscription.
  def entry(name, email: "#{name.parameterize}-#{SecureRandom.hex(3)}@example.test", participation: "participant")
    { invitation: { name: name, email: email, participation: participation } }
  end

  # Wrap pour forcer l'IP du test (@ip, unique par test) sur chaque POST
  # vers l'action rate-limitée.
  def post(path, **opts)
    env = (opts[:env] || {}).merge("REMOTE_ADDR" => @ip) if @ip
    opts[:env] = env if env
    super(path, **opts)
  end
end
