# frozen_string_literal: true

require "application_system_test_case"

# Page d'un webinaire dans un vrai navigateur (rangement par moment) : le menu
# « … » s'ouvre au clavier, chaque action destructrice demande
# confirmation (confirm_action.js), et la page tient sur un téléphone de
# 412 px sans défilement horizontal.
class WebinarPageMenusTest < JsSystemTestCase
  include OidcSignIn

  setup do
    @owner = User.create!(email: "owner@example.test", oidc_sub: "menus-owner")
    @webinar = Webinar.create!(title: "Café IA 9", slug: "cafe-ia-9", kind: "cafe_ia", visibility: "published",
                               starts_at: 2.days.from_now, host_sub: @owner.oidc_sub)
    @share_token = @webinar.generate_share_token!
    @speaker = @webinar.speakers.create!(name: "Basile")
    sign_in_as(@owner)
    visit webinar_path(@webinar)
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "le menu « … » d'un intervenant s'ouvre au clavier, fermé par défaut" do
    within("tr[data-speaker-id='#{@speaker.id}']") do
      assert_no_button "Révoquer"
      summary = find("[data-role='speaker-menu'] summary")
      summary.send_keys(:enter)
      assert_button "Révoquer"
      assert_button "Régénérer (invalide l’ancien)"
    end
  end

  test "Révoquer demande confirmation : refusée, rien ne change ; acceptée, le lien est révoqué" do
    within("tr[data-speaker-id='#{@speaker.id}']") do
      find("[data-role='speaker-menu'] summary").click
      dismiss_confirm(/Révoquer le lien de Basile/) { click_button "Révoquer" }
    end
    assert_selector "tr[data-speaker-id='#{@speaker.id}'] button[data-role='speaker-copy']"
    assert_nil @speaker.reload.revoked_at

    within("tr[data-speaker-id='#{@speaker.id}']") do
      accept_confirm(/Révoquer le lien de Basile/) { click_button "Révoquer" }
    end
    assert_selector "tr[data-speaker-id='#{@speaker.id}']", text: /lien révoqué/i
    assert @speaker.reload.revoked_at?
  end

  test "Désactiver le lien participants privé demande confirmation" do
    within("[data-role='invitation-link']") do
      find("[data-role='invitation-menu'] summary").click
      dismiss_confirm(/Désactiver le lien participants privé/) { click_button "Désactiver" }
    end
    assert_equal @share_token, @webinar.reload.share_token

    within("[data-role='invitation-link']") do
      accept_confirm(/Désactiver le lien participants privé/) { click_button "Désactiver" }
    end
    assert_button "Générer le lien participants privé"
    assert_nil @webinar.reload.share_token
  end

  # Chaque menu « … » ouvert reste dans l'écran, et ses boutons reçoivent
  # le toucher : rien n'est rogné par un conteneur ni recouvert.
  { "téléphone 412 px" => [ 412, 915, true ], "écran large 1440 px" => [ 1440, 900, false ] }.each do |screen, (width, height, mobile)|
    test "#{screen} : menus « … » ouverts dans l'écran, page sans défilement horizontal" do
      @webinar.host_invitations.create!(created_by_sub: @owner.oidc_sub, max_uses: 3, expires_at: 1.day.from_now)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height,
                                                                             deviceScaleFactor: 1, mobile: mobile)
      visit webinar_path(@webinar)
      find("summary", text: "Avancé : lien animateur").click
      find("summary", text: "Détails techniques").click

      %w[speaker-menu invitation-menu host-invitation-menu].each do |role|
        summary = find("[data-role='#{role}'] summary")
        summary.click
        assert_menu_reachable(role, width)
        summary.click
      end

      overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
      assert_operator overflow, :<=, 0, "la page déborde de #{overflow} px en largeur"
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  end

  private

  def assert_menu_reachable(role, width)
    report = page.evaluate_script(<<~JS)
      (() => {
        const panel = document.querySelector("[data-role='#{role}'] .menu-actions__panneau");
        panel.scrollIntoView({ block: "center" });
        const box = panel.getBoundingClientRect();
        const buttons = [...panel.querySelectorAll("button")].map((button) => {
          const r = button.getBoundingClientRect();
          const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
          return { label: button.textContent.trim(), reached: button === hit || button.contains(hit) };
        });
        return { left: box.left, right: box.right, buttons };
      })()
    JS
    assert_operator report["left"], :>=, 0, "#{role} : panneau rogné à gauche (#{report['left']} px)"
    assert_operator report["right"], :<=, width, "#{role} : panneau rogné à droite (#{report['right']} px)"
    report["buttons"].each { |button| assert button["reached"], "#{role} : « #{button['label']} » ne reçoit pas le toucher" }
  end
end
