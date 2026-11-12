require "test_helper"

# Écran du programme /webinars/:slug/program : toute l'animation (propriétaire,
# co-animateur invité, animateur du projet), 404 pour les autres (défense
# énumération). Seul le programme s'y modifie, et plus rien une fois le direct
# commencé.
class WebinarProgramsControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  STARTS_AT = Time.zone.local(2026, 11, 12, 18, 0)

  setup do
    travel_to Time.zone.local(2026, 11, 10, 10, 0)
    @owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    @admin = User.create!(email: "admin@example.net", oidc_sub: "sub-admin", admin: true)
    @guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean")
    @other = User.create!(email: "autre@example.net", oidc_sub: "sub-autre")
    @webinar = Webinar.create!(title: "Café IA #10", starts_at: STARTS_AT,
                               host_sub: @owner.oidc_sub, visibility: "published")
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  def program_params(topic)
    { webinar: { topic: topic, topic_summary: "", announced_speakers: [ "Karim", "Anne", "" ], lead_host_name: "Jean" } }
  end

  test "anonyme renvoyé vers la connexion" do
    get webinar_program_path(@webinar)
    assert_redirected_to sign_in_path
  end

  test "propriétaire, co-animateur et animateur du projet saisissent le programme" do
    { @owner => "Sujet du propriétaire", @guest => "Sujet du co-animateur", @admin => "Sujet de l'équipe" }.each do |user, topic|
      sign_in_as(user)
      get webinar_program_path(@webinar)
      assert_response :success, user.email
      assert_select "form[data-role='webinar-program'][action=?] input[name='webinar[topic]']", webinar_program_path(@webinar)

      patch webinar_program_path(@webinar), params: program_params(topic)
      assert_redirected_to webinar_path(@webinar)
      assert_equal topic, @webinar.reload.topic, user.email
    end

    assert_equal [ [ "Karim", "Anne" ], "Jean" ], [ @webinar.announced_speakers, @webinar.lead_host_name ]
  end

  test "seul le programme se modifie ici" do
    sign_in_as(@guest)
    patch webinar_program_path(@webinar), params: { webinar: { topic: "Agents IA", title: "Piraté", starts_at: "2026-11-20T18:00",
                                                               visibility: "draft", host_sub: @guest.oidc_sub } }

    @webinar.reload
    assert_equal "Agents IA", @webinar.topic
    assert_equal [ "Café IA #10", STARTS_AT, "published", @owner.oidc_sub ],
                 [ @webinar.title, @webinar.starts_at, @webinar.visibility, @webinar.host_sub ]
  end

  test "saisie invalide : 422 avec le message, rien n'est écrit" do
    sign_in_as(@guest)
    patch webinar_program_path(@webinar), params: { webinar: { topic: "", topic_summary: "Sans sujet." } }

    assert_response :unprocessable_entity
    assert_select "[role='alert']", text: /Sujet doit être renseigné/
    assert_nil @webinar.reload.topic_summary
  end

  test "utilisateur sans rôle : 404" do
    sign_in_as(@other)
    get webinar_program_path(@webinar)
    assert_response :not_found
    patch webinar_program_path(@webinar), params: program_params("Piraté")
    assert_response :not_found
    assert_nil @webinar.reload.topic
  end

  test "co-animateur à l'adresse non vérifiée : 404" do
    sign_in_as(@guest, email_verified: false)
    get webinar_program_path(@webinar)
    assert_response :not_found
  end

  test "direct commencé : écran et modification refusés" do
    @webinar.update!(state: "live", started_at: Time.current)
    sign_in_as(@guest)

    get webinar_program_path(@webinar)
    assert_redirected_to webinar_path(@webinar)
    patch webinar_program_path(@webinar), params: program_params("Trop tard")
    assert_redirected_to webinar_path(@webinar)
    assert_nil @webinar.reload.topic
  end
end
