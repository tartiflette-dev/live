require "test_helper"

# Liens animateur, côté gestion : création et
# révocation réservées au propriétaire et aux animateurs du projet ; la
# section de la page du webinaire suit la même règle.
class WebinarHostInvitationsControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  setup do
    @owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    @admin = User.create!(email: "admin@example.net", oidc_sub: "sub-admin", admin: true)
    @guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean")
    @other = User.create!(email: "autre@example.net", oidc_sub: "sub-autre")
    @webinar = Webinar.create!(title: "Café IA 8", starts_at: 2.days.from_now, host_sub: @owner.oidc_sub)
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
  end

  test "anonyme : renvoyé à la connexion, rien n'est créé" do
    assert_no_difference -> { HostInvitation.count } do
      post webinar_host_invitations_path(@webinar), params: { host_invitation: { max_uses: 3 } }
    end
    assert_redirected_to sign_in_path
  end

  test "le propriétaire crée un lien avec les valeurs par défaut" do
    sign_in_as(@owner)

    freeze_time do
      post webinar_host_invitations_path(@webinar), params: { host_invitation: { max_uses: "3", expires_at: "" } }
    end

    assert_redirected_to webinar_path(@webinar)
    assert_equal "Lien animateur créé.", flash[:notice]
    invitation = @webinar.host_invitations.sole
    assert_equal [ 3, 0, "sub-owner", nil ], [ invitation.max_uses, invitation.uses_count, invitation.created_by_sub, invitation.signup_url ]
    assert_equal HostInvitation.default_expiry_for(@webinar, now: invitation.created_at), invitation.expires_at
  end

  test "le propriétaire choisit usages, expiration et lien d'inscription Pocket ID" do
    sign_in_as(@owner)

    post webinar_host_invitations_path(@webinar), params: { host_invitation: {
      max_uses: "5", expires_at: 3.days.from_now.strftime("%Y-%m-%dT%H:%M"), signup_url: "https://id.example.test/st/abc123"
    } }

    invitation = @webinar.host_invitations.sole
    assert_equal 5, invitation.max_uses
    assert_equal 3.days.from_now.strftime("%Y-%m-%dT%H:%M"), invitation.expires_at.strftime("%Y-%m-%dT%H:%M")
    assert_equal "https://id.example.test/st/abc123", invitation.signup_url
  end

  test "un lien d'inscription hors de Pocket ID est refusé" do
    sign_in_as(@owner)

    assert_no_difference -> { HostInvitation.count } do
      post webinar_host_invitations_path(@webinar),
           params: { host_invitation: { max_uses: "3", signup_url: "https://evil.example/st/abc" } }
    end
    assert_redirected_to webinar_path(@webinar)
    assert_match(/doit être un lien de id\.example\.test/, flash[:alert])
  end

  test "un animateur du projet crée un lien sur le webinaire d'autrui" do
    sign_in_as(@admin)

    post webinar_host_invitations_path(@webinar), params: { host_invitation: { max_uses: "2" } }

    assert_equal "sub-admin", @webinar.host_invitations.sole.created_by_sub
  end

  test "un co-animateur invité et un autre compte reçoivent 404" do
    [ @guest, @other ].each do |user|
      sign_in_as(user)
      assert_no_difference -> { HostInvitation.count } do
        post webinar_host_invitations_path(@webinar), params: { host_invitation: { max_uses: "3" } }
      end
      assert_response :not_found
    end
    assert_equal :guest_host, @webinar.role_for(@guest.reload), "l'invité est bien co-animateur, refusé quand même"
  end

  test "le propriétaire révoque un lien" do
    invitation = @webinar.host_invitations.create!(created_by_sub: @owner.oidc_sub)
    sign_in_as(@owner)

    post revoke_webinar_host_invitation_path(@webinar, invitation)

    assert_redirected_to webinar_path(@webinar)
    assert invitation.reload.revoked_at?
  end

  test "un co-animateur invité ne révoque pas, ni le lien d'un autre webinaire" do
    invitation = @webinar.host_invitations.create!(created_by_sub: @owner.oidc_sub)
    elsewhere = Webinar.create!(title: "Autre", starts_at: 1.day.from_now, host_sub: @owner.oidc_sub)
    foreign = elsewhere.host_invitations.create!(created_by_sub: @owner.oidc_sub)

    sign_in_as(@guest)
    post revoke_webinar_host_invitation_path(@webinar, invitation)
    assert_response :not_found

    sign_in_as(@owner)
    post revoke_webinar_host_invitation_path(@webinar, foreign)
    assert_response :not_found
    assert_not invitation.reload.revoked_at?
    assert_not foreign.reload.revoked_at?
  end

  test "page du webinaire : liens masqués, usages restants, lien d'inscription jamais affiché" do
    active = @webinar.host_invitations.create!(created_by_sub: @owner.oidc_sub, max_uses: 3,
                                               signup_url: "https://id.example.test/st/secret-signup")
    active.update_columns(uses_count: 1)
    revoked = @webinar.host_invitations.create!(created_by_sub: @owner.oidc_sub).tap(&:revoke!)
    sign_in_as(@owner)

    get webinar_path(@webinar)

    assert_response :success
    assert_select "[data-role='host-invitation-form'] input[name='host_invitation[max_uses]'][value='3']"
    assert_select "[data-role='host-invitation-form'] input[name='host_invitation[expires_at]']"
    assert_select "[data-host-invitation-id='#{active.id}']" do
      assert_select "input[data-role='host-invitation-url'][value=?]", "www.example.com/a?t=••••••••"
      assert_select "button[data-role='host-invitation-copy'][data-copy-link=?]", host_invitation_url(t: active.token)
      assert_select "[data-role='host-invitation-usage']", text: /2 usages\s+restants sur 3/
      assert_select "button", text: "Révoquer"
    end
    assert_select "[data-host-invitation-id='#{revoked.id}']" do
      assert_select "[data-role='host-invitation-usage']", text: /Lien révoqué/
      assert_select "button[data-role='host-invitation-copy']", count: 0
      assert_select "button", text: "Révoquer", count: 0
    end
    assert_no_match(/secret-signup/, response.body)
    assert_no_match(/#{revoked.token}/, response.body)
  end

  test "page du webinaire : un co-animateur invité ne voit pas les liens animateur" do
    @webinar.host_invitations.create!(created_by_sub: @owner.oidc_sub)
    sign_in_as(@guest)

    get webinar_path(@webinar)

    assert_response :success
    assert_select "[data-role='host-invitations']", count: 0
    assert_select "[data-role='host-invitation-form']", count: 0
  end
end
