require "test_helper"

# API publique de l'agenda pour les sites tiers (tartiflette.dev) :
# /agenda/next.json (contrat live.agenda.next.v2) et lecture cross-origin des
# routes publiques de l'agenda. Le flux personnel : CalendarFeedsControllerTest.
class AgendaNextTest < ActionDispatch::IntegrationTest
  setup do
    travel_to Time.zone.local(2026, 10, 30, 10, 0)
    @november = publish(title: "Café IA de novembre", starts_at: Time.zone.local(2026, 11, 5, 18, 0))
    @december = publish(title: "Bootcamp de décembre", starts_at: Time.zone.local(2026, 12, 3, 9, 30),
                        kind: "bootcamp", price_cents: 9900)
    @january  = publish(title: "Café IA de janvier", starts_at: Time.zone.local(2027, 1, 7, 18, 0))
    @past     = publish(title: "Café IA de septembre", starts_at: Time.zone.local(2026, 9, 24, 9, 30), state: "ended")
    @draft    = Webinar.create!(title: "Brouillon non annoncé", starts_at: Time.zone.local(2026, 11, 2, 18, 0),
                                host_sub: "sub-marc", visibility: "draft")
  end

  def publish(**attributes)
    Webinar.create!({ host_sub: "sub-marc", visibility: "published", kind: "cafe_ia" }.merge(attributes))
  end

  def next_dates(**params)
    get agenda_next_path, params: params
    assert_response :success
    response.parsed_body
  end

  def titles_and_statuses(body)
    body["webinars"].map { |webinar| [ webinar["title"], webinar["status"] ] }
  end

  def feed_calendar
    Icalendar::Parser.new(response.body, true).parse.sole
  end

  REGISTER_BLOCK = { "page_url" => "http://www.example.com/agenda",
                     "register_url" => "http://www.example.com/agenda#inscription" }.freeze

  # ---- Sélection ----------------------------------------------------------

  test "un direct en cours, puis les deux dates suivantes" do
    publish(title: "Café IA en direct", starts_at: 20.minutes.ago, state: "live")

    assert_equal [ [ "Café IA en direct", "live" ], [ "Café IA de novembre", "upcoming" ],
                   [ "Bootcamp de décembre", "upcoming" ] ], titles_and_statuses(next_dates)
  end

  test "un direct qui vient de se terminer laisse place aux trois dates suivantes" do
    publish(title: "Café IA de ce matin", starts_at: 50.minutes.ago, state: "ended")

    assert_equal [ [ "Café IA de novembre", "upcoming" ], [ "Bootcamp de décembre", "upcoming" ],
                   [ "Café IA de janvier", "upcoming" ] ], titles_and_statuses(next_dates)
  end

  test "un direct en retard de démarrage suit le direct en cours ; au-delà de la fenêtre il disparaît" do
    publish(title: "Café IA en direct", starts_at: 2.hours.ago, state: "live")
    publish(title: "Café IA en retard", starts_at: 30.minutes.ago)
    publish(title: "Café IA jamais lancé", starts_at: Webinar::LATE_START_WINDOW.ago - 1.minute)

    assert_equal [ [ "Café IA en direct", "live" ], [ "Café IA en retard", "starting_late" ],
                   [ "Café IA de novembre", "upcoming" ] ], titles_and_statuses(next_dates)
  end

  test "aucun brouillon, même en direct" do
    Webinar.create!(title: "Répétition privée", starts_at: 10.minutes.ago, host_sub: "sub-marc",
                    state: "live", visibility: "draft")

    titles = next_dates(limit: 10)["webinars"].pluck("title")

    assert_equal [ "Café IA de novembre", "Bootcamp de décembre", "Café IA de janvier" ], titles
  end

  test "dates à égalité d'heure : départagées par ordre de création" do
    twin = publish(title: "Café IA jumeau", starts_at: @november.starts_at)

    assert_equal [ @november.slug, twin.slug ], next_dates(limit: 2)["webinars"].pluck("slug")
  end

  test "filtre kind : les dates ne portent que ce format ; le bloc d'inscription ne change pas" do
    body = next_dates(kind: "bootcamp")

    assert_equal [ "Bootcamp de décembre" ], body["webinars"].pluck("title")
    assert_equal REGISTER_BLOCK, body["calendar"]
  end

  test "limit : 3 par défaut, borné entre 1 et 10, illisible → défaut" do
    9.times { |week| publish(title: "Café IA #{week}", starts_at: Time.zone.local(2027, 2, 4, 18, 0) + week.weeks) }

    assert_equal 3,  next_dates["webinars"].size
    assert_equal 1,  next_dates(limit: 1)["webinars"].size
    assert_equal 1,  next_dates(limit: 0)["webinars"].size
    assert_equal 10, next_dates(limit: 50)["webinars"].size
    assert_equal 3,  next_dates(limit: "trois")["webinars"].size
  end

  test "kind inconnu : 400 en JSON, lisible par le site appelant" do
    get agenda_next_path, params: { kind: "masterclass" }

    assert_response :bad_request
    assert_equal "application/json", response.media_type
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
    assert_equal({ "error" => "invalid_kind", "message" => "kind must be one of: cafe_ia, bootcamp",
                   "allowed_kinds" => [ "cafe_ia", "bootcamp" ] }, response.parsed_body)
  end

  # ---- Forme de la réponse --------------------------------------------------

  # v2 : plus aucun flux public d'abonnement, seulement où s'inscrire pour
  # recevoir le flux personnel. Le fichier d'un café (`ics_url`) reste public.
  test "forme JSON v2 : bloc d'inscription et dates en UTC, URL absolues" do
    get agenda_next_path

    assert_equal "/agenda/next.json", agenda_next_path
    assert_equal "application/json", response.media_type
    body = response.parsed_body
    assert_equal REGISTER_BLOCK, body["calendar"]

    november, december = body["webinars"]
    google = november.delete("google_calendar_url")
    assert_equal({ "slug" => @november.slug, "title" => "Café IA de novembre", "kind" => "cafe_ia",
                   "status" => "upcoming", "date_status" => "confirmed",
                   "starts_at" => "2026-11-05T17:00:00Z", "ends_at" => "2026-11-05T18:00:00Z",
                   "url" => "http://www.example.com/w/#{@november.slug}",
                   "ics_url" => "http://www.example.com/w/#{@november.slug}.ics",
                   "free" => true, "price_label" => "Gratuit",
                   "topic" => nil, "speakers" => [], "lead_host" => nil }, november)
    assert_equal "TEMPLATE", Rack::Utils.parse_query(URI(google).query)["action"]
    assert_equal "20261105T170000Z/20261105T180000Z", Rack::Utils.parse_query(URI(google).query)["dates"]
    assert_equal [ false, "99,00 €", "2026-12-03T11:30:00Z" ],
                 december.values_at("free", "price_label", "ends_at")
  end

  # Programme (ajout compatible) : sujet, intervenants annoncés
  # dans leur ordre, animateur du jour. Texte brut, tel que saisi.
  test "programme d'une date : sujet et présentation, intervenants, animateur du jour" do
    @november.update!(topic: "Agents IA : ce qui marche", topic_summary: "Deux retours <b>de terrain</b>.",
                      announced_speakers: [ "Karim", "Anne" ], lead_host_name: "Marc")
    @december.update!(topic: "Prompting avancé")

    november, december = next_dates["webinars"]

    assert_equal({ "title" => "Agents IA : ce qui marche", "summary" => "Deux retours <b>de terrain</b>." },
                 november["topic"])
    assert_equal [ "Karim", "Anne" ], november["speakers"]
    assert_equal "Marc", november["lead_host"]
    assert_equal [ { "title" => "Prompting avancé", "summary" => nil }, [], nil ],
                 december.values_at("topic", "speakers", "lead_host")
  end

  test "aucune date à venir : liste vide, bloc d'inscription présent" do
    Webinar.where.not(id: @past.id).destroy_all

    body = next_dates

    assert_equal [], body["webinars"]
    assert_equal REGISTER_BLOCK, body["calendar"]
  end

  test "cache public d'une minute, aucun cookie" do
    get agenda_next_path

    assert_equal "max-age=60, public", response.headers["Cache-Control"]
    assert_nil response.headers["Set-Cookie"]
  end

  # ---- Langue -----------------------------------------------------------------

  test "réponses ouvertes : toujours en français, ?locale= ignoré, aucun cookie de langue" do
    get agenda_next_path, params: { locale: "en" }

    assert_nil response.headers["Set-Cookie"]
    assert_equal [ "Gratuit", "99,00 €" ], response.parsed_body["webinars"].first(2).pluck("price_label")

    get agenda_path(format: :ics, locale: "en")
    assert_nil response.headers["Set-Cookie"]
    assert_includes response.body, "Inscrivez-vous"

    get webinar_calendar_path(slug: @november.slug, format: :ics, locale: "en")
    assert_nil response.headers["Set-Cookie"]
    assert_includes feed_calendar.events.sole.description.to_s, "Café IA · Gratuit"
  end

  test "réponses ouvertes : le cookie de langue posé par la page ne les traduit pas" do
    get agenda_path(locale: "en")
    assert_match(/\Alocale=en;/, response.headers["Set-Cookie"])

    get agenda_next_path

    assert_equal "Gratuit", response.parsed_body["webinars"].first["price_label"]
    assert_nil response.headers["Set-Cookie"]
  end

  # ---- Lecture cross-origin -----------------------------------------------------

  test "CORS ouvert sur le JSON, le fichier d'un café et le 410 de l'ancien flux, sans credentials ni cookie" do
    { agenda_next_path => :success, webinar_calendar_path(slug: @november.slug, format: :ics) => :success,
      agenda_path(format: :ics) => :gone }.each do |path, status|
      get path, headers: { "Origin" => "https://tartiflette.dev" }

      assert_response status, path
      assert_equal "*", response.headers["Access-Control-Allow-Origin"], path
      assert_nil response.headers["Access-Control-Allow-Credentials"], path
      assert_nil response.headers["Set-Cookie"], path
    end
  end

  test "CORS absent de la page agenda et des pages webinaire" do
    [ agenda_path, public_webinar_path(slug: @november.slug), public_webinar_state_path(slug: @november.slug) ].each do |path|
      get path, headers: { "Origin" => "https://tartiflette.dev" }

      assert_response :success, path
      assert_nil response.headers["Access-Control-Allow-Origin"], path
    end
  end
end
