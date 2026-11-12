require "test_helper"

# Lien animateur — consommation au retour du fournisseur OIDC. Parcours OIDC complet en mode test d'OmniAuth : POST
# /auth/pocket_id (le jeton part avec le clic de /a) → callback mocké.
class SessionsHostInvitationTest < ActionDispatch::IntegrationTest
  CALLBACK_URL = "http://www.example.com/auth/pocket_id/callback".freeze

  setup do
    @owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    @guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean")
    @webinar = Webinar.create!(title: "Café IA 8", starts_at: 2.days.from_now, host_sub: @owner.oidc_sub)
    @invitation = @webinar.host_invitations.create!(created_by_sub: "sub-createur")
    OmniAuth.config.test_mode = true
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "connexion depuis le lien : co-animateur créé, usage consommé, page du webinaire avec scène et régie" do
    sign_in_from_invitation(@guest)

    assert_redirected_to webinar_path(@webinar)
    host = @webinar.webinar_hosts.sole
    assert_equal [ "jean@partenaire.example.org", "sub-createur", "sub-jean" ], [ host.email, host.invited_by_sub, host.claimed_sub ]
    assert_equal 1, @invitation.reload.uses_count
    assert cookies[HostInvitationCookie::NAME].blank?, "le cookie du jeton est effacé"

    follow_redirect!
    assert_response :success
    assert_select "[data-role='role-badge']", text: /Co-animateur invité/
    assert_select "a[data-role='stage-open'][href=?]", stage_webinar_path(slug: @webinar.slug)
    assert_select "a[data-role='regie-open'][href=?]", webinar_regie_path(@webinar)
  end

  test "le jeton attend le retour dans un cookie chiffré, jamais dans la session" do
    mock_pocket_id(@guest)
    post "/auth/pocket_id", params: { HostInvitationCookie::PARAM => @invitation.token }

    assert_redirected_to CALLBACK_URL
    stored = cookies[HostInvitationCookie::NAME]
    assert stored.present?
    assert_not_includes CGI.unescape(stored), @invitation.token
    assert_not_includes session.to_hash.values.map(&:to_s), @invitation.token
  end

  test "email non vérifié : rien n'est consommé, retour sur le lien avec la marche à suivre" do
    sign_in_from_invitation(@guest, email_verified: false)

    assert_redirected_to host_invitation_path(t: @invitation.token)
    assert_equal "Vérifie ton adresse dans ton compte Studio Exemple puis reconnecte-toi.", flash[:alert]
    assert_empty @webinar.webinar_hosts
    assert_equal 0, @invitation.reload.uses_count

    follow_redirect!
    assert_response :success
    assert_select "[role='alert']", text: /Vérifie ton adresse/
  end

  test "propriétaire ou animateur du projet : rien n'est créé, retour sur le webinaire" do
    admin = User.create!(email: "admin@example.net", oidc_sub: "sub-admin", admin: true)

    [ @owner, admin ].each do |user|
      sign_in_from_invitation(user)
      assert_redirected_to webinar_path(@webinar)
      assert_match(/Tu animes déjà/, flash[:notice])
    end
    assert_empty @webinar.webinar_hosts
    assert_equal 0, @invitation.reload.uses_count
  end

  test "lien révoqué entre le clic et le retour : rien n'est créé" do
    mock_pocket_id(@guest)
    post "/auth/pocket_id", params: { HostInvitationCookie::PARAM => @invitation.token }
    @invitation.revoke!
    follow_redirect!

    # Le compte n'anime rien : il arrive sur une page qui s'affiche pour lui,
    # avec l'alerte (la zone animateur lui répondrait 404).
    assert_redirected_to replays_path
    follow_redirect!
    assert_response :success
    assert_select "[role=alert]", /plus valable/
    assert_empty @webinar.webinar_hosts
  end

  test "adresse déjà liée à un autre compte : rien n'est créé, l'alerte s'affiche sur les replays" do
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub, claimed_sub: "sub-ancien")
    sign_in_from_invitation(@guest)

    assert_redirected_to replays_path
    follow_redirect!
    assert_response :success
    assert_select "[role=alert]", /déjà liée à un autre compte/
    assert_equal 0, @invitation.reload.uses_count
  end

  test "lien plus valable pour un compte qui anime déjà : retour sur ses webinaires" do
    Webinar.create!(title: "Le sien", starts_at: 1.day.from_now, host_sub: @guest.oidc_sub)
    mock_pocket_id(@guest)
    post "/auth/pocket_id", params: { HostInvitationCookie::PARAM => @invitation.token }
    @invitation.revoke!
    follow_redirect!

    assert_redirected_to webinars_path
    follow_redirect!
    assert_response :success
    assert_select "[role=alert]", /plus valable/
  end

  test "une connexion lancée sans le lien efface le jeton d'une tentative précédente" do
    mock_pocket_id(@guest)
    post "/auth/pocket_id", params: { HostInvitationCookie::PARAM => @invitation.token }
    post "/auth/pocket_id"
    follow_redirect!

    # Sans invitation acceptée, le compte n'anime rien : il arrive sur les replays.
    assert_redirected_to replays_path
    assert_empty @webinar.webinar_hosts
    assert_equal 0, @invitation.reload.uses_count
  end

  test "un jeton resté plus de 30 minutes ne vaut plus rien" do
    mock_pocket_id(@guest)
    post "/auth/pocket_id", params: { HostInvitationCookie::PARAM => @invitation.token }

    travel(HostInvitationCookie::TTL + 1.minute) { follow_redirect! }

    assert_redirected_to replays_path
    assert_empty @webinar.webinar_hosts
  end

  # Request phase refusée (jeton CSRF absent) : OmniAuth passe la main à
  # SessionsController#oidc_failure, qui journalise les paramètres du POST.
  test "le jeton posté n'apparaît jamais en clair dans le journal, même quand la connexion échoue" do
    io = StringIO.new
    previous_logger = Rails.logger
    previous_controller_logger = ActionController::Base.logger
    previous_forgery = ActionController::Base.allow_forgery_protection
    Rails.logger = ActionController::Base.logger = ActiveSupport::Logger.new(io)
    ActionController::Base.allow_forgery_protection = true
    mock_pocket_id(@guest)

    post "/auth/pocket_id", params: { HostInvitationCookie::PARAM => @invitation.token }

    assert_match(/Processing by SessionsController#oidc_failure/, io.string)
    assert_match(/Parameters: .*"host_invitation" *=> *"\[FILTERED\]"/, io.string)
    assert_no_match(/#{Regexp.escape(@invitation.token)}/, io.string)
  ensure
    Rails.logger = previous_logger
    ActionController::Base.logger = previous_controller_logger
    ActionController::Base.allow_forgery_protection = previous_forgery
  end

  private

  def mock_pocket_id(user, email_verified: true)
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id",
      uid: user.oidc_sub,
      info: { email: user.email, email_verified: email_verified },
      extra: { raw_info: { email_verified: email_verified } }
    )
  end

  def sign_in_from_invitation(user, email_verified: true)
    mock_pocket_id(user, email_verified: email_verified)
    post "/auth/pocket_id", params: { HostInvitationCookie::PARAM => @invitation.token }
    assert_redirected_to CALLBACK_URL
    follow_redirect!
  end
end
