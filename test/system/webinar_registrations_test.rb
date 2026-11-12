require "application_system_test_case"
require "csv"

class WebinarRegistrationsTest < ApplicationSystemTestCase
  setup do
    @host = User.create!(email: "host@example.com", oidc_sub: "registrations-host", admin: true)
    @webinar = Webinar.create!(title: "Participants", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    @registration = Registration.create!(webinar: @webinar, name: "Alice", email: "alice@example.com", confirmed_at: Time.current)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: @host.oidc_sub, info: { email: @host.email }
    )
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "host opens registrations from webinar and downloads CSV" do
    visit "/auth/pocket_id/callback"
    visit webinar_path(@webinar)
    assert_selector "[data-role='registrations-count'] strong", text: "1"

    click_on "Inscrits", exact: true
    assert_current_path webinar_registrations_path(@webinar)
    assert_selector "tbody tr", count: 1
    assert_text "alice@example.com"

    click_on "Exporter en CSV"
    assert_current_path webinar_registrations_path(@webinar, format: :csv)
    assert_match "attachment", page.response_headers["Content-Disposition"]
    rows = CSV.parse(page.body.delete_prefix("\uFEFF"), headers: true)
    assert_equal [ "Alice" ], rows.map { |row| row["name"] }
    assert_not_includes page.body, @registration.token
  end
end
