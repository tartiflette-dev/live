# frozen_string_literal: true

require "test_helper"
# Thème undust seulement : la gem undust-charte fournit le contrat testé ;
# sous un autre thème, les tests sont sautés (comptés), pas retirés.
require "undust/charte/testing/ecran_accueil_contract" if Theme.undust?

# Écran d'accueil — manifest + apple-touch-icon opaques servis par
# la gem (`Undust::Charte::EcranAccueil`, middleware en tête de pile) sur le
# layout `application` de live. Live n'est pas installable au registre →
# display = browser.
class CharteEcranAccueilTest < ActionDispatch::IntegrationTest
  setup { require_undust_theme! }
  include Undust::Charte::Testing::EcranAccueilContract if Theme.undust?

  test "catalogue (layout application) : contrat écran d'accueil servi par la gem" do
    get root_path
    assert_response :success
    assert_undust_ecran_accueil
  end
end
