require "test_helper"

# Retrait du consentement :
# GET /mc/withdraw?t=… sans effet, POST applique le retrait et le propage
# au CRM via `CrmMarketingWithdrawalJob`.
class MarketingWithdrawalsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @webinar = Webinar.create!(
      title: "Café IA public", starts_at: 1.day.from_now,
      host_sub: "host", visibility: "published"
    )
    @registration = @webinar.registrations.create!(
      name: "Alice", email: "alice@example.test", confirmed_at: Time.current
    )
    @registration.request_marketing_consent!
    @registration.apply_marketing_consent!
    @registration.update!(pushed_to_crm_at: Time.current, crm_contact_id: "42")
    @token = @registration.reload.marketing_withdrawal_token
  end

  test "GET /mc/withdraw affiche le formulaire SANS mutation" do
    assert_no_enqueued_jobs do
      get marketing_withdrawal_path(t: @token)
    end
    assert_response :success
    assert_match(/Tu ne veux plus que Studio Exemple te recontacte/, response.body)
    assert_select "button[type=submit]", /Oui, je retire mon accord/
    assert @registration.reload.marketing_consent, "consentement intact tant que POST non reçu"
  end

  test "café dépublié (annulé) : le retrait fonctionne quand même, sous un titre neutre" do
    @webinar.update!(visibility: "draft")

    get marketing_withdrawal_path(t: @token)
    assert_response :success
    assert_match(/un café qui n&#39;est plus au programme/, response.body)
    assert_no_match(/Café IA public/, response.body)

    post confirm_marketing_withdrawal_path(t: @token)
    assert_response :success
    assert_not @registration.reload.marketing_consent?
    assert @registration.marketing_consent_withdrawn?
  end

  test "GET /mc/withdraw : aucune donnée personnelle (ni email, ni nom)" do
    get marketing_withdrawal_path(t: @token)
    assert_response :success
    assert_no_match(/#{@registration.email}/, response.body)
    assert_no_match(/\bAlice\b/, response.body)
  end

  test "GET /mc/withdraw : Referrer-Policy strict-origin, Cache-Control no-store" do
    get marketing_withdrawal_path(t: @token)
    assert_equal "strict-origin", response.headers["Referrer-Policy"]
    assert_equal "no-store",    response.headers["Cache-Control"]
  end

  test "POST /mc/withdraw : applique le retrait, enqueue le job CRM si drapeau on" do
    with_crm_sync_enabled do
      assert_enqueued_with(job: CrmMarketingWithdrawalJob, args: [ @registration.id ]) do
        post confirm_marketing_withdrawal_path(t: @token)
      end
    end
    assert_response :success
    @registration.reload
    assert_not @registration.marketing_consent
    assert_not_nil @registration.marketing_consent_withdrawn_at
    assert_nil @registration.marketing_withdrawal_token
    # Le retrait arrête la prospection, la fiche reste.
    assert_select "[data-role='marketing-withdrawal-created']", /où ta fiche reste/
    assert_select "[data-role='marketing-withdrawal-created']", /Pour demander qu'on l'efface/
  end

  test "SÉCURITÉ : enqueue CrmMarketingWithdrawalJob même SANS pushed_to_crm_at" do
    # Si CrmSyncJob a créé le contact côté CRM
    # puis abandonné avant la pose de pushed_to_crm_at (retrait concurrent),
    # on doit propager le retrait même quand `crm_pushed?` est false.
    # Le job sait retrouver le contact via search_by_email.
    @registration.update!(pushed_to_crm_at: nil)
    with_crm_sync_enabled do
      assert_enqueued_with(job: CrmMarketingWithdrawalJob, args: [ @registration.id ]) do
        post confirm_marketing_withdrawal_path(t: @token)
      end
    end
    assert_not @registration.reload.marketing_consent
  end

  test "POST /mc/withdraw : drapeau off → retrait posé, mais aucun job CRM" do
    assert_no_enqueued_jobs(only: CrmMarketingWithdrawalJob) do
      post confirm_marketing_withdrawal_path(t: @token)
    end
    assert_not @registration.reload.marketing_consent
  end

  test "POST /mc/withdraw rejoué : 2e appel idempotent, pas d'erreur" do
    post confirm_marketing_withdrawal_path(t: @token)
    assert_no_enqueued_jobs do
      post confirm_marketing_withdrawal_path(t: @token)
    end
    assert_response :not_found
  end

  test "scanner GET répété sur withdraw : effet nul" do
    assert_no_enqueued_jobs do
      5.times { get marketing_withdrawal_path(t: @token) }
    end
    assert @registration.reload.marketing_consent
  end

  test "GET avec jeton inconnu : 404 propre" do
    get marketing_withdrawal_path(t: "jeton-inconnu")
    assert_response :not_found
  end

  test "SÉCURITÉ : jeton de retrait filtré des logs" do
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io).tap { |l| l.formatter = ->(_s, _t, _p, m) { "#{m}\n" } }
    begin
      get marketing_withdrawal_path(t: @token)
    ensure
      Rails.logger = original
    end
    assert_no_match(/#{Regexp.escape(@token)}/, io.string, "le jeton ne doit pas apparaître dans les logs")
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
