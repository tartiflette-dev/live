require "application_system_test_case"
require "undust/charte/testing/mobile_contract" if Theme.undust?

# Écran d'envoi au téléphone, depuis la régie pendant le direct : contrat
# mobile de la charte (pas de débordement, contenu non rogné, cibles
# tactiles) sur la composition et l'aperçu, en Chrome réel. Émulation de
# viewport : la preuve sur un vrai téléphone se fait hors suite.
class AnnouncementsMobileTest < ApplicationSystemTestCase
  include OidcSignIn

  # Écart PRÉEXISTANT de la bande basse des pages animateur connectées (toutes
  # pages, contenu indifférent, consigné comme dette) : signature undust. trop
  # serrée contre sa voisine. Seule entrée tolérée ; tout autre écart, de cible
  # ou d'une autre famille, fait échouer le test. À retirer avec la correction
  # du chrome bas.
  KNOWN_CHROME_DEFECT = "a.chrome-signature cible sans espacement"

  setup { require_undust_theme! }
  include Undust::Charte::Testing::MobileContract if Theme.undust?

  if Theme.undust?
    driven_by :selenium, using: :headless_chrome, screen_size: [ 412, 915 ], options: { name: :undust_charte_mobile } do |options|
      Undust::Charte::Testing::MobileContract.configure_chrome(options)
    end
  end

  test "composition et aperçu tiennent le contrat mobile" do
    owner = User.create!(email: "owner@example.test", oidc_sub: "sub-owner")
    webinar = announcement_webinar(host_sub: owner.oidc_sub)
    confirmed_registration(webinar, "ana@example.test")
    sign_in_as(owner)

    visit new_webinar_announcement_path(webinar)
    assert_mobile_contract(touch_targets: "input[type=radio]")
    choose "Inscrits confirmés de ce webinaire"
    fill_in "Objet", with: "Salle 2"
    fill_in "Message", with: "Le café a lieu salle 2, au fond du couloir à droite. " * 6
    click_button "Voir l'aperçu"
    assert_selector "[data-role=recipients-count]", text: "1 destinataire"

    # Aperçu : bouton d'envoi et case sous le pli, mesurés après défilement
    # par la boucle générale du contrat (les cibles explicites le sont en haut).
    assert_mobile_contract(touch_targets: nil)
  end

  private

  def assert_mobile_contract(touch_targets:)
    [ [ 412, 915 ], [ 360, 915 ], [ 320, 915 ] ].each do |width, height|
      resize_undust_viewport(width, height)
      assert_undust_mobile(touch_targets: touch_targets)
    rescue Minitest::Assertion => error
      raise unless only_known_chrome_defect?(error.message)
    end
  end

  # « targets » est la dernière famille vérifiée par assert_undust_mobile :
  # échouer là, c'est avoir passé débordement, contenu rogné et chrome.
  def only_known_chrome_defect?(message)
    entries = message[/ : targets — (.*?)\nExpected/m, 1]
    entries.present? && entries.split("; ").all? { |entry| entry.start_with?(KNOWN_CHROME_DEFECT) }
  end
end
