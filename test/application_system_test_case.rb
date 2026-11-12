require "test_helper"
require "capybara/rails"
require "selenium/webdriver"

# Système Capybara — exige Capybara d'office.
#
# DEUX DRIVERS ici, arbitrés par la classe de test — voir cible ci-dessous.
# - `ApplicationSystemTestCase` (rack_test, défaut) : PAS de navigateur
#   headless, PAS de JS. Suffisant pour les flows serveur (formulaires,
#   redirections, contenu HTML) — ce qu'exigent les critères d'acceptation
#   (le HTML container React se vérifie sans exécuter React).
# - `JsSystemTestCase` (selenium_chrome_headless) : EXÉCUTE le JS. Requis
#   pour les vues salle React (PreJoin, LiveKitRoom) où le rendu réel
#   n'est visible qu'après montage. Sans ce driver, un crash hooks React
# (écran blanc observé en staging) passe INAPERÇU en CI : ce driver
#   l'attrape.
#
# Fake device flags Chrome : permettent de tester la salle SANS media réel.
# --use-fake-device-for-media-stream : streams synthétiques micro/caméra.
# --use-fake-ui-for-media-stream     : bypass du prompt d'autorisation.
# --no-sandbox                       : requis en CI conteneurisé (act_runner).
# --headless=new                     : mode headless moderne (Chrome 109+).
module ViewerRegistrationSystemHelpers
  # `participation_chosen: false` : inscription qui n'a jamais choisi
  # « J'observe » ou « Je participe » (site partenaire) ; la salle le demande
  # avant d'entrer. Par défaut le choix est fait, la salle s'ouvre.
  def confirm_viewer_registration(webinar, participation_chosen: true)
    registration = webinar.registrations.find_or_create_by!(email: "viewer@example.test") do |record|
      record.name = "Spectateur confirmé"
    end
    registration.update!(participation_chosen_at: participation_chosen ? Time.current : nil)
    visit confirm_registration_path(registration.token)
    # Libellé du bouton dans la tonalité de l'émission (Voice) : ce helper
    # navigue, les textes ont leurs propres tests. Inscription déjà confirmée :
    # bouton d'accès, le GET ne donne plus l'accès seul.
    step = registration.confirmed? ? "access" : "confirm"
    click_button Voice.t("registrations.#{step}.button", voice: webinar.voice)
    # Attendre la redirection : avec un vrai navigateur, `click_button` rend
    # la main avant la réponse, et un `visit` immédiat partirait sans cookie.
    assert_current_path public_webinar_path(webinar.slug)
  end
end

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  include ViewerRegistrationSystemHelpers
  driven_by :rack_test
end

class JsSystemTestCase < ActionDispatch::SystemTestCase
  include ViewerRegistrationSystemHelpers

  # Isolation des tests : chaque réponse qui lit la session renvoie le
  # cookie de session (mesuré : /regie/status, /w/:slug/messages). Une page
  # qui relit le serveur en boucle (régie, salle) peut le RÉÉCRIRE après
  # l'effacement de Capybara.reset_sessions! (requête en vol sur un serveur
  # chargé, quatre processus en parallèle) : le test suivant du même
  # navigateur héritait alors de la session animateur, et un spectateur
  # recevait un jeton host et le PreJoin (échecs intermittents des tests
  # « spectateur » de hand_raises_room, spotlight, stage_layout, room_chat ;
  # cookie de session présent au début du test, mesuré).
  #   - Fin de test, après la capture d'échec et avant la remise à zéro :
  #     on quitte la page pour une page du même site sans script ni session
  #     (/up) ; les relectures cessent.
  #   - Début de test : on repart sans cookie, quoi qu'ait laissé une
  #     réponse tardive du test précédent.
  def before_teardown
    super
  ensure
    visit rails_health_check_path
  end

  setup do
    visit rails_health_check_path
    page.driver.browser.manage.delete_all_cookies
  end

  # Clic au centre de l'écran. Avant de cliquer un élément hors écran,
  # chromedriver le fait défiler juste au bord bas de la fenêtre, sous la
  # barre basse fixe du chrome : « element click intercepted ». Le clic
  # dépendait de la hauteur de la page et de la vitesse du runner (passe en
  # local, échoue en CI). On centre l'élément d'abord ; `choose` et `check`
  # passent aussi par ce clic.
  module ClicAuCentre
    def click(*args, **options)
      driver.execute_script("arguments[0].scrollIntoView({ block: 'center', inline: 'nearest' })", self)
      super
    end
  end
  Capybara::Selenium::Node.prepend(ClicAuCentre)

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 900 ] do |driver_option|
    driver_option.add_argument("--headless=new")
    driver_option.add_argument("--no-sandbox")
    driver_option.add_argument("--disable-dev-shm-usage")
    driver_option.add_argument("--disable-gpu")
    driver_option.add_argument("--use-fake-device-for-media-stream")
    driver_option.add_argument("--use-fake-ui-for-media-stream")
    # CI : binaire assorti au chromedriver installé par la CI.
    # Sans CHROME_BIN, Selenium Manager choisit le navigateur.
    chrome_bin = ENV["CHROME_BIN"].presence
    driver_option.binary = chrome_bin if chrome_bin
  end
end
