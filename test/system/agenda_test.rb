require "application_system_test_case"

# Parcours visiteur de l'agenda (rack_test : aucun JS en jeu) : accueil →
# agenda → page du webinaire → « Ajouter à mon agenda » (.ics unitaire).
class AgendaTest < ApplicationSystemTestCase
  setup do
    travel_to Time.zone.local(2026, 10, 30, 10, 0)
    @webinar = Webinar.create!(
      title: "Café IA — agenda", starts_at: Time.zone.local(2026, 11, 5, 18, 0),
      host_sub: "sub-marc", visibility: "published", kind: "cafe_ia"
    )
  end

  test "de l'accueil à l'événement ajouté dans son agenda" do
    visit root_path
    click_link "Agenda : toutes les dates des webinaires"

    assert_selector "h1", text: "Agenda des webinaires"
    assert_selector "[data-role='agenda-mois'] h2", text: "Novembre 2026"
    assert_selector "[data-role='agenda-mois'] .quand", text: /jeudi 5 novembre · 18h00 · Café IA · Gratuit/
    click_link "Café IA — agenda"

    assert_selector "[data-role='pre-live'] h1", text: "Café IA — agenda"
    google = find("[data-role='add-to-calendar-google']")
    assert google[:href].start_with?("https://calendar.google.com/calendar/render?action=TEMPLATE")
    assert_includes google[:href], "text=Caf%C3%A9+IA+%E2%80%94+agenda"

    click_link "Ajouter à mon agenda"

    assert_equal "text/calendar", page.response_headers["Content-Type"].split(";").first
    event = Icalendar::Parser.new(page.body, true).parse.sole.events.sole
    assert_equal "Café IA — agenda", event.summary.to_s
    assert_equal "#{@webinar.slug}@#{WebinarCalendar::UID_DOMAIN}", event.uid.to_s
  end

  test "le bouton n'apparaît ni sur un direct terminé, ni sur un direct en cours" do
    @webinar.update!(state: "ended")
    visit public_webinar_path(slug: @webinar.slug)
    assert_selector "[data-role='pre-live']"
    assert_no_selector "[data-role='add-to-calendar']"

    @webinar.update!(state: "live")
    visit public_webinar_path(slug: @webinar.slug)
    assert_selector "[data-role='live-registration-required']"
    assert_no_selector "[data-role='add-to-calendar']"
  end
end
