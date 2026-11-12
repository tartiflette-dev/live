require "test_helper"

# /confirmer?t=<token> — confirmation groupée d'une demande de l'API.
class RegistrationRequestsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @saved_env = ENV.to_h.slice("CRM_SYNC_ENABLED", "CO_ORGANIZERS_NOTIFY_TO")
    ENV.delete("CRM_SYNC_ENABLED")
    ENV.delete("CO_ORGANIZERS_NOTIFY_TO")
    @first = Webinar.create!(title: "Café IA de novembre", starts_at: 3.days.from_now, host_sub: "h", visibility: "published")
    @second = Webinar.create!(title: "Café IA de décembre", starts_at: 30.days.from_now, host_sub: "h", visibility: "published")
    @request_record = RegistrationRequest.create!(
      name: "Camille", email: "camille@example.test", source: "tartiflette.dev", profile: "dev"
    )
    @registrations = [ @first, @second ].map do |webinar|
      Registration.find_or_create_for(webinar, email: "camille@example.test", name: "Camille",
                                      registration_request: @request_record).first
    end
  end

  teardown do
    %w[CRM_SYNC_ENABLED CO_ORGANIZERS_NOTIFY_TO].each { |key| ENV[key] = @saved_env[key] }
  end

  # La confirmation met aussi en file le lien d'agenda personnel
  # (CalendarSubscriptionMailer) : seul le mail aux co-organisateurs compte ici.
  def assert_no_team_mail_enqueued
    team_mails = enqueued_jobs.select do |job|
      job[:job] == ActionMailer::MailDeliveryJob && job[:args].first == "CoOrganizerMailer"
    end
    assert_empty team_mails
  end

  test "GET : page SANS effet, cafés listés, aucune donnée personnelle" do
    assert_no_enqueued_jobs do
      get registration_request_path(t: @request_record.token)
    end
    assert_response :success
    assert_select "button", text: "Je confirme"
    assert_includes response.body, "sans confirmation, la demande est effacée sous 30 jours"
    assert_includes response.body, "Café IA de novembre"
    assert_includes response.body, "Café IA de décembre"
    assert_not_includes response.body, "camille@example.test"
    assert_not_includes response.body, "Camille"
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "strict-origin", response.headers["Referrer-Policy"]
    assert_not @request_record.reload.confirmed?
    assert @registrations.none? { |registration| registration.reload.confirmed? }
  end

  test "lien d'une demande non confirmée de plus de 30 jours : 410, sans effet" do
    @request_record.update_columns(created_at: 31.days.ago)
    get registration_request_path(t: @request_record.token)
    assert_response :gone
    post confirm_registration_request_path(t: @request_record.token)
    assert_response :gone
    assert_not @request_record.reload.confirmed?
  end

  test "demande confirmée : le lien reste la page d'accès au-delà de 30 jours" do
    @request_record.confirm!
    @request_record.update_columns(created_at: 60.days.ago)
    get registration_request_path(t: @request_record.token)
    assert_response :success
    assert_select "[data-role=registration-request-confirmed]"
  end

  test "jeton inconnu ou absent : 404" do
    get registration_request_path(t: "inconnu")
    assert_response :not_found
    post confirm_registration_request_path
    assert_response :not_found
  end

  test "POST : confirme la demande et TOUTES ses inscriptions, liens d'accès par café" do
    post confirm_registration_request_path(t: @request_record.token)
    assert_response :success
    assert @request_record.reload.confirmed?
    assert @registrations.all? { |registration| registration.reload.confirmed? }
    @registrations.each do |registration|
      assert_select "a[href=?]", confirm_registration_path(registration.token)
    end
    assert_equal "no-store", response.headers["Cache-Control"]

    get confirm_registration_path(@registrations.first.token)
    assert_response :success, "inscription confirmée : page à bouton d'accès, sans cookie"
    assert_select "[data-role=registration-access] form[action=?]", confirm_registration_path(@registrations.first.token)
  end

  test "page confirmée : le Café IA garde ses mots, la tonalité par défaut ne nomme aucune émission" do
    @request_record.confirm!
    get registration_request_path(t: @request_record.token)
    assert_select "[data-role=registration-request-confirmed] a", text: "Ouvrir la page du café"

    bootcamp = Webinar.create!(title: "Atelier", kind: "bootcamp", starts_at: 5.days.from_now, host_sub: "h",
                               visibility: "published")
    other = RegistrationRequest.create!(name: "Lou", email: "lou@example.test", source: "tartiflette.dev")
    Registration.find_or_create_for(bootcamp, email: other.email, name: other.name, registration_request: other)
    other.confirm!
    get registration_request_path(t: other.token)
    assert_select "[data-role=registration-request-confirmed] a", text: "Ouvrir la page du webinaire"
    assert_not_includes response.body, "Café IA"
  end

  test "GET après confirmation : page d'accès, sans rien refaire" do
    @request_record.confirm!
    assert_no_enqueued_jobs do
      get registration_request_path(t: @request_record.token)
    end
    assert_select "[data-role=registration-request-confirmed]"
    assert_select "[data-role=registration-request-confirmed] button", count: 0
  end

  test "CRM : drapeau on → un job par inscription, et le « préviens-moi » si demandé" do
    ENV["CRM_SYNC_ENABLED"] = "1"
    @request_record.update!(notify_next: true)
    post confirm_registration_request_path(t: @request_record.token)
    @registrations.each { |registration| assert_enqueued_with(job: CrmSyncJob, args: [ registration.id ]) }
    assert_enqueued_with(job: CrmNotifyNextJob, args: [ @request_record.id ])
  end

  test "CRM : drapeau off → aucun job" do
    assert_no_enqueued_jobs(only: [ CrmSyncJob, CrmNotifyNextJob ]) do
      post confirm_registration_request_path(t: @request_record.token)
    end
  end

  test "POST rejoué : ni second job CRM ni second mail du message" do
    ENV["CRM_SYNC_ENABLED"] = "1"
    ENV["CO_ORGANIZERS_NOTIFY_TO"] = "orga@tartiflette.test"
    @request_record.update!(message: "Je propose une présentation.")
    post confirm_registration_request_path(t: @request_record.token)
    assert_no_enqueued_jobs do
      post confirm_registration_request_path(t: @request_record.token)
    end
    assert_response :success
  end

  test "co-organisateurs : message d'une demande tartiflette.dev transmis à CO_ORGANIZERS_NOTIFY_TO à la confirmation" do
    ENV["CO_ORGANIZERS_NOTIFY_TO"] = "orga@tartiflette.test"
    @request_record.update!(message: "Je propose une présentation.")
    assert_enqueued_email_with CoOrganizerMailer, :message_received,
                               args: [ @request_record, { to: "orga@tartiflette.test" } ] do
      post confirm_registration_request_path(t: @request_record.token)
    end
    assert_not_nil @request_record.reload.team_notified_at
  end

  test "co-organisateurs : demande sans message → aucun envoi" do
    ENV["CO_ORGANIZERS_NOTIFY_TO"] = "orga@tartiflette.test"
    post confirm_registration_request_path(t: @request_record.token)

    assert_no_team_mail_enqueued
  end

  test "co-organisateurs : variable absente → aucun envoi" do
    @request_record.update!(message: "Je propose une présentation.")
    post confirm_registration_request_path(t: @request_record.token)

    assert_no_team_mail_enqueued
  end

  test "co-organisateurs : demande sans source tartiflette.dev → aucun envoi" do
    ENV["CO_ORGANIZERS_NOTIFY_TO"] = "orga@tartiflette.test"
    @request_record.update!(source: nil, message: "Je propose une présentation.")
    post confirm_registration_request_path(t: @request_record.token)

    assert_no_team_mail_enqueued
  end

  test "« préviens-moi » seul : confirmé, message dédié" do
    lone = RegistrationRequest.create!(name: "Lou", email: "lou@example.test", notify_next: true)
    post confirm_registration_request_path(t: lone.token)
    assert lone.reload.confirmed?
    assert_includes response.body, "on te prévient par mail"
  end

  # ---- Case de recontact -----------------------------------

  test "recontact non coché : aucun consentement marketing après confirmation, ni mention" do
    get registration_request_path(t: @request_record.token)
    assert_select "[data-role=marketing-consent-notice]", count: 0
    assert_select "[data-role=confirm-without-marketing]", count: 0

    post confirm_registration_request_path(t: @request_record.token)
    assert @registrations.none? { |registration| registration.reload.marketing_consent? }
    assert_select "[data-role=marketing-consent-given]", count: 0
  end

  test "recontact coché : deux boutons explicites, la case présentée comme cochée lors de la demande" do
    @request_record.update!(marketing_box_checked: true)
    get registration_request_path(t: @request_record.token)
    assert_select "[data-role=marketing-consent-notice]", /La case « Ok pour que Studio Exemple me recontacte.*a été cochée lors de cette demande/m
    assert_no_match(/Vous avez coché|Tu as coché/, response.body)
    # Cafés : libellés café (Voice), qui disent eux aussi ce qu'ils accordent.
    assert_select "button[data-role=confirm-with-marketing]", "Je confirme, et Studio Exemple peut me recontacter"
    assert_select "button[data-role=confirm-without-marketing]", "Je confirme, sans être recontacté·e"
    assert_select "button", text: "Je confirme", count: 0
    assert_select "form:has(button[data-role=confirm-with-marketing]) input[name=marketing][value='1']"
    assert_select "form:has(button[data-role=confirm-without-marketing]) input[name=marketing][value='0']"
    assert @registrations.none? { |registration| registration.reload.marketing_consent? }, "rien avant le POST"
  end

  test "recontact coché, « Confirmer et accepter » (marketing=1) : consentement daté, preuve figée" do
    @request_record.update!(marketing_box_checked: true)
    freeze_time do
      post confirm_registration_request_path(t: @request_record.token), params: { marketing: "1" }
      @registrations.each do |registration|
        registration.reload
        assert registration.marketing_consent?
        assert_equal Time.current, registration.marketing_consent_at
        assert_equal Time.current, registration.confirmed_at
        assert registration.marketing_withdrawal_token.present?
        assert_equal [ "tartiflette.dev", "/confirmer", PrivacyPolicy::VERSION, @request_record.id,
                       "Je confirme, et Studio Exemple peut me recontacter" ],
                     registration.values_at(:marketing_consent_source, :marketing_consent_path,
                                            :marketing_consent_policy_version, :marketing_consent_request_id,
                                            :marketing_consent_label)
      end
    end
    assert_select "[data-role=marketing-consent-given] a[href=?]",
                  marketing_withdrawal_path(t: @registrations.first.reload.marketing_withdrawal_token)
  end

  test "SÉCURITÉ : recontact coché, POST sans choix ou valeur inattendue → inscrit, aucun consentement" do
    @request_record.update!(marketing_box_checked: true)
    post confirm_registration_request_path(t: @request_record.token)
    assert @request_record.reload.confirmed?
    assert @registrations.all? { |registration| registration.reload.confirmed? }
    assert @registrations.none?(&:marketing_consent?), "un POST sans `marketing` n'accorde jamais rien"

    other = RegistrationRequest.create!(name: "Lou", email: "lou@example.test", marketing_box_checked: true)
    lou, = Registration.find_or_create_for(@first, email: other.email, name: other.name, registration_request: other)
    post confirm_registration_request_path(t: other.token), params: { marketing: "true" }
    assert_not lou.reload.marketing_consent?, "seul \"1\" accorde"
  end

  test "recontact coché puis « Confirmer sans être recontacté·e » : inscrit, sans consentement, rejeu sans effet" do
    @request_record.update!(marketing_box_checked: true)
    post confirm_registration_request_path(t: @request_record.token), params: { marketing: "0" }
    assert @request_record.reload.confirmed?
    assert @registrations.all? { |registration| registration.reload.confirmed? }
    assert @registrations.none?(&:marketing_consent?)

    post confirm_registration_request_path(t: @request_record.token), params: { marketing: "1" }
    assert @registrations.none? { |registration| registration.reload.marketing_consent? }, "la demande est déjà confirmée"
  end

  test "recontact coché, demande jamais confirmée : aucun consentement, même expirée" do
    @request_record.update!(marketing_box_checked: true)
    get registration_request_path(t: @request_record.token)
    @request_record.update_columns(created_at: 31.days.ago)
    post confirm_registration_request_path(t: @request_record.token), params: { marketing: "1" }
    assert_response :gone
    assert @registrations.none? { |registration| registration.reload.marketing_consent? }
  end

  test "SÉCURITÉ : un retrait vaut pour la personne — toutes ses demandes, propagé au CRM" do
    ENV["CRM_SYNC_ENABLED"] = "1"
    @request_record.update!(marketing_box_checked: true)
    post confirm_registration_request_path(t: @request_record.token), params: { marketing: "1" }
    @registrations.each { |registration| assert_enqueued_with(job: CrmSyncJob, args: [ registration.id ]) }

    third = Webinar.create!(title: "Café IA de janvier", starts_at: 60.days.from_now, host_sub: "h", visibility: "published")
    later = RegistrationRequest.create!(name: "Camille", email: "camille@example.test", marketing_box_checked: true)
    january, = Registration.find_or_create_for(third, email: later.email, name: later.name, registration_request: later)
    post confirm_registration_request_path(t: later.token), params: { marketing: "1" }
    assert january.reload.marketing_consent?
    stranger = third.registrations.create!(name: "Bob", email: "bob@example.test", confirmed_at: Time.current)
    stranger.update!(marketing_consent: true, marketing_consent_at: Time.current, marketing_withdrawal_token: "bob-token")

    post confirm_marketing_withdrawal_path(t: @registrations.first.reload.marketing_withdrawal_token)
    assert_response :success
    (@registrations + [ january ]).each do |registration|
      registration.reload
      assert_not registration.marketing_consent?
      assert registration.marketing_consent_withdrawn?
      assert registration.confirmed?, "le retrait n'annule pas l'inscription"
      assert_enqueued_with(job: CrmMarketingWithdrawalJob, args: [ registration.id ])
    end
    assert stranger.reload.marketing_consent?, "jamais une autre adresse"
  end

  test "« préviens-moi » seul, case cochée — deux boutons, accord sur la demande, retrait par la page" do
    ENV["CRM_SYNC_ENABLED"] = "1"
    lone = RegistrationRequest.create!(name: "Lou", email: "lou@example.test", notify_next: true, marketing_box_checked: true)
    get registration_request_path(t: lone.token)
    assert_select "[data-role=marketing-consent-notice]", /a été cochée lors de cette demande/
    assert_select "button[data-role=confirm-with-marketing]"

    assert_enqueued_with(job: CrmNotifyNextJob, args: [ lone.id ]) do
      post confirm_registration_request_path(t: lone.token), params: { marketing: "1" }
    end
    assert lone.reload.marketing_consent?
    assert_select "[data-role=marketing-consent-given] a[href=?]", marketing_withdrawal_path(t: lone.marketing_withdrawal_token)

    get marketing_withdrawal_path(t: lone.marketing_withdrawal_token)
    assert_response :success
    assert_includes response.body, "préviens-moi du prochain Café IA"
    assert_enqueued_with(job: CrmNotifyNextJob, args: [ lone.id ]) do
      post confirm_marketing_withdrawal_path(t: lone.marketing_withdrawal_token)
    end
    assert_response :success
    assert lone.reload.marketing_consent_withdrawn?
    assert_not lone.marketing_consent?
  end

  test "case cochée mais aucun café affiché ni « préviens-moi » : ni avis ni choix" do
    @first.update!(visibility: "draft")
    @second.update!(visibility: "draft")
    @request_record.update!(marketing_box_checked: true)
    get registration_request_path(t: @request_record.token)
    assert_select "[data-role=marketing-consent-notice]", count: 0
    assert_select "button", text: "Confirmer mon inscription"
  end

  test "un retrait par une inscription retire aussi l'accord d'une demande « préviens-moi » du même email" do
    lone = RegistrationRequest.create!(name: "Camille", email: "camille@example.test", notify_next: true,
                                       marketing_box_checked: true)
    post confirm_registration_request_path(t: lone.token), params: { marketing: "1" }
    @request_record.update!(marketing_box_checked: true)
    post confirm_registration_request_path(t: @request_record.token), params: { marketing: "1" }

    post confirm_marketing_withdrawal_path(t: @registrations.first.reload.marketing_withdrawal_token)
    assert lone.reload.marketing_consent_withdrawn?
    assert @registrations.all? { |registration| registration.reload.marketing_consent_withdrawn? }
  end

  test "SÉCURITÉ : le jeton `t` est filtré des logs Rails" do
    io = StringIO.new
    originals = [ Rails.logger, ActionController::Base.logger ]
    Rails.logger = ActionController::Base.logger = ActiveSupport::Logger.new(io)
    begin
      get registration_request_path(t: @request_record.token)
      post confirm_registration_request_path(t: @request_record.token)
    ensure
      Rails.logger, ActionController::Base.logger = originals
    end
    assert_match(/Parameters:/, io.string, "le log observé est bien celui du contrôleur")
    assert_no_match(/#{Regexp.escape(@request_record.token)}/, io.string)
  end
end
