# frozen_string_literal: true

require "test_helper"

# Consentement spectateur.
# Un spectateur à qui l'on donne la parole doit voir « Enregistrement en
# cours » dès que son flux est capté. Endpoint lecture seule, autorisé
# par le cookie `registration_id` (CurrentRegistration).
class PublicWebinarRecordingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @webinar = Webinar.create!(title: "Café IA", starts_at: 1.hour.ago, host_sub: "sub-marc",
                                visibility: "published")
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    @registration = @webinar.registrations.create!(name: "Inès", email: "ines@example.com")
  end

  # Rack::Test ne sait pas chiffrer les cookies ; on passe par le flow
  # réel : GET /r/<token> pose le cookie `registration_id` chiffré ET
  # confirme l'inscription (same pattern que hand_raises_controller_test).
  def confirm_registration_cookie(reg = @registration)
    post confirm_registration_path(reg.token)
  end

  test "anonyme → 403 (consentement n'a de sens que pour un publieur potentiel)" do
    get public_webinar_recording_status_path(slug: @webinar.slug)
    assert_response :forbidden
  end

  test "inscription confirmée mais d'un autre webinaire → 403" do
    other = Webinar.create!(title: "Autre", starts_at: 1.hour.ago, host_sub: "sub-eve",
                             visibility: "published")
    other_reg = other.registrations.create!(name: "Eve", email: "eve@example.com")
    confirm_registration_cookie(other_reg)
    # Cookie posé sur other_reg.id, mais la lecture scope sur @webinar.
    get public_webinar_recording_status_path(slug: @webinar.slug)
    assert_response :forbidden
  end

  test "aucun enregistrement actif → recording nil, participant_recording false" do
    confirm_registration_cookie
    get public_webinar_recording_status_path(slug: @webinar.slug)
    assert_response :success
    payload = JSON.parse(response.body)
    assert_nil payload["recording"]
    assert_equal false, payload["participant_recording"]
  end

  test "composite actif → participant_recording true (consentement affiché)" do
    @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_comp",
                                 started_at: 1.minute.ago)
    confirm_registration_cookie
    get public_webinar_recording_status_path(slug: @webinar.slug)
    assert_response :success
    payload = JSON.parse(response.body)
    assert payload["participant_recording"]
    assert_equal "recording", payload.dig("recording", "status")
  end

  test "piste viewer-<id> active → participant_recording true même sans composite" do
    @webinar.recordings.create!(kind: "track", status: "recording", egress_id: "EG_v",
                                 track_sid: "TR_v",
                                 participant_identity: "viewer-#{@registration.id}",
                                 track_source: "microphone",
                                 output_prefix: "#{@webinar.slug}/v",
                                 started_at: 1.minute.ago)
    confirm_registration_cookie
    get public_webinar_recording_status_path(slug: @webinar.slug)
    assert_response :success
    payload = JSON.parse(response.body)
    assert payload["participant_recording"]
    assert_equal "recording", payload.dig("recording", "status")
  end

  test "payload NE contient JAMAIS stop_url ni start_url (lecture seule)" do
    @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_comp",
                                 started_at: 1.minute.ago)
    confirm_registration_cookie
    get public_webinar_recording_status_path(slug: @webinar.slug)
    assert_response :success
    body = response.body
    refute_match(/stop_url/, body)
    refute_match(/start_url/, body)
  end

  test "slug inconnu → 404" do
    confirm_registration_cookie
    get public_webinar_recording_status_path(slug: "inconnu")
    assert_response :not_found
  end
end
