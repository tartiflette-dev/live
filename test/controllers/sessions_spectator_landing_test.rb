require "test_helper"

# Connexion d'un compte sans droit d'animation : il arrive sur les replays,
# jamais sur une page animateur qui lui répondrait 404.
class SessionsSpectatorLandingTest < ActionDispatch::IntegrationTest
  include OidcSignIn
  include ReplayHelpers

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "spectateur : liste des replays, chrome sans les pages animateur" do
    sign_in_as(User.create!(email: "s@example.test", oidc_sub: "sub-s"), groups: [ "live-spectateurs" ])

    assert_redirected_to replays_path
    follow_redirect!
    assert_select "nav a[href=?]", replays_path
    assert_select "a[href=?]", webinars_path, count: 0
    assert_select "a[href=?]", new_webinar_path, count: 0
  end

  test "spectateur parti d'un replay : il y revient ; parti d'une page animateur : les replays" do
    get "/webinars"
    sign_in_as(User.create!(email: "s@example.test", oidc_sub: "sub-s"), groups: [])
    assert_redirected_to replays_path

    with_recordings_root do
      slug = replay_cafe.webinar.slug
      delete sign_out_path
      get public_webinar_replay_path(slug)
      sign_in_as(User.find_by!(oidc_sub: "sub-s"), groups: [])
      assert_redirected_to public_webinar_replay_path(slug)
    end
  end

  test "animateur : inchangé, sa page de départ ou ses webinaires, et le lien des replays" do
    sign_in_as(User.create!(email: "a@example.test", oidc_sub: "sub-a"), groups: [ "live-animateurs" ])

    assert_redirected_to webinars_path
    follow_redirect!
    assert_select "nav a[href=?]", webinars_path
    assert_select "nav a[href=?]", replays_path
  end
end
