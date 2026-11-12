require "application_system_test_case"

# Page « Présence » d'un café passé, vue par son animateur : la courbe, qui
# était là et quand, qui a essayé sans entrer, qui n'est jamais venu.
class PresencePageTest < ApplicationSystemTestCase
  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: at("9:30"), host_sub: @host.oidc_sub)
    @webinar.update!(state: "ended", started_at: at("9:32"), ended_at: at("10:51"))
    alice = registration("Alice")
    bruno = registration("Bruno")
    denis = registration("Denis")
    registration("Élise")
    speaker = @webinar.speakers.create!(name: "Alice", registration: alice)
    [
      [ "9:30:08", "joined", "host-sub-marc" ], [ "9:32:54", "joined", "viewer-#{alice.id}" ],
      [ "9:33:39", "joined", "viewer-#{bruno.id}" ], [ "9:35:00", "joined", "speaker-#{speaker.id}" ],
      [ "9:35:08", "left", "viewer-#{alice.id}" ], [ "9:36:16", "left", "viewer-#{bruno.id}" ],
      [ "9:36:34", "aborted", "viewer-#{bruno.id}" ], [ "9:41:00", "page_opened", "viewer-#{denis.id}" ],
      [ "10:30:10", "left", "speaker-#{speaker.id}" ], [ "10:52:02", "room_finished", nil ]
    ].each do |clock, kind, identity|
      @webinar.presence_events.create!(kind: kind, identity: identity, occurred_at: at(clock), source: "livekit_log")
    end
  end

  def at(clock)
    Time.zone.parse("2026-11-10 #{clock}")
  end

  def registration(name)
    @webinar.registrations.create!(name: name, email: "#{I18n.transliterate(name).downcase}@example.test", confirmed_at: 2.days.ago)
  end

  test "l'animateur lit la présence de son café, rien n'y est une commande" do
    sign_in_host
    visit webinar_room_presence_path(@webinar)

    assert_selector "h1", text: "Présence — Café IA #9"
    assert_text "2 inscrits venus sur 4 attendus"
    assert_text "Au plus fort : 3 présents, à 9:33"
    assert_selector "[data-role=presence-curve] svg[role=img] title", text: "Nombre de présents de 9:30 à 10:52, au plus 3", visible: :all

    within "[data-role=presence-chronology]" do
      rows = all("[data-role=presence-person]")
      assert_equal [ "marc", "Alice", "Bruno" ], rows.map { |row| row.all("td")[1].text }
      assert_equal "Intervenant (inscrit)", rows[1].all("td")[2].text
      assert_equal "9:32 → 10:30", rows[1].all("td")[3].text
      assert_includes rows[2].text, "connexion interrompue à 9:36"
    end
    within("[data-role=presence-tried]") { assert_text "Denis (inscrit) : page ouverte à 9:41" }
    within("[data-role=presence-never-came]") { assert_text "Élise" }
    assert_text "journal du serveur LiveKit, rejoué après coup"

    assert_no_selector "main form"
    assert_no_selector "main button"
  end

  private

  def sign_in_host
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: @host.oidc_sub, info: { email: @host.email }
    )
    visit "/auth/pocket_id/callback"
  end
end

class PresencePageMobileTest < JsSystemTestCase
  include OidcSignIn

  setup do
    @host = User.create!(email: "marc-mobile@example.com", oidc_sub: "sub-marc-mobile", admin: true)
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: Time.zone.parse("2026-11-10 9:30"),
                               host_sub: @host.oidc_sub)
    @webinar.update!(state: "ended", started_at: Time.zone.parse("2026-11-10 9:32"),
                     ended_at: Time.zone.parse("2026-11-10 10:51"))
    alice = @webinar.registrations.create!(name: "Alice", email: "alice-mobile@example.test", confirmed_at: 2.days.ago)
    [
      [ "9:30", "joined", "host-#{@host.oidc_sub}" ],
      [ "9:32", "joined", "viewer-#{alice.id}" ],
      [ "10:30", "left", "viewer-#{alice.id}" ]
    ].each do |clock, kind, identity|
      @webinar.presence_events.create!(kind: kind, identity: identity,
                                       occurred_at: Time.zone.parse("2026-11-10 #{clock}"), source: "livekit")
    end
  end

  test "à 375 px la courbe tient dans l'écran, sans défilement horizontal" do
    sign_in_as(@host)
    page.current_window.resize_to(375, 812)
    visit webinar_room_presence_path(@webinar)

    curve = find("[data-role=presence-curve] svg.presence-svg")
    page.scroll_to(curve, align: :center)
    overflow = evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
    assert_operator overflow, :<=, 1, "défilement horizontal de #{overflow} px à 375 px"
    svg_width = evaluate_script("document.querySelector('.presence-svg').getBoundingClientRect().width")
    viewport = evaluate_script("document.documentElement.clientWidth")
    assert_operator svg_width, :<=, viewport, "courbe #{svg_width} px plus large que #{viewport} px"
    page.save_screenshot(Rails.root.join("tmp/presence-curve-375.png"))
  end
end
