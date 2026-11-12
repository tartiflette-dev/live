# frozen_string_literal: true

require "test_helper"

# Endpoint d'export .txt du transcript multi-locuteur. Host-only,
# scope host_sub — mêmes garanties que RecordingsController#index. Un
# intervenant signé (token speaker `t`) N'A PAS droit à cet export, voir
# `authenticate_participant!` qui ne whiteliste pas `transcript` dans la
# bypass liste.
class RecordingsTranscriptTest < ActionDispatch::IntegrationTest
  setup do
    @host  = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @other = User.create!(email: "eve@example.com", oidc_sub: "sub-eve")
    @webinar = Webinar.create!(title: "Café IA", starts_at: 1.hour.from_now, host_sub: @host.oidc_sub)
    @base = Time.zone.local(2026, 10, 7, 9, 0, 0)
    @webinar.transcript_segments.create!(participant_identity: "host-sub-marc", speaker_name: "Marc",
      text: "Première phrase.", started_at: @base, ended_at: @base + 2.seconds, segment_id: "a")
    @webinar.transcript_segments.create!(participant_identity: "speaker-1", speaker_name: "Pauline",
      text: "Deuxième phrase.", started_at: @base + 10.seconds, ended_at: @base + 12.seconds, segment_id: "b")
  end

  test "animateur propriétaire → .txt UTF-8, lignes `[HH:MM:SS] Nom : texte`" do
    sign_in_as(@host)
    get transcript_webinar_recordings_path(@webinar, format: :txt)
    assert_response :success
    assert_match %r{text/plain}, response.media_type
    assert_match(/\btranscript-#{Regexp.escape(@webinar.slug)}\.txt\b/, response.headers["Content-Disposition"])
    assert_equal "[09:00:00] Marc : Première phrase.\n[09:00:10] Pauline : Deuxième phrase.\n", response.body
  end

  test "animateur d'un autre webinaire → 404 (scope host_sub)" do
    sign_in_as(@other)
    get transcript_webinar_recordings_path(@webinar, format: :txt)
    assert_response :not_found
  end

  test "anonyme → redirect sign_in" do
    get transcript_webinar_recordings_path(@webinar, format: :txt)
    assert_redirected_to sign_in_path
  end

  test "lien visible sur /recordings quand au moins un segment existe" do
    sign_in_as(@host)
    get webinar_recordings_path(@webinar)
    assert_response :success
    assert_match %r{Transcript \(\.txt\)}, response.body
    assert_match %r{data-role="transcript-download"}, response.body
  end

  test "pas de lien quand aucun segment" do
    autre = Webinar.create!(title: "Vide", starts_at: 1.hour.from_now, host_sub: @host.oidc_sub)
    sign_in_as(@host)
    get webinar_recordings_path(autre)
    assert_response :success
    assert_no_match %r{Transcript \(\.txt\)}, response.body
  end

  private

  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: user.oidc_sub, info: { email: user.email },
    )
    post "/auth/pocket_id"
    follow_redirect!
  end
end
