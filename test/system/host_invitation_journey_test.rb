require "application_system_test_case"

# Lien animateur, parcours rack_test : le
# propriétaire crée le lien, l'invité l'ouvre, se connecte (Pocket ID mocké
# par le mode test d'OmniAuth, request phase comprise) et arrive sur le
# webinaire en co-animateur. Reconduction : rien n'est créé avant le clic.
class HostInvitationJourneyTest < ApplicationSystemTestCase
  include OidcSignIn

  setup do
    @owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    @webinar = Webinar.create!(title: "Café IA 8", starts_at: 2.days.from_now, host_sub: @owner.oidc_sub)
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "le propriétaire crée un lien ; l'invité l'ouvre, se connecte et arrive en co-animateur" do
    sign_in_as(@owner)
    visit webinar_path(@webinar)
    # Le lien animateur est replié sous « Avancé ».
    find("summary", text: "Avancé : lien animateur").click
    within("[data-role='host-invitation-form']") do
      fill_in "Nombre d’usages", with: "2"
      click_button "Créer un lien animateur"
    end

    assert_text "Lien animateur créé."
    invitation = @webinar.host_invitations.sole
    assert_equal 2, invitation.max_uses
    find("summary", text: "Avancé : lien animateur").click
    copy_button = find("button[data-role='host-invitation-copy']")
    assert_equal host_invitation_url(t: invitation.token, host: "www.example.com"), copy_button["data-copy-link"]
    assert_no_text invitation.token

    Capybara.reset_sessions!
    mock_pocket_id(email: "jean@partenaire.example.org", sub: "sub-jean")
    visit URI(copy_button["data-copy-link"]).request_uri
    assert_selector "h1", text: "Co-animer « Café IA 8 »"
    click_button "Se connecter avec mon compte #{Brand.organization}"

    assert_current_path webinar_path(@webinar)
    assert_text "Tu co-animes « Café IA 8 »"
    assert_selector "[data-role='role-badge']", text: "Co-animateur invité"
    assert_link "Ouvrir la scène", href: stage_webinar_path(slug: @webinar.slug)
    assert_link "Ouvrir la régie", href: webinar_regie_path(@webinar)
    assert_equal [ "jean@partenaire.example.org" ], @webinar.webinar_hosts.pluck(:email)
    assert_equal 1, invitation.reload.uses_count
  end

  test "reconduction : cases pré-cochées, seuls les co-animateurs cochés sont repris au clic" do
    previous = Webinar.create!(title: "Café IA 7", starts_at: 7.days.ago, host_sub: @owner.oidc_sub)
    previous.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: @owner.oidc_sub, claimed_sub: "sub-jean")
    previous.webinar_hosts.create!(email: "paul@partenaire.example.org", invited_by_sub: @owner.oidc_sub)

    sign_in_as(@owner)
    visit webinar_path(@webinar)

    within("[data-role='co-animateurs-carryover']") do
      assert_checked_field "jean@partenaire.example.org"
      assert_checked_field "paul@partenaire.example.org"
      assert_empty @webinar.webinar_hosts.reload, "rien n'est créé avant le clic"
      uncheck "paul@partenaire.example.org"
      click_button "Reprendre les co-animateurs du café précédent"
    end

    assert_text "Co-animateurs repris : jean@partenaire.example.org."
    assert_equal [ [ "jean@partenaire.example.org", "sub-jean" ] ], @webinar.webinar_hosts.reload.pluck(:email, :claimed_sub)
    within("[data-role='co-animateurs-carryover']") do
      assert_checked_field "paul@partenaire.example.org"
      assert_no_field "jean@partenaire.example.org"
    end
    within("[data-role='co-animateur-list']") { assert_text "jean@partenaire.example.org" }
  end

  private

  def mock_pocket_id(email:, sub:)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: sub,
      info: { email: email, email_verified: true }, extra: { raw_info: { email_verified: true } }
    )
  end
end
