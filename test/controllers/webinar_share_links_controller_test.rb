require "test_helper"

class WebinarShareLinksControllerTest < ActionDispatch::IntegrationTest
  # Lien d'invitation intervenant PARTAGÉ, côté animateur.

  setup do
    @host  = User.create!(email: "share-host@example.com", oidc_sub: "share-sub-host")
    @other = User.create!(email: "share-other@example.com", oidc_sub: "share-sub-other")
    @webinar = Webinar.create!(title: "Partagé", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "host can generate the shared invitation link" do
    sign_in_as(@host)
    assert_nil @webinar.share_token

    post webinar_share_link_path(@webinar)

    assert_redirected_to webinar_path(@webinar)
    assert @webinar.reload.share_token.present?
  end

  test "regenerating replaces the previous token (invalidates it)" do
    sign_in_as(@host)
    @webinar.generate_share_token!
    before = @webinar.share_token

    post webinar_share_link_path(@webinar)
    assert_redirected_to webinar_path(@webinar)

    @webinar.reload
    assert_not_equal before, @webinar.share_token
    assert_nil Webinar.find_by_active_share_token(before)
  end

  test "destroying disables the share link but keeps existing speakers" do
    sign_in_as(@host)
    @webinar.generate_share_token!
    speaker = @webinar.speakers.create!(name: "Déjà entrée")

    delete webinar_share_link_path(@webinar)
    assert_redirected_to webinar_path(@webinar)

    assert_nil @webinar.reload.share_token
    assert_nil speaker.reload.revoked_at
  end

  test "anonymous cannot generate or destroy" do
    post webinar_share_link_path(@webinar)
    assert_redirected_to sign_in_path
    assert_nil @webinar.reload.share_token

    @webinar.generate_share_token!
    delete webinar_share_link_path(@webinar)
    assert_redirected_to sign_in_path
    assert @webinar.reload.share_token.present?
  end

  test "another host cannot generate or destroy" do
    sign_in_as(@other)
    post webinar_share_link_path(@webinar)
    assert_response :not_found
    assert_nil @webinar.reload.share_token

    @webinar.generate_share_token!
    delete webinar_share_link_path(@webinar)
    assert_response :not_found
    assert @webinar.reload.share_token.present?
  end

  private

  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: user.oidc_sub, info: { email: user.email }
    )
    get "/auth/pocket_id/callback"
  ensure
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end
end
