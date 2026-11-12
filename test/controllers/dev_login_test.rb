# frozen_string_literal: true

require "test_helper"

# Connexion de développement (lib/dev_login.rb) : hors développement, elle
# n'existe qu'avec LIVE_DEV_LOGIN=1, lu à chaque requête.
class DevLoginControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn
  setup { @previous = ENV["LIVE_DEV_LOGIN"] }
  teardown { @previous.nil? ? ENV.delete("LIVE_DEV_LOGIN") : ENV["LIVE_DEV_LOGIN"] = @previous }

  def enable! = ENV["LIVE_DEV_LOGIN"] = "1"

  test "désactivée : POST /dev_login en 404, aucun compte créé, pas de formulaire" do
    ENV.delete("LIVE_DEV_LOGIN")

    assert_no_difference -> { User.count } do
      post dev_login_path, params: { email: "host@example.test" }
    end
    assert_response :not_found

    get sign_in_path
    assert_select "[data-role='dev-login']", count: 0
  end

  test "activée : le formulaire s'affiche à côté du bouton OIDC" do
    enable!
    get sign_in_path

    assert_select "form[data-role='dev-login'][action=?]", dev_login_path do
      assert_select "input[type=email][name=email]"
    end
    assert_select "form[action=?]", "/auth/pocket_id"
  end

  test "activée : l'adresse ouvre une session d'animateur du projet" do
    enable!
    post dev_login_path, params: { email: " Host@Example.test " }

    assert_redirected_to webinars_path
    user = User.find_by!(email: "host@example.test")
    assert_equal "#{DevLogin::SUB_PREFIX}host@example.test", user.oidc_sub
    assert_predicate user, :project_host?
    assert_predicate user, :email_verified_and_fresh?

    get new_webinar_path
    assert_response :success
  end

  test "activée : une seconde connexion retrouve le même compte" do
    enable!
    post dev_login_path, params: { email: "host@example.test" }
    delete sign_out_path

    assert_no_difference -> { User.count } do
      post dev_login_path, params: { email: "host@example.test" }
    end
    assert_redirected_to webinars_path
  end

  test "activée : retour à la page demandée avant la connexion" do
    enable!
    get new_webinar_path
    assert_redirected_to sign_in_path

    post dev_login_path, params: { email: "host@example.test" }
    assert_redirected_to new_webinar_path
  end

  test "activée : adresse invalide refusée" do
    enable!

    assert_no_difference -> { User.count } do
      post dev_login_path, params: { email: "pas une adresse" }
    end
    assert_redirected_to sign_in_path
  end

  test "activée : l'adresse d'un compte OIDC existant n'en prend pas la place" do
    enable!
    User.create!(email: "real@example.test", oidc_sub: "oidc-sub-real")

    post dev_login_path, params: { email: "real@example.test" }

    assert_redirected_to sign_in_path
    assert_nil session[:user_id]
    assert_not User.exists?(oidc_sub: "#{DevLogin::SUB_PREFIX}real@example.test")
  end

  test "activée : la casse de l'adresse ne contourne pas un compte OIDC existant" do
    enable!
    User.create!(email: "Real@Example.test", oidc_sub: "oidc-sub-real")

    assert_no_difference -> { User.count } do
      post dev_login_path, params: { email: "real@example.TEST" }
    end
    assert_redirected_to sign_in_path
    assert_nil session[:user_id]
  end

  test "activée mais origine publique : 404, pas de formulaire" do
    enable!
    public_peer = { "REMOTE_ADDR" => "203.0.113.5" }

    assert_no_difference -> { User.count } do
      post dev_login_path, params: { email: "host@example.test" }, headers: public_peer
    end
    assert_response :not_found

    get sign_in_path, headers: public_peer
    assert_select "[data-role='dev-login']", count: 0
    assert_select "[data-role='dev-login-local-only']"
  end

  test "activée : un X-Forwarded-For loopback venant d'un pair public ne passe pas" do
    enable!
    post dev_login_path, params: { email: "host@example.test" },
                         headers: { "REMOTE_ADDR" => "203.0.113.5", "X-Forwarded-For" => "127.0.0.1" }

    assert_response :not_found
  end

  test "activée : poste du réseau local + X-Forwarded-For loopback, sans réseau déclaré : 404" do
    enable!

    assert_no_difference -> { User.count } do
      post dev_login_path, params: { email: "host@example.test" },
                           headers: { "REMOTE_ADDR" => "192.168.1.50", "X-Forwarded-For" => "127.0.0.1" }
    end
    assert_response :not_found
  end

  test "activée : même falsification avec un réseau déclaré qui n'inclut pas le poste : 404" do
    enable!

    with_networks("172.16.0.0/12") do
      post dev_login_path, params: { email: "host@example.test" },
                           headers: { "REMOTE_ADDR" => "192.168.1.50", "X-Forwarded-For" => "127.0.0.1" }
    end
    assert_response :not_found
  end

  test "activée : passerelle Docker déclarée qui ajoute un en-tête de transfert : 404" do
    enable!

    with_networks("172.16.0.0/12") do
      post dev_login_path, params: { email: "host@example.test" },
                           headers: { "REMOTE_ADDR" => "172.29.0.1", "X-Real-IP" => "172.29.0.1" }
    end
    assert_response :not_found
  end

  test "activée : loopback brut, sans en-tête de transfert : connecté" do
    enable!
    post dev_login_path, params: { email: "host@example.test" }, headers: { "REMOTE_ADDR" => "127.0.0.1" }

    assert_redirected_to webinars_path
  end

  test "activée : le navigateur de l'hôte relayé par la passerelle Docker passe si son réseau est déclaré" do
    enable!
    docker_gateway = { "REMOTE_ADDR" => "172.29.0.1" }

    post dev_login_path, params: { email: "host@example.test" }, headers: docker_gateway
    assert_response :not_found

    with_networks("172.16.0.0/12") do
      post dev_login_path, params: { email: "host@example.test" }, headers: docker_gateway
    end
    assert_redirected_to webinars_path
  end

  test "activée : sans jeton CSRF valide, la connexion est refusée" do
    enable!
    ActionController::Base.allow_forgery_protection = true

    assert_no_difference -> { User.count } do
      post dev_login_path, params: { email: "host@example.test", authenticity_token: "forged" }
    end
    assert_response :unprocessable_entity
    assert_nil session[:user_id]
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  test "le callback OIDC refuse un sub réservé à la connexion de développement" do
    dev_account = User.create!(email: "host@example.test", oidc_sub: "#{DevLogin::SUB_PREFIX}host@example.test")

    sign_in_as(dev_account)

    assert_redirected_to sign_in_path
    assert_nil session[:user_id]
  end

  private

  def with_networks(value)
    previous = ENV["LIVE_DEV_LOGIN_ALLOWED_NETWORKS"]
    ENV["LIVE_DEV_LOGIN_ALLOWED_NETWORKS"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("LIVE_DEV_LOGIN_ALLOWED_NETWORKS") : ENV["LIVE_DEV_LOGIN_ALLOWED_NETWORKS"] = previous
  end
end
