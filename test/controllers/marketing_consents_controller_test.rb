require "test_helper"

# Exigences de sécurité testées ici :
#   (a) GET /mc?t=…  = aucune mutation, aucune donnée personnelle affichée ;
#   (b) POST /mc?t=… = CSRF-protégé via button_to, applique le consentement ;
#   (c) jeton expiré rejeté avec message clair ;
#   (d) POST rejoué idempotent ;
#   (e) crawler GET = aucun effet ;
#   (f) refus explicite possible (POST /mc/decline) ;
#   (g) jeton absent des logs ;
#   (h) /r/:token seul inchangé (couvert par registrations_controller_test).
class MarketingConsentsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @webinar = Webinar.create!(
      title: "Café IA public", starts_at: 1.day.from_now,
      host_sub: "host", visibility: "published"
    )
    @registration = @webinar.registrations.create!(name: "Bob", email: "bob@example.test")
    @registration.request_marketing_consent!
    @token = @registration.marketing_consent_token
  end

  # ---- (a) GET sans mutation ------------------------------------------------

  test "GET /mc?t=... affiche le formulaire SANS poser aucun consentement" do
    assert_no_enqueued_jobs do
      assert_no_changes "@registration.reload.marketing_consent" do
        assert_no_changes "@registration.reload.marketing_consent_at" do
          get marketing_consent_path(t: @token)
        end
      end
    end
    assert_response :success
    assert_select "button[type=submit]", /Oui, j'accepte/
  end

  test "GET /mc : AUCUNE donnée personnelle à l'écran (ni email, ni nom)" do
    get marketing_consent_path(t: @token)
    assert_response :success
    assert_no_match(/#{@registration.email}/, response.body, "email jamais affiché")
    assert_no_match(/\bBob\b/, response.body, "prénom jamais affiché")
    assert_includes response.body, @webinar.title
  end

  test "GET /mc pose Referrer-Policy: strict-origin + Cache-Control: no-store" do
    get marketing_consent_path(t: @token)
    assert_equal "strict-origin", response.headers["Referrer-Policy"]
    assert_equal "no-store",    response.headers["Cache-Control"]
  end

  # ---- (e) scanner / crawler : GET = effet nul ------------------------------

  test "scanner GET répété : jamais de consentement posé, jamais de job" do
    assert_no_enqueued_jobs do
      5.times { get marketing_consent_path(t: @token) }
    end
    assert_not @registration.reload.marketing_consent
  end

  # ---- (b) POST applique le consentement -----------------------------------

  test "POST /mc avec jeton valide : applique le consentement, envoie le mail, enqueue CRM si drapeau on" do
    @registration.update!(confirmed_at: Time.current)
    with_crm_sync_enabled do
      assert_enqueued_with(job: CrmSyncJob, args: [ @registration.id ]) do
        assert_enqueued_with(job: ActionMailer::MailDeliveryJob) do
          post confirm_marketing_consent_path(t: @token)
        end
      end
    end
    assert_response :success
    @registration.reload
    assert @registration.marketing_consent
    assert_not_nil @registration.marketing_consent_at
    assert_nil @registration.marketing_consent_token, "jeton consommé"
    assert_not_nil @registration.marketing_withdrawal_token
    assert_equal [ "live.example.test", "/mc", PrivacyPolicy::VERSION, nil ],
                 @registration.values_at(:marketing_consent_source, :marketing_consent_path,
                                         :marketing_consent_policy_version, :marketing_consent_request_id),
                 "preuve figée à l'accord"
    assert_equal "Oui, j'accepte d'être recontacté·e", @registration.marketing_consent_label,
                 "libellé du bouton affiché, figé à l'accord (politique v1.7)"
  end

  test "POST /mc fige le libellé du bouton RÉELLEMENT affiché, par tonalité" do
    # Tonalité du setup (café IA) : la clé `marketing_consents.show.accept`
    # n'y est pas réécrite, le libellé retombe sur le défaut — figé tel
    # qu'affiché.
    get marketing_consent_path(t: @token)
    assert_select "button[type=submit]", "Oui, j'accepte d'être recontacté·e"
    post confirm_marketing_consent_path(t: @token)
    assert_equal "Oui, j'accepte d'être recontacté·e", @registration.reload.marketing_consent_label

    # Tonalité qui RÉÉCRIT la clé : c'est son libellé qui est figé.
    I18n.backend.store_translations(:fr, voices: { bootcamp: { marketing_consents: { show: { accept: "Oui, je veux les nouvelles du bootcamp" } } } })
    bootcamp = Webinar.create!(title: "Bootcamp", kind: "bootcamp", starts_at: 2.days.from_now,
                               host_sub: "h", visibility: "published")
    other = bootcamp.registrations.create!(name: "Kay", email: "kay@example.test")
    other.request_marketing_consent!
    get marketing_consent_path(t: other.marketing_consent_token)
    assert_select "button[type=submit]", "Oui, je veux les nouvelles du bootcamp"
    post confirm_marketing_consent_path(t: other.marketing_consent_token)
    assert_equal "Oui, je veux les nouvelles du bootcamp", other.reload.marketing_consent_label,
                 "le libellé figé est celui affiché dans la tonalité, pas une constante"
  ensure
    I18n.reload!
  end

  test "POST /mc : si drapeau CRM off, aucun enqueue CRM mais mail envoyé" do
    @registration.update!(confirmed_at: Time.current)
    assert_no_enqueued_jobs(only: CrmSyncJob) do
      post confirm_marketing_consent_path(t: @token)
    end
    assert @registration.reload.marketing_consent
  end

  test "POST /mc : si inscription NON confirmée, pas d'enqueue CRM (crm_sync_eligible? false)" do
    # Jeton valide, consentement effectif, MAIS inscription non confirmée
    # → l'enqueue sera fait à la confirmation /r/:token (si drapeau on).
    with_crm_sync_enabled do
      assert_no_enqueued_jobs(only: CrmSyncJob) do
        post confirm_marketing_consent_path(t: @token)
      end
    end
    assert @registration.reload.marketing_consent
  end

  # ---- (c) jeton expiré ----------------------------------------------------

  test "POST /mc avec jeton EXPIRÉ : rejet avec message clair, aucun consentement" do
    @registration.update!(marketing_consent_token_expires_at: 1.hour.ago)
    assert_no_enqueued_jobs do
      post confirm_marketing_consent_path(t: @token)
    end
    assert_response :gone
    assert_includes response.body, "a expiré"
    assert_not @registration.reload.marketing_consent
  end

  test "GET /mc avec jeton EXPIRÉ : page explicite, aucun consentement" do
    @registration.update!(marketing_consent_token_expires_at: 1.hour.ago)
    get marketing_consent_path(t: @token)
    assert_response :gone
    assert_includes response.body, "a expiré"
  end

  # ---- (d) rejeu idempotent ------------------------------------------------

  test "POST /mc rejoué : le 2e POST n'émet pas un second job ni un second mail" do
    @registration.update!(confirmed_at: Time.current)
    with_crm_sync_enabled do
      post confirm_marketing_consent_path(t: @token)
      assert_no_enqueued_jobs(only: CrmSyncJob) do
        assert_no_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
          # Deuxième POST : le jeton est nil, on arrive sur :invalid.
          post confirm_marketing_consent_path(t: @token)
        end
      end
    end
    assert_response :not_found
  end

  # ---- (f) refus explicite -------------------------------------------------

  test "POST /mc/decline consomme le jeton sans poser le consentement" do
    assert_no_enqueued_jobs do
      post decline_marketing_consent_path(t: @token)
    end
    assert_response :success
    assert_includes response.body, "pas de recontact"
    @registration.reload
    assert_not @registration.marketing_consent
    assert_nil @registration.marketing_consent_token
  end

  test "POST /mc/decline sur jeton inconnu : 404 propre" do
    assert_no_enqueued_jobs do
      post decline_marketing_consent_path(t: "inconnu")
    end
    assert_response :not_found
  end

  # ---- jetons inconnus / webinar non publié --------------------------------

  test "GET /mc avec jeton inconnu : 404 sans mutation" do
    get marketing_consent_path(t: "jeton-fantome-inconnu")
    assert_response :not_found
    assert_includes response.body, "Lien invalide"
  end

  test "POST /mc sur un webinaire non publié : 404" do
    @webinar.update!(visibility: "draft")
    post confirm_marketing_consent_path(t: @token)
    assert_response :not_found
    assert_not @registration.reload.marketing_consent
  end

  # ---- Refus possible AVANT confirmation d'inscription ---------------------

  test "refus marketing possible sans confirmer l'inscription" do
    assert_not @registration.confirmed?
    post decline_marketing_consent_path(t: @token)
    assert_response :success
    assert_not @registration.reload.confirmed?, "l'inscription reste indépendante"
  end

  # ---- (g) jeton absent des logs ------------------------------------------

  test "SÉCURITÉ : le jeton `t` est FILTRÉ des logs Rails (ParameterFilter)" do
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io).tap { |l| l.formatter = ->(_s, _t, _p, m) { "#{m}\n" } }
    begin
      get marketing_consent_path(t: @token)
    ensure
      Rails.logger = original
    end
    log = io.string
    # Le jeton nu ne doit pas apparaître dans les logs (filter_parameters
    # couvre `/\At\z/`). On vérifie à la fois qu'il n'est pas écrit tel quel
    # et qu'un marqueur [FILTERED] est présent dans les paramètres loggués.
    assert_no_match(/#{Regexp.escape(@token)}/, log, "le jeton ne doit JAMAIS apparaître dans les logs")
  end

  private

  def with_crm_sync_enabled
    original = ENV["CRM_SYNC_ENABLED"]
    ENV["CRM_SYNC_ENABLED"] = "1"
    yield
  ensure
    ENV["CRM_SYNC_ENABLED"] = original
  end
end
