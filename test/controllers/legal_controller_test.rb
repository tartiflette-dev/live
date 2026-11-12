require "test_helper"

# /confidentialite sert la politique de l'instance quand elle en fournit une
# (PrivacyPolicy), sinon la page générique publiée avec le logiciel.
class LegalControllerTest < ActionDispatch::IntegrationTest
  INSTANCE_VIEWS = Rails.root.join("test/fixtures/files/privacy_policy")

  test "sans politique d'instance : la page générique décrit ce que traite le logiciel" do
    with_policy(PrivacyPolicy::GENERIC) { get confidentialite_path }

    assert_response :success
    assert_select "[data-role='privacy'] h1", "Politique de confidentialité — live.example.test"
    assert_select "[data-role='privacy'] p em", "Version 1.0 — 12 novembre 2026."
    assert_select "[data-role='privacy-generic']", /c'est lui qui fixe les finalités, les\s+bases légales, les destinataires/
    assert_select "[data-role='privacy']", /Studio Exemple — entreprise de démonstration/
    assert_select "[data-role='privacy'] a[href='mailto:contact@example.test']"
    ParticipantConsent::LABELS.each_value do |label|
      assert_select "[data-role='participant-consent'] li", /« #{Regexp.escape(label)} »/
    end
    body = response.body
    assert_match(/non confirmée est effacée 30 jours après la demande ; une inscription confirmée,\s+12 mois après la date du webinaire/, body)
    assert_match(/au plus tard 3 ans après la date\s+du webinaire/, body)
    assert_match(/Un spectateur qui ne prend pas la parole n'est jamais enregistré/, body)
  end

  test "la page générique ne nomme ni l'instance d'origine, ni ses partenaires, ni ses sous-traitants" do
    with_policy(PrivacyPolicy::GENERIC) { get confidentialite_path }

    assert_no_match(/undust|tartiflette|OVH|Scaleway|WhatsApp|LinkedIn|Nextcloud|Café IA/i, css_select("[data-role='privacy']").to_html)
  end

  test "politique d'instance présente : elle remplace la page générique, avec sa version" do
    policy = PrivacyPolicy.resolve(INSTANCE_VIEWS)
    previous = LegalController.view_paths
    LegalController.prepend_view_path(INSTANCE_VIEWS)

    with_policy(policy) { get confidentialite_path }

    assert_response :success
    assert_select "[data-role='privacy'] h1", "Politique de l'instance d'exemple"
    assert_select "[data-role='privacy'] p em", "Version 3.1 — 1er mars 2027."
    assert_select "[data-role='privacy-generic']", false
  ensure
    LegalController.view_paths = previous
  end

  # Page publique : pas de fil d'ariane animateur (il pointe vers l'index
  # animateur), pas de lien vers la zone animateur dans le canvas.
  test "aucun fil d'ariane animateur pour un visiteur anonyme" do
    get confidentialite_path

    assert_response :success
    assert_select "nav.fil-ariane", false, "le fil d'ariane animateur ne doit pas s'afficher aux anonymes"
    assert_select "main.chrome-fenetre a[href=?]", webinars_path, false,
      "aucun lien vers la zone animateur dans le canvas d'une page publique"
  end

  private

  def with_policy(policy, &block)
    stub_const(PrivacyPolicy, :TEMPLATE, policy.template) do
      stub_const(PrivacyPolicy, :VERSION, policy.version) do
        stub_const(PrivacyPolicy, :DATE, policy.date, &block)
      end
    end
  end
end
