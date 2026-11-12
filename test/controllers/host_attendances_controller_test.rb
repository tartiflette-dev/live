require "test_helper"

# /presence?t= : page à boutons sans effet, réponse au POST, jeton invalide
# (inconnu, co-animateur retiré) 404, café dépublié / commencé / passé 410.
class HostAttendancesControllerTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  setup do
    @owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    @webinar = Webinar.create!(title: "Café IA 12", starts_at: 10.days.from_now, host_sub: @owner.oidc_sub, visibility: "published")
    @host = @webinar.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: @owner.oidc_sub)
    @attendance = HostAttendance.for!(@webinar, @host)
  end

  test "la page n'enregistre rien et ne reste dans aucun cache" do
    get host_attendance_path(t: @attendance.token, reponse: "non")

    assert_response :success
    assert_select "h1", "Seras-tu là ?"
    assert_select "[data-role='host-attendance'] form[action=?][method=post]", answer_host_attendance_path, count: 2
    assert_select "button.btn:not(.btn--secondary)", "Je ne serai pas là"
    assert_nil @attendance.reload.answer
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "strict-origin", response.headers["Referrer-Policy"]
  end

  test "« oui » enregistré au POST pour la date actuelle, sans mail" do
    assert_no_enqueued_emails do
      post answer_host_attendance_path, params: { t: @attendance.token, reponse: "oui" }
    end

    assert_response :success
    assert_select "h1", "C'est noté : tu seras là"
    assert @attendance.reload.attending?
  end

  # Protection CSRF ACTIVE, comme en prod (coupée par défaut en test) : la
  # session Rails porte le jeton CSRF du bouton, et rien d'autre — aucun
  # cookie d'identité ni d'accès (même motif que speaker_links_controller_test).
  test "CSRF actif : le bouton répond dans un vrai navigateur, sans cookie d'identité ni d'accès" do
    forgery = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    get host_attendance_path(t: @attendance.token, reponse: "oui")
    assert_response :success
    assert session["_csrf_token"].present?, "la protection CSRF est bien active"
    assert_no_identity_cookie
    form = css_select("form[action='#{answer_host_attendance_path}']").first
    fields = form.css("input[type=hidden]").to_h { |input| [ input["name"], input["value"] ] }
    assert fields["authenticity_token"].present?

    post answer_host_attendance_path, params: fields.except("authenticity_token"), headers: { "Origin" => "http://www.example.com" }
    assert_response :unprocessable_entity, "sans jeton CSRF, rien n'est enregistré"
    assert_nil @attendance.reload.answer

    post answer_host_attendance_path, params: fields, headers: { "Origin" => "http://www.example.com" }
    assert_response :success
    assert @attendance.reload.attending?
    assert_no_identity_cookie
  ensure
    ActionController::Base.allow_forgery_protection = forgery
  end

  test "« non » enregistré au POST : mail immédiat au propriétaire" do
    assert_enqueued_email_with HostAttendanceMailer, :absence_notice, args: [ @attendance ] do
      post answer_host_attendance_path, params: { t: @attendance.token, reponse: "non" }
    end

    assert_select "h1", "C'est noté : tu ne seras pas là"
    assert_equal "absent", @attendance.reload.current_answer
  end

  test "réponse illisible : 422, rien d'enregistré" do
    post answer_host_attendance_path, params: { t: @attendance.token, reponse: "peut-être" }

    assert_response :unprocessable_entity
    assert_nil @attendance.reload.answer
  end

  test "jeton inconnu ou absent : 404" do
    get host_attendance_path(t: "inconnu")
    assert_response :not_found
    assert_select "[data-role='host-attendance-unavailable']"

    post answer_host_attendance_path, params: { reponse: "oui" }
    assert_response :not_found
  end

  test "co-animateur retiré : son lien ne résout plus" do
    token = @attendance.token
    @host.destroy!

    get host_attendance_path(t: token)
    assert_response :not_found
    post answer_host_attendance_path, params: { t: token, reponse: "oui" }
    assert_response :not_found
  end

  test "café dépublié, commencé ou passé : 410, rien d'enregistré" do
    @webinar.update_columns(visibility: "draft")
    get host_attendance_path(t: @attendance.token)
    assert_response :gone

    @webinar.update_columns(visibility: "published", starts_at: 1.hour.ago)
    post answer_host_attendance_path, params: { t: @attendance.token, reponse: "oui" }
    assert_response :gone

    @webinar.update_columns(starts_at: 1.day.from_now, state: "live")
    get host_attendance_path(t: @attendance.token)
    assert_response :gone
    assert_nil @attendance.reload.answer
  end

  test "aperçu de lien en Accept JSON : 406" do
    get host_attendance_path(t: @attendance.token), headers: { "Accept" => "application/json" }
    assert_response :not_acceptable
  end

  private

  def assert_no_identity_cookie
    assert_no_match(/registration_id|share_speaker_|host_invitation/, response.headers["set-cookie"].to_s)
    assert_equal [], session.to_h.keys - %w[session_id _csrf_token], "la session ne porte que le jeton CSRF"
  end
end
