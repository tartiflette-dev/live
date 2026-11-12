require "test_helper"

# Réponse de présence depuis la page du webinaire, connecté.
class WebinarPresencesControllerTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper
  include OidcSignIn

  setup do
    @owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    @guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean")
    @webinar = Webinar.create!(title: "Café IA 12", starts_at: 10.days.from_now, host_sub: @owner.oidc_sub, visibility: "published")
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "sans session : connexion" do
    post webinar_presence_path(@webinar), params: { answer: "present" }
    assert_redirected_to sign_in_path
  end

  test "le propriétaire répond pour lui-même, sans mail" do
    sign_in_as(@owner)

    assert_no_enqueued_emails do
      post webinar_presence_path(@webinar), params: { answer: "absent" }
    end
    assert_redirected_to webinar_path(@webinar)
    assert_equal "Noté : tu ne seras pas là.", flash[:notice]
    assert_equal "absent", @webinar.host_attendances.find_by(webinar_host: nil).current_answer
  end

  test "le co-animateur répond pour lui ; son « non » prévient le propriétaire" do
    sign_in_as(@guest)

    assert_enqueued_emails(1) do
      post webinar_presence_path(@webinar), params: { answer: "absent" }
    end
    assert_equal "absent", @webinar.webinar_hosts.sole.host_attendance.current_answer
  end

  test "animateur du projet sans rôle d'animateur sur ce café, ou inconnu : 404" do
    admin = User.create!(email: "admin@example.net", oidc_sub: "sub-admin", admin: true)
    sign_in_as(admin)
    post webinar_presence_path(@webinar), params: { answer: "present" }
    assert_response :not_found

    sign_in_as(User.create!(email: "autre@example.net", oidc_sub: "sub-autre"))
    post webinar_presence_path(@webinar), params: { answer: "present" }
    assert_response :not_found
    assert_equal 0, HostAttendance.count
  end

  test "réponse illisible : 422 ; café non publié : refus expliqué" do
    sign_in_as(@owner)
    post webinar_presence_path(@webinar), params: { answer: "peut-être" }
    assert_response :unprocessable_entity

    @webinar.update_columns(visibility: "draft")
    post webinar_presence_path(@webinar), params: { answer: "present" }
    assert_redirected_to webinar_path(@webinar)
    assert_match(/plus de présence à donner/, flash[:alert])
    assert_equal 0, HostAttendance.count
  end
end
