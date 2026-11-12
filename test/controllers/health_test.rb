require "test_helper"

class HealthTest < ActionDispatch::IntegrationTest
  # /up rend 200 (Rails::HealthController monté par défaut).
  # Cette assertion protège la route de santé contre une régression accidentelle
  # (suppression dans config/routes.rb, initializer qui raise, etc.).
  test "up_returns_200" do
    get "/up"
    assert_response :success
    assert_equal 200, response.status
  end
end
