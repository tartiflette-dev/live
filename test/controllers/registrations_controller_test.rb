require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @privacy_url = ENV["REGISTRATION_PRIVACY_URL"]
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/privacy"
    @webinar = Webinar.create!(title: "Café public", starts_at: 1.day.from_now,
      host_sub: "host", visibility: "published")
    @headers = { "REMOTE_ADDR" => "2001:db8:#{SecureRandom.hex(2)}:#{SecureRandom.hex(2)}::1" }
    @params = { registration: { name: "Alice", email: "alice@example.test" } }
  end

  teardown do
    ENV["REGISTRATION_PRIVACY_URL"] = @privacy_url
  end

  test "public registration creates pending identity and enqueues confirmation" do
    assert_difference "Registration.count", 1 do
      assert_enqueued_with(job: ActionMailer::MailDeliveryJob) do
        post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers
      end
    end
    assert_response :success
    assert_includes response.body, "Inscription pour essayer"
    registration = Registration.last
    refute registration.confirmed?
    assert_nil registration.paid_confirmed_at
    assert_nil cookies[:registration_id]
  end

  test "SMTP mode shows mailbox instructions without delivering external mail" do
    original_delivery_method = ActionMailer::Base.delivery_method
    ActionMailer::Base.delivery_method = :smtp
    assert_enqueued_jobs 1 do
      post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers
    end
    assert_includes response.body, "Regarde ta boîte mail"
    refute_includes response.body, Registration.last.token
  ensure
    ActionMailer::Base.delivery_method = original_delivery_method
  end

  test "a competing insert before validation still returns the generic response" do
    # Deterministic interleaving: the competing insert lands after the lookup,
    # then the original create hits the real uniqueness validation.
    raced = false
    interleaving = Module.new do
      define_method(:find_or_create_by!) do |attributes, &block|
        if klass == Registration && attributes[:email] == "alice@example.test" && !raced
          raced = true
          create!(attributes, &block)
          create!(attributes, &block)
        else
          super(attributes, &block)
        end
      end
    end
    ActiveRecord::Relation.prepend(interleaving)
    assert_difference "Registration.count", 1 do
      post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers
    end
    assert raced
    assert_response :success
    assert_includes response.body, "Inscription pour essayer"
  ensure
    interleaving&.remove_method(:find_or_create_by!)
  end

  test "ended webinars refuse new registrations" do
    @webinar.update!(state: "ended")
    assert_no_difference "Registration.count" do
      assert_no_enqueued_jobs do
        post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers
      end
    end
    assert_response :gone
  end

  test "duplicates return the same page and resend unchanged pending link" do
    post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers
    first_body = without_csp_nonce(response.body)
    registration = Registration.last
    token = registration.token
    # Dans les 10 minutes : même réponse, mais pas de second mail (limite par
    # destinataire) ; passé ce délai, le lien en attente est renvoyé.
    assert_no_difference "Registration.count" do
      assert_no_enqueued_jobs do
        post public_webinar_registrations_path(@webinar.slug), params: @params.deep_merge(registration: { name: "Mallory", email: " ALICE@EXAMPLE.TEST " }), headers: @headers
      end
    end
    assert_equal first_body, without_csp_nonce(response.body)
    travel RecipientMailThrottle::INTERVAL + 1.minute do
      assert_enqueued_jobs 1 do
        post public_webinar_registrations_path(@webinar.slug), params: @params.deep_merge(registration: { name: "Mallory", email: " ALICE@EXAMPLE.TEST " }), headers: @headers
      end
    end
    assert_equal first_body, without_csp_nonce(response.body)
    assert_equal "Alice", registration.reload.name
    assert_equal token, registration.token
    registration.confirm!
    assert_no_enqueued_jobs do
      post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers
    end
    assert_equal first_body, without_csp_nonce(response.body)
  end

  # Politique v1.6 : l'inscription repose sur la demande (art. 6.1.b), plus
  # sur une case. Une ancienne soumission `consent: "0"` n'empêche rien.
  test "no registration checkbox: an old consent value is ignored" do
    assert_difference "Registration.count", 1 do
      post public_webinar_registrations_path(@webinar.slug),
        params: @params.deep_merge(registration: { consent: "0" }), headers: @headers
    end
    assert_response :success
  end

  test "invalid identity creates nothing" do
    [ { email: "bad-address" }, { name: "" } ].each do |invalid|
      assert_no_difference "Registration.count" do
        assert_no_enqueued_jobs do
          post public_webinar_registrations_path(@webinar.slug), params: @params.deep_merge(registration: invalid), headers: @headers
        end
      end
      assert_response :unprocessable_entity
    end
  end

  test "unpublished webinar is unavailable and no email is sent" do
    @webinar.update!(visibility: "draft")
    assert_no_difference "Registration.count" do
      assert_no_enqueued_jobs do
        post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers
      end
    end
    assert_response :not_found
  end

  test "client cannot set privileged registration fields" do
    post public_webinar_registrations_path(@webinar.slug), params: @params.deep_merge(registration: {
      token: "attacker", confirmed_at: Time.current, paid_confirmed_at: Time.current, webinar_id: 999
    }), headers: @headers
    registration = Registration.last
    refute_equal "attacker", registration.token
    refute registration.confirmed?
    assert_nil registration.paid_confirmed_at
    assert_equal @webinar, registration.webinar
  end

  test "confirmation cookie is an encrypted persistent identity scoped to webinar" do
    registration = @webinar.registrations.create!(name: "Alice", email: "alice@example.test")
    https!
    post confirm_registration_path(registration.token)
    assert_redirected_to public_webinar_path(@webinar.slug)
    assert registration.reload.confirmed?
    first_confirmation = registration.confirmed_at
    cookie = response.headers["set-cookie"].to_s
    assert_match(/httponly/i, cookie)
    assert_match(/secure/i, cookie)
    assert_match(/samesite=lax/i, cookie)
    assert_match(/expires=/i, cookie, "persistant : survit à la fermeture du navigateur")
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "strict-origin", response.headers["Referrer-Policy"]
    follow_redirect!
    assert_includes response.body, "Tu es inscrit·e, Alice"
    other = Webinar.create!(title: "Autre", starts_at: 2.days.from_now, host_sub: "host", visibility: "published")
    get public_webinar_path(other.slug)
    refute_includes response.body, "Tu es inscrit·e, Alice"
    post confirm_registration_path(registration.token)
    assert_equal first_confirmation, registration.reload.confirmed_at
  end

  test "SÉCURITÉ : GET /r/:token non confirmé = page à bouton SANS effet (scanners de liens)" do
    with_crm_sync_enabled do
      registration = @webinar.registrations.create!(name: "Alice", email: "alice@example.test")
      assert_no_enqueued_jobs do
        get confirm_registration_path(registration.token)
      end
      assert_response :success
      assert_select "form[action=?][method=post] button", confirm_registration_path(registration.token),
                    text: "Je confirme"
      assert_not_includes response.body, "alice@example.test"
      assert_not_includes response.body, "Alice"
      assert_nil response.headers["set-cookie"], "aucun cookie d'accès avant confirmation"
      assert_equal "strict-origin", response.headers["Referrer-Policy"]
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_not registration.reload.confirmed?
      assert_nil registration.crm_enrolled_at
    end
  end

  # Le GET ne pose plus le cookie d'inscription, même d'une
  # inscription confirmée — un lien envoyé par un tiers ne doit pas imposer
  # son identité. Le bouton (POST, CSRF) donne l'accès.
  test "GET /r/:token déjà confirmé : page à bouton sans cookie, le POST donne l'accès, aucun effet CRM" do
    with_crm_sync_enabled do
      registration = @webinar.registrations.create!(name: "Alice", email: "alice@example.test")
      post confirm_registration_path(registration.token)
      clear_enqueued_jobs
      cookies.delete(:registration_id)
      assert_no_enqueued_jobs do
        get confirm_registration_path(registration.token)
      end
      assert_response :success
      assert_nil response.headers["set-cookie"], "aucun cookie d'identité sur un GET"
      assert_select "form[action=?][method=post] button", confirm_registration_path(registration.token),
                    text: "Ouvrir la page du café"
      assert_not_includes response.body, "Alice"

      assert_no_enqueued_jobs do
        post confirm_registration_path(registration.token)
      end
      assert_redirected_to public_webinar_path(@webinar.slug)
      follow_redirect!
      assert_includes response.body, "Tu es inscrit·e, Alice"
    end
  end

  test "GET /r/:token d'une inscription retirée de la salle : « Accès retiré », aucun cookie" do
    registration = @webinar.registrations.create!(name: "Alice", email: "alice@example.test", confirmed_at: Time.current)
    registration.remove_from_room!

    get confirm_registration_path(registration.token)
    assert_response :forbidden
    assert_select "[data-role='room-removed']"
    assert_nil response.headers["set-cookie"]
  end

  test "SÉCURITÉ : inscrit confirmé sous la politique v1.0 — revisiter le lien ne l'envoie pas au CRM" do
    with_crm_sync_enabled do
      legacy = @webinar.registrations.create!(name: "Ana", email: "ana@example.test", confirmed_at: 1.month.ago)
      assert_no_enqueued_jobs(only: CrmSyncJob) do
        get confirm_registration_path(legacy.token)
        post confirm_registration_path(legacy.token)
      end
      assert_not legacy.reload.crm_sync_eligible?
      assert_not_includes Registration.crm_pending, legacy
    end
  end

  test "unknown token and forged cookie do not authenticate" do
    get confirm_registration_path("unknown-token")
    assert_response :not_found
    cookies[:registration_id] = "123"
    get public_webinar_path(@webinar.slug)
    assert_response :success
    refute_includes response.body, "Vous êtes inscrit·e"
  end

  test "missing privacy document closes registration" do
    ENV.delete("REGISTRATION_PRIVACY_URL")
    get public_webinar_path(@webinar.slug)
    assert_includes response.body, "Les inscriptions ne sont pas encore ouvertes"
    assert_select "form[action=?]", public_webinar_registrations_path(@webinar.slug), count: 0
    assert_no_difference "Registration.count" do
      post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers
    end
    assert_response :service_unavailable
  end

  test "rate limit stops the eleventh request and resets after a minute" do
    10.times { post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers }
    assert_response :success
    assert_no_enqueued_jobs do
      post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers
    end
    assert_response :too_many_requests
    travel 61.seconds do
      post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers
      assert_response :success
    end
  end

  test "même adresse saisie depuis dix réseaux différents : un seul mail, même réponse" do
    assert_enqueued_emails 1 do
      10.times do |index|
        headers = { "REMOTE_ADDR" => "2001:db8:#{index.to_s(16)}:#{SecureRandom.hex(2)}::1" }
        post public_webinar_registrations_path(@webinar.slug),
          params: { registration: { name: "Mallory #{index}", email: "victime@example.test" } }, headers: headers
        assert_response :success
      end
    end
    assert_equal 1, Registration.where(email: "victime@example.test").count
  end

  # Le mail de confirmation d'un accès immédiat est ce qui
  # prévient la boîte qu'on est entré sous son adresse ; sans lui, jamais
  # d'accès. Budget `:security`, séparé des mails ordinaires.
  test "pendant le direct : budget de sécurité refusé, l'inscription reste en attente et la salle ne s'ouvre pas" do
    @webinar.update!(state: "live", started_at: Time.current)

    assert_enqueued_emails 1 do
      with_mail_throttle_refusing(:security) do
        post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers
      end
    end

    assert_response :success
    registration = Registration.find_by!(email: "alice@example.test")
    assert_not registration.instant_access?, "budget de sécurité épuisé, pas d'accès immédiat"
    assert_nil cookies[:registration_id]
  end

  test "pendant le direct : tous les budgets refusés, ni accès immédiat ni mail" do
    @webinar.update!(state: "live", started_at: Time.current)

    assert_no_enqueued_emails do
      with_mail_throttle_refusing do
        post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers
      end
    end

    assert_not Registration.find_by!(email: "alice@example.test").instant_access?
  end

  test "pendant le direct : les mails ordinaires épuisés n'empêchent ni le mail ni l'accès immédiat" do
    @webinar.update!(state: "live", started_at: Time.current)
    RecipientMailThrottle::DAILY_TOTAL_CAP.times do |index|
      RecipientMailThrottle.default.claim("alice@example.test", "confirmation:ancien-#{index}")
    end

    assert_enqueued_emails 1 do
      post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers
    end

    assert_redirected_to public_webinar_path(@webinar.slug)
    assert Registration.find_by!(email: "alice@example.test").instant_access?
  end

  # La première confirmation d'une inscription NEUVE n'est
  # pas empêchée par des renvois épuisés.
  test "hors direct : les renvois épuisés n'empêchent pas la première confirmation d'une inscription neuve" do
    RecipientMailThrottle::DAILY_TOTAL_CAP.times do |index|
      RecipientMailThrottle.default.claim("alice@example.test", "confirmation:ancien-#{index}")
    end

    assert_enqueued_emails 1 do
      post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers
    end
    assert_not Registration.find_by!(email: "alice@example.test").instant_access?
  end

  test "budgets épuisés : le mail d'accès de la boîte prouvée part quand même" do
    @webinar.update!(state: "live", started_at: Time.current)
    post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers
    provisional = Registration.find_by!(email: "alice@example.test")
    assert provisional.instant_access?
    RecipientMailThrottle::DAILY_TOTAL_CAP.times do |index|
      RecipientMailThrottle.default.claim("alice@example.test", "confirmation:ancien-#{index}")
    end
    assert_not RecipientMailThrottle.default.claim("alice@example.test", "renvoi")

    # La personne de la boîte confirme depuis un AUTRE navigateur (reprise) :
    # le mail d'accès ne dépend d'aucun des deux budgets.
    reset!
    assert_enqueued_email_with RegistrationMailer, :access, args: ->(args) { args.first.email == "alice@example.test" } do
      post confirm_registration_path(provisional.token), params: { name: "Alice", participation: "spectator" }
    end
  end

  test "rate limit IPv6 par /64 : changer d'adresse dans le même préfixe ne le contourne pas" do
    prefix = @headers["REMOTE_ADDR"].split(":")[0, 4].join(":")
    10.times do |index|
      post public_webinar_registrations_path(@webinar.slug),
        params: { registration: { name: "A", email: "a#{index}@example.test" } }, headers: { "REMOTE_ADDR" => "#{prefix}::#{index + 1}" }
    end
    post public_webinar_registrations_path(@webinar.slug),
      params: { registration: { name: "A", email: "z@example.test" } }, headers: { "REMOTE_ADDR" => "#{prefix}:1:2:3:4" }
    assert_response :too_many_requests
  end

  test "legacy browsers can register" do
    post public_webinar_registrations_path(@webinar.slug), params: @params,
      headers: @headers.merge("HTTP_USER_AGENT" => "Mozilla/5.0 Chrome/100.0.0.0 Safari/537.36")
    assert_response :success
  end

  # ---- consentement marketing (facultatif, distinct de l'inscription) -----

  test "case marketing cochée à la création : jeton généré, pas de consentement effectif" do
    params = @params.deep_merge(registration: { marketing_consent: "1" })
    post public_webinar_registrations_path(@webinar.slug), params: params, headers: @headers
    registration = Registration.last
    assert registration.marketing_consent_requested?, "le jeton doit être généré"
    assert_match(/\A[A-Za-z0-9_-]{32}\z/, registration.marketing_consent_token)
    assert_not registration.marketing_consent, "pas de consentement effectif avant /mc/:token"
    assert_nil registration.marketing_consent_at
  end

  test "case marketing absente : ni jeton ni consentement" do
    post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers
    registration = Registration.last
    assert_nil registration.marketing_consent_token
    assert_not registration.marketing_consent
    assert_nil registration.marketing_consent_at
  end

  test "SÉCURITÉ : re-soumission avec l'email d'un tiers ne pose AUCUN jeton ni consentement" do
    # Scénario d'attaque 1 : B s'inscrit sans case marketing et confirme.
    # A soumet le formulaire avec l'email de B + case marketing cochée.
    # Rien ne doit changer côté consentement, AUCUN jeton, AUCUN job CRM.
    victim = @webinar.registrations.create!(
      name: "Bob", email: "bob@example.test", confirmed_at: Time.current
    )
    attacker_params = @params.deep_merge(registration: {
      name: "Mallory", email: "bob@example.test", marketing_consent: "1"
    })
    assert_no_enqueued_jobs(only: CrmSyncJob) do
      assert_no_difference "Registration.count" do
        post public_webinar_registrations_path(@webinar.slug), params: attacker_params, headers: @headers
      end
    end
    victim.reload
    assert_nil victim.marketing_consent_token, "aucun jeton ne doit être posé via un tiers"
    assert_not victim.marketing_consent
    assert_nil victim.marketing_consent_at
  end

  test "SÉCURITÉ : re-soumission sur une inscription NON confirmée ne génère pas un second jeton" do
    @webinar.registrations.create!(
      name: "Carol", email: "carol@example.test", marketing_consent_token: "existing-mc-token"
    )
    post public_webinar_registrations_path(@webinar.slug),
      params: @params.deep_merge(registration: {
        email: "carol@example.test", marketing_consent: "1"
      }), headers: @headers
    # Le re-POST ne remplace pas le jeton existant ni n'engage le consentement.
    reloaded = Registration.find_by!(email: "carol@example.test")
    assert_equal "existing-mc-token", reloaded.marketing_consent_token
    assert_not reloaded.marketing_consent
  end

  test "SÉCURITÉ : /r/:token (inscription) NE touche PAS le consentement marketing" do
    # Flux d'attaque : A inscrit B avec case cochée. Le mail part à B.
    # Si B clique UNIQUEMENT sur le lien d'inscription (ignorant la mention
    # consentement du mail), AUCUN consentement ne doit être posé.
    post public_webinar_registrations_path(@webinar.slug),
      params: @params.deep_merge(registration: { marketing_consent: "1" }), headers: @headers
    registration = Registration.last
    assert registration.marketing_consent_requested?

    https!
    post confirm_registration_path(registration.token)
    registration.reload
    assert registration.confirmed?, "l'inscription est confirmée"
    assert_not registration.marketing_consent, "le consentement reste INEFFECTIF"
    assert_nil registration.marketing_consent_at
    assert registration.marketing_consent_requested?, "le jeton reste en attente"
  end

  test "POST /r/:token enqueue le job CRM une fois, pour tout inscrit confirmé, sans consentement marketing" do
    # La confirmation suffit pour entrer au CRM
    # comme participant ; la prospection reste conditionnée à /mc.
    with_crm_sync_enabled do
      registration = @webinar.registrations.create!(name: "Alice", email: "alice@example.test")
      https!
      assert_enqueued_with(job: CrmSyncJob, args: [ registration.id ]) do
        post confirm_registration_path(registration.token)
      end
      assert_not registration.reload.marketing_consent
      assert_no_enqueued_jobs(only: CrmSyncJob) do
        clear_enqueued_jobs
        post confirm_registration_path(registration.token)
      end
    end
  end

  test "POST /r/:token : drapeau CRM off → aucun enqueue" do
    registration = @webinar.registrations.create!(
      name: "Alice", email: "alice@example.test",
      marketing_consent: true, marketing_consent_at: Time.current
    )
    https!
    assert_no_enqueued_jobs(only: CrmSyncJob) do
      post confirm_registration_path(registration.token)
    end
  end

  # ---- lien public : choix et accès immédiat ----

  test "le formulaire offre le choix, spectateur coché d'office ; le choix est retenu à la création" do
    get public_webinar_path(@webinar.slug)
    assert_select "input[type=radio][name='registration[participation]'][value=spectator][checked]"
    assert_select "input[type=radio][name='registration[participation]'][value=participant]:not([checked])"

    post public_webinar_registrations_path(@webinar.slug), headers: @headers,
      params: { registration: { name: "Alice", email: "alice@example.test", participation: "participant" } }
    assert Registration.find_by!(email: "alice@example.test").participant?

    post public_webinar_registrations_path(@webinar.slug), params: @params.deep_merge(registration: { email: "bob@example.test" }),
      headers: @headers
    assert Registration.find_by!(email: "bob@example.test").spectator?
  end

  test "choix inconnu : rien de créé" do
    assert_no_difference "Registration.count" do
      post public_webinar_registrations_path(@webinar.slug), headers: @headers,
        params: @params.deep_merge(registration: { participation: "host" })
    end
    assert_response :unprocessable_entity
  end

  test "pendant le direct : salle ouverte tout de suite sur cet appareil, mail parti, rien au CRM avant confirmation" do
    @webinar.update!(state: "live", started_at: Time.current)

    with_crm_sync_enabled do
      assert_no_enqueued_jobs(only: CrmSyncJob) do
        assert_enqueued_with(job: ActionMailer::MailDeliveryJob) do
          post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers
        end
      end
      assert_redirected_to public_webinar_path(@webinar.slug)
      registration = Registration.find_by!(email: "alice@example.test")
      assert registration.instant_access?
      assert_not registration.confirmed?
      assert_nil registration.crm_enrolled_at
      notice = RegistrationMailer.confirmation(registration).text_part.body.to_s
      assert_match(/Quelqu'un est entré au café avec ton adresse/, notice)
      assert_no_match(/Alice/, notice, "le nom saisi n'est pas recopié dans un mail à une adresse non prouvée")

      follow_redirect!
      assert_select "#livekit-room[data-viewer-hand-raises-url]"

      # La confirmation du mail, plus tard, fait entrer au CRM.
      assert_enqueued_with(job: CrmSyncJob, args: [ registration.id ]) do
        post confirm_registration_path(registration.token)
      end
      assert registration.reload.crm_enrolled_at
    end
  end

  test "dans le quart d'heure qui précède le début : accès immédiat ; avant, la salle attend le mail" do
    @webinar.update!(starts_at: 10.minutes.from_now)
    post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers
    assert_redirected_to public_webinar_path(@webinar.slug)
    follow_redirect!
    assert_includes response.body, "Tu es inscrit·e, Alice"

    later = Webinar.create!(title: "Plus tard", starts_at: 20.minutes.from_now, host_sub: "host", visibility: "published")
    post public_webinar_registrations_path(later.slug), params: @params, headers: @headers
    assert_response :success
    assert_nil later.registrations.sole.instant_access_at
  end

  test "pendant le direct, une adresse déjà inscrite n'ouvre pas la salle à qui la saisit" do
    @webinar.update!(state: "live", started_at: Time.current)
    existing = @webinar.registrations.create!(name: "Alice", email: "alice@example.test")

    post public_webinar_registrations_path(@webinar.slug), params: @params, headers: @headers

    assert_response :success
    assert_nil existing.reload.instant_access_at
    assert_nil cookies[:registration_id]
  end

  private

  # Le nonce CSP change à chaque réponse (config/initializers/content_security_policy.rb) :
  # « même page » s'entend à nonce près.
  def without_csp_nonce(body)
    body.gsub(/(name="csp-nonce" content=")[^"]*/, '\\1').gsub(/ nonce="[^"]*"/, "")
  end

  def with_crm_sync_enabled
    original = ENV["CRM_SYNC_ENABLED"]
    ENV["CRM_SYNC_ENABLED"] = "1"
    yield
  ensure
    ENV["CRM_SYNC_ENABLED"] = original
  end
end
