require "test_helper"

# Lien animateur — page publique /a?t= : sans effet,
# un seul geste (la connexion Pocket ID), page propre en 410 quand le lien
# ne sert plus.
class HostInvitationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @webinar = Webinar.create!(title: "Café IA 8", starts_at: 2.days.from_now, host_sub: "sub-owner")
    @invitation = @webinar.host_invitations.create!(created_by_sub: "sub-owner")
  end

  test "lien valable : titre du café et connexion Pocket ID qui emporte le jeton" do
    get host_invitation_path(t: @invitation.token)

    assert_response :success
    assert_select "h1", text: /Café IA 8/
    assert_select "form[action='/auth/pocket_id'][method='post']" do
      assert_select "input[type='hidden'][name='host_invitation'][value=?]", @invitation.token
      assert_select "button", text: "Se connecter avec mon compte Studio Exemple"
    end
    assert_select "[data-role='host-invitation-email-code']", text: /code reçu par mail/
    assert_select "[data-role='host-invitation-signup']", count: 0
  end

  test "lien d'inscription Pocket ID renseigné : « Je n'ai pas de compte » ouvre un autre onglet" do
    @invitation.update!(signup_url: "https://id.example.test/st/abc123")

    get host_invitation_path(t: @invitation.token)

    assert_select "[data-role='host-invitation-signup'] a[href='https://id.example.test/st/abc123'][target='_blank'][rel~='noopener']",
                  text: /Je n’ai pas de compte : le créer/
    assert_select "[data-role='host-invitation-signup'] a .visually-hidden", text: "(nouvel onglet)"
  end

  test "la page ne garde le jeton ni en cache ni dans le Referer, et n'a aucun effet" do
    get host_invitation_path(t: @invitation.token)

    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "strict-origin", response.headers["Referrer-Policy"]
    assert_equal 0, @invitation.reload.uses_count
    assert_nil cookies[HostInvitationCookie::NAME]
    assert_empty @webinar.webinar_hosts
  end

  test "jeton inconnu ou absent : 404, page propre" do
    get host_invitation_path(t: "inconnu")
    assert_response :not_found
    assert_select "[data-role='host-invitation-unavailable']"

    get host_invitation_path
    assert_response :not_found
  end

  test "webinaire terminé : 410, page propre sans bouton de connexion" do
    @webinar.update!(state: "ended", ended_at: Time.current)

    get host_invitation_path(t: @invitation.token)

    assert_response :gone
    assert_select "[data-role='host-invitation-unavailable']", text: /n’est pas valable/
    assert_select "form[action='/auth/pocket_id']", count: 0
  end

  test "lien expiré, épuisé ou révoqué : 410, page propre sans bouton de connexion" do
    expired = @webinar.host_invitations.create!(created_by_sub: "sub-owner")
    expired.update_columns(expires_at: 1.minute.ago)
    exhausted = @webinar.host_invitations.create!(created_by_sub: "sub-owner", max_uses: 1)
    exhausted.update_columns(uses_count: 1)
    revoked = @webinar.host_invitations.create!(created_by_sub: "sub-owner").tap(&:revoke!)

    [ expired, exhausted, revoked ].each do |invitation|
      get host_invitation_path(t: invitation.token)

      assert_response :gone
      assert_select "[data-role='host-invitation-unavailable']", text: /n’est pas valable/
      assert_select "form[action='/auth/pocket_id']", count: 0
    end
  end

  test "aperçu de lien en JSON : 406, jamais d'erreur serveur" do
    get host_invitation_path(t: @invitation.token), headers: { "Accept" => "application/json" }

    assert_response :not_acceptable
  end
end
