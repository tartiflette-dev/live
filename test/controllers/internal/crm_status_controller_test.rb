require "test_helper"

# Sonde de la supervision CRM — GET /internal/crm_status.
class Internal::CrmStatusControllerTest < ActionDispatch::IntegrationTest
  KEYS = %w[CRM_STATUS_TOKEN CRM_SYNC_ENABLED REMINDERS_ENABLED].freeze

  setup do
    @saved = KEYS.index_with { |key| ENV[key] }
    ENV["CRM_STATUS_TOKEN"] = "sonde-test"
    ENV["CRM_SYNC_ENABLED"] = "1"
    @webinar = Webinar.create!(title: "Café IA", starts_at: 1.day.from_now, host_sub: "h", visibility: "published")
  end

  teardown { @saved.each { |key, value| ENV[key] = value } }

  test "fermée sans CRM_STATUS_TOKEN, ou avec une valeur vide (secret de déploiement vide) : 404" do
    [ nil, "" ].each do |value|
      ENV["CRM_STATUS_TOKEN"] = value
      get internal_crm_status_path, headers: auth("")
      assert_response :not_found, value.inspect
    end
  end

  test "jeton : seul `Authorization: Bearer <jeton>` est accepté (pas le jeton nu, pas un autre schéma)" do
    [ "sonde-test", "Token sonde-test", "bearer sonde-test", "Bearer  sonde-test", "Bearer" ].each do |value|
      get internal_crm_status_path, headers: { "Authorization" => value }
      assert_response :unauthorized, value.inspect
    end
  end

  test "jeton absent ou faux : 401, aucun compteur" do
    get internal_crm_status_path
    assert_response :unauthorized
    get internal_crm_status_path, headers: auth("autre")
    assert_response :unauthorized
    assert_empty response.body
  end

  test "rien en attente : 200, alert false" do
    get internal_crm_status_path, headers: auth("sonde-test")
    assert_response :ok
    body = response.parsed_body
    assert_equal({ "registrations" => 0, "notify_next" => 0, "withdrawals" => 0, "total" => 0 }, body["pending"])
    assert_nil body["oldest_pending_at"]
    assert_equal false, body["alert"]
    assert_equal true, body["crm_sync_enabled"]
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "attente récente sans échec : 200, compteurs, sans PII" do
    registration("camille@example.test", crm_enrolled_at: 2.hours.ago, name: "Camille")
    get internal_crm_status_path, headers: auth("sonde-test")
    assert_response :ok
    body = response.parsed_body
    assert_equal 1, body["pending"]["registrations"]
    assert_in_delta 2.hours.to_i, body["oldest_pending_age_seconds"], 5
    assert_no_match(/camille/i, response.body)
  end

  test "ALERTE (503) : une attente de plus de 24 h" do
    registration("a@example.org", crm_enrolled_at: 25.hours.ago, crm_sync_attempts: 9, crm_last_error_code: 503)
    get internal_crm_status_path, headers: auth("sonde-test")
    assert_response :service_unavailable
    body = response.parsed_body
    assert body["alert"]
    assert_equal 1, body["failing"]
    assert_equal 0, body["permanent_failures"]
  end

  test "ALERTE (503) : un échec permanent, même récent (retrait compris)" do
    registration("a@example.org", crm_enrolled_at: 1.hour.ago, pushed_to_crm_at: 1.hour.ago, crm_contact_id: "4",
                           marketing_consent_withdrawn_at: 10.minutes.ago, crm_withdrawal_last_error_code: 404)
    get internal_crm_status_path, headers: auth("sonde-test")
    assert_response :service_unavailable
    assert_equal 1, response.parsed_body["pending"]["withdrawals"]
    assert_equal 1, response.parsed_body["permanent_failures"]
    assert_equal 1, response.parsed_body["withdrawal_contact_not_found"]
  end

  test "fiche partie (état terminal attendu) : comptée, sans alerte" do
    registration("a@example.org", crm_enrolled_at: 2.days.ago, crm_sync_contact_gone_at: 1.day.ago)
    CrmDisappearance.record!("55")
    get internal_crm_status_path, headers: auth("sonde-test")
    assert_response :ok
    body = response.parsed_body
    assert_equal({ "registrations" => 1, "notify_next" => 0 }, body["contact_gone"])
    assert_equal 1, body["disappeared_contacts"]
    assert_equal 0, body["pending"]["total"]
  end

  test "synchro coupée : jamais d'alerte, l'attente reste visible" do
    ENV["CRM_SYNC_ENABLED"] = "0"
    registration("a@example.org", crm_enrolled_at: 3.days.ago)
    get internal_crm_status_path, headers: auth("sonde-test")
    assert_response :ok
    assert_equal false, response.parsed_body["alert"]
    assert_equal 1, response.parsed_body["pending"]["total"]
  end

  test "bloc reminders : dernier passage et cumuls du jour, sans effet sur alert" do
    ENV["REMINDERS_ENABLED"] = "1"
    paris = Time.find_zone("Europe/Paris")
    RegistrationReminderRun.create!(ran_at: paris.parse("2026-11-02 20:00"), due: 9, sent: 9)
    RegistrationReminderRun.create!(ran_at: paris.parse("2026-11-03 09:00"), due: 3, sent: 2, abandoned: 1)
    RegistrationReminderRun.create!(ran_at: paris.parse("2026-11-03 10:00"), due: 3, skipped: 2, smtp_retry: 1)

    travel_to(paris.parse("2026-11-03 10:05")) { get internal_crm_status_path, headers: auth("sonde-test") }

    assert_response :ok, "un abandon de rappel ne change pas la règle d'alerte CRM"
    reminders = response.parsed_body["reminders"]
    assert_equal true, reminders["enabled"]
    assert_equal paris.parse("2026-11-03 10:00").iso8601, reminders["last_run_at"]
    assert_equal({ "due" => 3, "sent" => 0, "skipped" => 2, "smtp_retry" => 1, "abandoned" => 0, "failed" => 0 },
                 reminders["last_run"])
    assert_equal({ "sent" => 2, "skipped" => 2, "smtp_retry" => 1, "abandoned" => 1, "failed" => 0 }, reminders["today"])
  end

  test "bloc reminders sans aucune tournée : null, coupé" do
    ENV["REMINDERS_ENABLED"] = nil
    get internal_crm_status_path, headers: auth("sonde-test")
    reminders = response.parsed_body["reminders"]
    assert_equal false, reminders["enabled"]
    assert_nil reminders["last_run_at"]
    assert_nil reminders["last_run"]
    assert_equal 0, reminders["today"]["sent"]
  end

  private

  def auth(token)
    { "Authorization" => "Bearer #{token}" }
  end

  def registration(email, name: "P", **attrs)
    @webinar.registrations.create!(name: name, email: email, confirmed_at: Time.current,
                                   crm_enrolled_at: Time.current, **attrs)
  end
end
