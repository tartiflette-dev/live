require "application_system_test_case"

# Présence des animateurs (docs/host-presence.md), parcours rack_test : le lien
# du mail mène à une page à boutons sans effet ; « oui » de tous = « date
# confirmée » partout en public ; « non » = mail au propriétaire, rien côté
# public ; le propriétaire répond aussi depuis la page du café.
class HostPresenceTest < ApplicationSystemTestCase
  include OidcSignIn
  include ActionMailer::TestHelper
  include ActiveJob::TestHelper

  setup do
    @owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    @webinar = Webinar.create!(title: "Café IA 12", starts_at: 10.days.from_now, host_sub: @owner.oidc_sub, visibility: "published")
    @host = @webinar.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: @owner.oidc_sub)
    @attendance = HostAttendance.for!(@webinar, @host)
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "tous disent oui : la date passe « confirmée » au catalogue, à l'agenda et sur la page du café" do
    HostAttendance.for!(@webinar).answer!("present")
    assert_public_status "À confirmer"

    visit link_from_request_mail("Je serai là")
    assert_selector "h1", text: "Seras-tu là ?"
    assert_nil @attendance.reload.answer, "ouvrir le lien ne répond pas"
    click_button "Je serai là"

    assert_selector "h1", text: "C'est noté : tu seras là"
    assert_public_status "Date confirmée"
  end

  test "un « non » : mail immédiat au propriétaire, la date reste « à confirmer », rien d'autre ne change" do
    HostAttendance.for!(@webinar).answer!("present")

    visit link_from_request_mail("Je ne serai pas là")
    perform_enqueued_jobs { click_button "Je ne serai pas là" }

    assert_selector "h1", text: "C'est noté : tu ne seras pas là"
    notice = ActionMailer::Base.deliveries.sole
    assert_equal [ "owner@example.net" ], notice.to
    assert_match(/jean@partenaire\.example\.org ne sera pas là/, notice.subject)
    assert_public_status "À confirmer"
    assert @webinar.reload.visibility_published?
  end

  test "le propriétaire, présumé présent, passe à « non » depuis la page du café ; la régie montre le statut" do
    HostAttendance.for!(@webinar, @host).answer!("present")
    sign_in_as(@owner)

    visit webinar_path(@webinar)
    within("[data-role='host-presence']") do
      assert_text "Date confirmée"
      assert_selector "[data-role='host-presence-mine']", text: "sera là"
      assert_selector "[data-role='host-presence-list'] li[data-answer='present']", count: 2
      click_button "Je ne serai pas là"
    end

    assert_text "Noté : tu ne seras pas là."
    within("[data-role='host-presence']") do
      assert_text "À confirmer"
      assert_selector "[data-role='host-presence-list'] li[data-answer='absent']", text: "owner@example.net"
    end
    assert_empty ActionMailer::Base.deliveries, "le « non » du propriétaire ne prévient personne"

    visit webinar_regie_path(@webinar)
    assert_selector "[data-role='regie-date-status']", text: "À confirmer"
  end

  test "café sans co-animateur : « Date confirmée » d'office en public" do
    @host.destroy!

    assert_public_status "Date confirmée"
  end

  # Invariant : un co-animateur invité ne voit pas la liste des co-animateurs.
  test "co-animateur connecté, café à deux co-animateurs : sa présence seulement, ni la liste ni l'autre adresse" do
    @webinar.webinar_hosts.create!(email: "paul@partenaire.example.org", invited_by_sub: @owner.oidc_sub)
    guest = User.create!(email: @host.email, oidc_sub: "sub-jean")
    sign_in_as(guest)

    visit webinar_path(@webinar)
    within("[data-role='host-presence']") do
      assert_selector "[data-role='host-presence-mine']", text: "pas encore répondu"
      assert_no_selector "[data-role='host-presence-list']"
      click_button "Je serai là"
    end
    assert_text "Noté : tu seras là."
    assert_no_selector "[data-role='host-presence-list']"
    assert_no_text "paul@partenaire.example.org"
    assert_no_text "owner@example.net"
  end

  test "co-animateur retiré : le lien de son mail n'est plus valable" do
    link = link_from_request_mail("Je serai là")
    @host.destroy!

    visit link
    assert_selector "h1", text: "Ce lien de présence n’est pas valable"
    assert_no_button "Je serai là"
  end

  private

  def link_from_request_mail(label)
    html = Nokogiri::HTML(HostAttendanceMailer.presence_request(@attendance).html_part.body.decoded)
    URI(html.at_xpath("//a[text()='#{label}']")["href"]).request_uri
  end

  def assert_public_status(label)
    visit root_path
    within("[data-role='catalogue']") { assert_selector "[data-role='date-status']", text: label }
    visit agenda_path
    assert_selector "[data-role='agenda-webinaire'] [data-role='date-status']", text: label
    visit public_webinar_path(slug: @webinar.slug)
    within("[data-role='pre-live']") { assert_selector "[data-role='date-status']", text: label }
  end
end
