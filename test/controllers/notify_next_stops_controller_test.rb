require "test_helper"

# Page d'arrêt du « préviens-moi » : GET sans effet, POST qui arrête pour la
# personne, lien re-cliqué ou forgé → page neutre 404.
class NotifyNextStopsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @request_record = confirmed_request("ana@example.test", notify_next: true)
    @twin = confirmed_request("ana@example.test", notify_next: true)
    @token = @request_record.generate_token_for(:notify_next_stop)
  end

  test "GET : page à bouton, sans effet, sans adresse, ni cache ni chemin dans le Referer" do
    get notify_next_stop_path(t: @token)

    assert_response :success
    assert_select "[data-role=notify-next-stop] form[action=?][method=post]", confirm_notify_next_stop_path(t: @token)
    assert_not_includes response.body, "ana@example.test"
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "strict-origin", response.headers["Referrer-Policy"]
    assert_nil @request_record.reload.notify_next_stopped_at
  end

  test "POST : arrêt de toutes les demandes de la personne ; un second clic est sans effet" do
    post confirm_notify_next_stop_path(t: @token)

    assert_response :success
    assert_select "[data-role=notify-next-stop-created]"
    assert @request_record.reload.notify_next_stopped_at
    assert @twin.reload.notify_next_stopped_at

    post confirm_notify_next_stop_path(t: @token)
    assert_response :not_found
    assert_select "[data-role=notify-next-stop-invalid]"
  end

  test "jeton absent, forgé, ou demande non confirmée : page neutre 404, rien ne change" do
    pending = RegistrationRequest.create!(name: "Bob", email: "bob@example.test", notify_next: true)

    [ nil, "forgé", pending.generate_token_for(:notify_next_stop) ].each do |token|
      post confirm_notify_next_stop_path(t: token)
      assert_response :not_found
    end
    assert_nil @request_record.reload.notify_next_stopped_at
    assert_nil pending.reload.notify_next_stopped_at
  end
end
