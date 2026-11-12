require "test_helper"

# Flux d'agenda personnel /agenda/<jeton>.ics (CalendarSubscription) : même
# contenu que l'ancien flux public, réservé au jeton d'une personne inscrite.
# Octets figés : AgendaFeedGoldenTest.
class CalendarFeedsControllerTest < ActionDispatch::IntegrationTest
  setup do
    travel_to Time.zone.local(2026, 10, 30, 10, 0)
    @november = publish(title: "Café IA de novembre", starts_at: Time.zone.local(2026, 11, 5, 18, 0))
    @december = publish(title: "Bootcamp de décembre", starts_at: Time.zone.local(2026, 12, 3, 9, 30),
                        kind: "bootcamp", price_cents: 9900)
    @past     = publish(title: "Café IA de septembre", starts_at: Time.zone.local(2026, 9, 24, 9, 30), state: "ended")
    Webinar.create!(title: "Brouillon non annoncé", starts_at: Time.zone.local(2026, 11, 12, 18, 0),
                    host_sub: "sub-marc", visibility: "draft")
    @subscription = CalendarSubscription.create!(email: "alice@example.test")
  end

  def publish(**attributes)
    Webinar.create!({ host_sub: "sub-marc", visibility: "published", kind: "cafe_ia" }.merge(attributes))
  end

  def feed_path(**params)
    personal_agenda_path(@subscription.token, format: :ics, **params)
  end

  def feed_calendar
    Icalendar::Parser.new(response.body, true).parse.sole
  end

  def summaries
    feed_calendar.events.map { |event| event.summary.to_s }
  end

  test "text/calendar en ligne : tous les publiés, passés compris, aucun brouillon" do
    get feed_path

    assert_response :success
    assert_equal "text/calendar", response.media_type
    assert_equal "utf-8", response.charset
    assert_match(/\Ainline/, response.headers["Content-Disposition"])
    assert_equal WebinarCalendar::NAME, feed_calendar.x_wr_calname.sole.to_s
    assert_equal [ "Café IA de septembre", "Café IA de novembre", "Bootcamp de décembre" ], summaries
    assert_no_match(/Brouillon non annoncé/, response.body)
  end

  test "les dates futures se mettent à jour : déplacée, ajoutée, dépubliée, au rafraîchissement suivant" do
    get feed_path
    first_sequence = feed_calendar.events.second.sequence.to_i

    travel 1.hour
    @november.update!(starts_at: Time.zone.local(2026, 11, 6, 9, 30))
    publish(title: "Café IA de janvier", starts_at: Time.zone.local(2027, 1, 7, 9, 30))
    @december.update!(visibility: "draft")

    get feed_path

    november = feed_calendar.events.find { |event| event.summary.to_s == "Café IA de novembre" }
    assert_equal Time.utc(2026, 11, 6, 8, 30), november.dtstart.to_time.utc
    assert_operator november.sequence.to_i, :>, first_sequence
    assert_equal "#{@november.slug}@#{WebinarCalendar::UID_DOMAIN}", november.uid.to_s
    assert_equal [ "Café IA de septembre", "Café IA de novembre", "Café IA de janvier" ], summaries
  end

  test "kind : ce format seul, calendrier nommé ; vide = sans filtre ; inconnu = 400" do
    get feed_path(kind: "cafe_ia")
    assert_equal [ "Café IA de septembre", "Café IA de novembre" ], summaries
    assert_match(/\ACafé IA — /, feed_calendar.x_wr_calname.sole.to_s)

    get feed_path
    full = response.body
    get feed_path(kind: "")
    assert_equal full, response.body

    get feed_path(kind: "masterclass")
    assert_response :bad_request
    assert_equal "text/plain", response.media_type
    assert_equal "kind must be one of: cafe_ia, bootcamp", response.body
  end

  test "jeton inconnu ou révoqué : 404, sans contenu" do
    get personal_agenda_path("jeton-inconnu", format: :ics)
    assert_response :not_found

    @subscription.revoke!
    get feed_path
    assert_response :not_found
    assert_no_match(/VCALENDAR/, response.body)
  end

  test "chaque lecture compte, 304 compris, sans toucher updated_at" do
    updated_at = @subscription.updated_at
    get feed_path
    etag = response.headers["ETag"]

    travel 2.hours
    get feed_path, headers: { "If-None-Match" => etag }
    assert_response :not_modified

    @subscription.reload
    assert_equal 2, @subscription.fetch_count
    assert_equal Time.current, @subscription.last_fetched_at
    assert_equal updated_at, @subscription.updated_at
  end

  test "une lecture refusée ne compte pas" do
    @subscription.revoke!
    get feed_path

    assert_equal 0, @subscription.reload.fetch_count
  end

  test "réponse privée : cache partagé exclu, aucun cookie, pas de CORS, toujours en français" do
    get agenda_path(locale: "en")
    get feed_path(locale: "en"), headers: { "Origin" => "https://tartiflette.dev" }

    assert_response :success
    assert_equal "max-age=0, private, must-revalidate", response.headers["Cache-Control"]
    assert_nil response.headers["Set-Cookie"]
    assert_nil response.headers["Access-Control-Allow-Origin"]
    assert_includes feed_calendar.events.second.description.to_s, "Café IA · Gratuit"
  end

  test "la route ne capture ni /agenda/next.json ni un autre format" do
    get agenda_next_path
    assert_response :success
    assert_equal "application/json", response.media_type

    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/agenda/#{@subscription.token}.json", method: :get)
    end
  end

  test "le jeton n'apparaît pas dans le journal de requêtes" do
    assert_equal "/agenda/[FILTERED]", TokenPathMask.mask(feed_path)
    assert_equal "/agenda/next.json", TokenPathMask.mask(agenda_next_path)
  end
end
