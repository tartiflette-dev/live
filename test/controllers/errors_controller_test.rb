# frozen_string_literal: true

require "test_helper"

# Pages hors-session (ErrorsController + exceptions_app). Cas réel : un
# consommateur qui demande JSON (aperçu WhatsApp,
# scanner) ne doit JAMAIS provoquer un second 500 côté ErrorsController.
class ErrorsControllerTest < ActionDispatch::IntegrationTest
  test "rendu HTML sur route /erreur/404" do
    get erreur_path(code: "404")
    assert_response :not_found
    assert_match(%r{text/html}, response.media_type)
  end

  test "rendu HTML même si Accept réclame JSON (pas de 500)" do
    get erreur_path(code: "500"), headers: { "Accept" => "application/json" }
    assert_response :internal_server_error
    assert_match(%r{text/html}, response.media_type)
  end

  test "code hors liste (422) retombe sur 500 sans exception" do
    get erreur_path(code: "422")
    assert_response :internal_server_error
  end
end
