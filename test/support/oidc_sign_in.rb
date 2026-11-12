# Helper partagé par les tests contrôleur / système — flow OIDC
# test_mode pour poser `session[:user_id]` exactement comme en prod.
#
# Enrichi : porte `email_verified` et `groups` comme
# claims OIDC. Un test qui veut exercer le chemin « invité » doit
# transmettre `email_verified: true` (défense broken-authentication —
# sans ce claim, Webinar#role_for refuse :guest_host). Un test
# « animateur du projet » transmet `groups: ["live-animateurs"]`.
module OidcSignIn
  def sign_in_as(user, email_verified: true, groups: nil)
    OmniAuth.config.test_mode = true
    info = { email: user.email }
    info[:email_verified] = email_verified unless email_verified.nil?
    extra = {}
    raw_info = {}
    raw_info[:groups] = groups if groups
    raw_info[:email_verified] = email_verified unless email_verified.nil?
    extra[:raw_info] = raw_info unless raw_info.empty?

    hash_attrs = { provider: "pocket_id", uid: user.oidc_sub, info: info }
    hash_attrs[:extra] = extra unless extra.empty?

    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(**hash_attrs)
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:pocket_id]
    perform_oidc_callback
    Rails.application.env_config.delete("omniauth.auth")
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  private

  # ActionDispatch::IntegrationTest expose `get`, Capybara expose `visit`.
  # On choisit mécaniquement selon ce qui répond.
  def perform_oidc_callback
    if respond_to?(:visit, true) && !respond_to?(:get, true)
      visit "/auth/pocket_id/callback"
    else
      get "/auth/pocket_id/callback"
    end
  end
end
