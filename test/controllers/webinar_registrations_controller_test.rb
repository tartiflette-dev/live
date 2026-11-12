# frozen_string_literal: true

require "test_helper"

class WebinarRegistrationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @host  = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @other = User.create!(email: "eve@example.com", oidc_sub: "sub-eve")

    @webinar = Webinar.create!(
      title: "Kick-off", starts_at: 1.day.from_now, host_sub: @host.oidc_sub
    )

    # 3 inscrits : 2 confirmés (dont 1 payé), 1 en attente.
    @confirmed = Registration.create!(
      webinar: @webinar, name: "Alice", email: "alice@example.com",
      confirmed_at: 2.hours.ago
    )
    @paid = Registration.create!(
      webinar: @webinar, name: "Bob", email: "bob@example.com",
      confirmed_at: 1.hour.ago, paid_confirmed_at: 30.minutes.ago
    )
    @pending = Registration.create!(
      webinar: @webinar, name: "Carol", email: "carol@example.com"
    )
  end

  # ---- Auth ----

  test "index redirects anonymous to sign_in" do
    get webinar_registrations_path(@webinar)
    assert_redirected_to sign_in_path
  end

  test "csv redirects anonymous to sign_in" do
    get webinar_registrations_path(@webinar, format: :csv)
    assert_redirected_to sign_in_path
  end


  test "registrations_index_scoped_to_host — host sees all registrations" do
    sign_in_as(@host)
    get webinar_registrations_path(@webinar)
    assert_response :success

    assert_select "[data-role='registrations-csv']"
    assert_select "tbody tr", 3
    assert_match(/Alice/,      response.body)
    assert_match(/Bob/,        response.body)
    assert_match(/Carol/,      response.body)
    # 2 confirmés (compteur)
    assert_select "strong", text: "3"
    assert_select "strong", text: "2"
  end

  test "registrations_index_scoped_to_host — non-host gets 404 (not 403)" do
    sign_in_as(@other)
    get webinar_registrations_path(@webinar)
    assert_response :not_found
  end

  test "registrations_index_scoped_to_host — non-host gets 404 on CSV" do
    sign_in_as(@other)
    get webinar_registrations_path(@webinar, format: :csv)
    assert_response :not_found
  end

  test "registrations_index — token N'EST JAMAIS rendu (invariant fuite)" do
    sign_in_as(@host)
    get webinar_registrations_path(@webinar)
    assert_response :success
    [ @confirmed, @paid, @pending ].each do |r|
      assert_not_includes response.body, r.token, "token de #{r.name} fuité dans HTML"
    end
  end


  test "registrations_csv_export — content-type text/csv utf-8 + BOM + headers" do
    sign_in_as(@host)
    get webinar_registrations_path(@webinar, format: :csv)
    assert_response :success

    assert_equal "text/csv", response.media_type
    assert_match(/charset=utf-8/i, response.headers["Content-Type"])
    assert_match(/attachment/,     response.headers["Content-Disposition"])
    assert_match(/#{Regexp.escape(@webinar.slug)}-inscrits\.csv/,
                 response.headers["Content-Disposition"])

    body = response.body
    assert body.start_with?("﻿"), "CSV doit commencer par le BOM UTF-8"

    # En-têtes ordonnés + N+1 lignes (header + 3 inscrits).
    lines = body.sub(/\A﻿/, "").split(/\r?\n/)
    assert_equal %w[name email confirmed_at paid_confirmed_at created_at room_joined_at], CSV.parse_line(lines.first)
    assert_equal 4, lines.size
  end

  test "registrations_csv_export — dates ISO 8601, ordre desc, aucun token" do
    sign_in_as(@host)
    get webinar_registrations_path(@webinar, format: :csv)

    body = response.body.sub(/\A﻿/, "")
    rows = CSV.parse(body, headers: true)

    # Ordre desc created_at : Carol (le plus récent), Bob, Alice.
    assert_equal %w[Carol Bob Alice], rows.map { |r| r["name"] }

    alice = rows.find { |r| r["name"] == "Alice" }
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, alice["confirmed_at"])
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, alice["created_at"])
    assert_equal "", alice["paid_confirmed_at"].to_s

    bob = rows.find { |r| r["name"] == "Bob" }
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, bob["paid_confirmed_at"])

    carol = rows.find { |r| r["name"] == "Carol" }
    assert_equal "", carol["confirmed_at"].to_s

    # Invariant fuite : aucun token n'apparaît dans le corps CSV.
    [ @confirmed, @paid, @pending ].each do |r|
      assert_not_includes body, r.token, "token de #{r.name} fuité dans CSV"
    end
  end


  test "show_displays_registration_count — /webinars/:slug affiche compteur + lien" do
    sign_in_as(@host)
    get webinar_path(@webinar)
    assert_response :success

    assert_select "[data-role='registrations-count']" do
      # 2 confirmés parmi 3 inscrits.
      assert_select "strong", text: "2"
    end
    assert_select "[data-role='registrations-list']"
    assert_select "[data-role='registrations-link']"
    assert_select "a[data-role='room-presence-link'][href=?]", webinar_room_presence_path(@webinar)
  end

  test "index empty state when no registrations" do
    empty_webinar = Webinar.create!(
      title: "Vide", starts_at: 2.days.from_now, host_sub: @host.oidc_sub
    )
    sign_in_as(@host)
    get webinar_registrations_path(empty_webinar)
    assert_response :success
    assert_select ".vide"
    assert_select "tbody tr", 0
  end

  test "csv treats spreadsheet formulas as text and preserves quoted names" do
    dangerous_names = [ "=1+1", "+1+1", "-1+1", "@SUM(A1)", "\t=1+1", "\r=1+1", "\n=1+1", "  =1+1", "＝1+1", "＋1+1", "－1+1", "＠SUM(A1)" ]
    # Écrits en SQL, sans le modèle qui ramène aujourd'hui un nom sur une
    # ligne : l'export protège aussi les inscriptions plus anciennes.
    legacy_name = ->(email, name) do
      Registration.where(id: Registration.create!(webinar: @webinar, name: "x", email: email)).update_all([ "name = ?", name ])
    end
    dangerous_names.each_with_index { |name, index| legacy_name.call("formula#{index}@example.com", name) }
    quoted_name = "Alice, \"A\";\nBob"
    legacy_name.call("+formula@example.com", quoted_name)
    sign_in_as(@host)

    get webinar_registrations_path(@webinar, format: :csv)

    assert_response :success
    rows = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true)
    dangerous_names.each_with_index do |name, index|
      row = rows.find { |entry| entry["email"] == "formula#{index}@example.com" }
      assert_equal "'#{name}", row["name"]
    end
    quoted_row = rows.find { |entry| entry["name"] == quoted_name }
    assert_equal "'+formula@example.com", quoted_row["email"]
    assert_equal dangerous_names.size + 4, rows.size
  end

  # ---- Présence (bloc « Inscrits » de la régie) ----

  class EmptyRoom
    def room_metadata(room:) = ""
    def list_participants(room:) = [ { identity: "viewer-#{Registration.find_by!(name: "Alice").id}", kind: "STANDARD" } ]
  end

  def with_room
    previous = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { EmptyRoom.new }
    yield
  ensure
    Rails.configuration.x.room_service_client_factory = previous
  end

  test "attendance : anonyme renvoyé à la connexion, sans rôle 404" do
    get attendance_webinar_registrations_path(@webinar)
    assert_redirected_to sign_in_path

    sign_in_as(@other)
    get attendance_webinar_registrations_path(@webinar)
    assert_response :not_found
  end

  test "attendance : co-animateur invité → 404, comme la liste (pas d'accès aux inscrits)" do
    guest = User.create!(email: "co@partenaire.test", oidc_sub: "sub-co", email_verified: true,
                         email_verified_for: "co@partenaire.test")
    @webinar.webinar_hosts.create!(email: guest.email, invited_by_sub: @host.oidc_sub)
    sign_in_as(guest)

    get attendance_webinar_registrations_path(@webinar)
    assert_response :not_found
  end

  test "attendance : contrat JSON figé, présence lue dans la salle, jamais le jeton" do
    with_room do
      sign_in_as(@host)
      get attendance_webinar_registrations_path(@webinar)
    end

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    body = response.parsed_body
    assert_equal %w[came present registered registrations room], body.keys.sort
    assert_equal %w[confirmed email id joined_at name participation removed status],
                 body["registrations"].first.keys.sort
    assert_equal [ 3, 1, 1 ], body.values_at("registered", "present", "came")
    assert_equal({ "Alice" => "present", "Bob" => "absent", "Carol" => "absent" },
                 body["registrations"].to_h { |item| [ item["name"], item["status"] ] })
    assert_not_includes response.body, @confirmed.token
    assert_not_nil @confirmed.reload.room_joined_at
  end

  test "liste : colonne « Venu dans la salle »" do
    @paid.update!(room_joined_at: 1.hour.ago)
    sign_in_as(@host)
    get webinar_registrations_path(@webinar)

    assert_select "tr[data-registration-id='#{@paid.id}'] [data-role='registration-attendance']", text: "Oui"
    assert_select "tr[data-registration-id='#{@pending.id}'] [data-role='registration-attendance']", text: "Non"
  end

  private

  # Identique aux autres controller tests animateur — flow OIDC test_mode.
  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id",
      uid: user.oidc_sub,
      info: { email: user.email }
    )
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:pocket_id]
    get "/auth/pocket_id/callback"
    Rails.application.env_config.delete("omniauth.auth")
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end
end
