require "test_helper"

# Sérialisation iCalendar de l'agenda (RFC 5545). Les valeurs attendues sont
# écrites à la main (heures UTC, lignes pliées) : le test ne réutilise pas
# la logique de production pour calculer ce qu'il vérifie.
class WebinarCalendarTest < ActiveSupport::TestCase
  PAGE_URL = ->(webinar) { "https://live.example.test/w/#{webinar.slug}" }

  def webinar(**overrides)
    Webinar.create!({
      title: "Café IA", starts_at: Time.zone.local(2026, 11, 5, 18, 0),
      host_sub: "sub-marc", visibility: "published", kind: "cafe_ia"
    }.merge(overrides))
  end

  def calendar
    WebinarCalendar.new(page_url: PAGE_URL)
  end

  # Lignes logiques : le pliage RFC 5545 (CRLF + espace) est retiré.
  def unfolded(ics)
    ics.gsub("\r\n ", "").split("\r\n")
  end

  def strict_parse(ics)
    Icalendar::Parser.new(ics, true).parse.sole
  end

  test "flux : un VCALENDAR valide, lu par la gem en mode strict" do
    require_undust_theme!
    cafe = webinar
    bootcamp = webinar(title: "Bootcamp", kind: "bootcamp", starts_at: Time.zone.local(2026, 12, 3, 9, 30))

    ics = calendar.feed([ cafe, bootcamp ])

    assert ics.end_with?("END:VCALENDAR\r\n")
    assert_no_match(/(?<!\r)\n/, ics, "toutes les fins de ligne doivent être CRLF")
    parsed = strict_parse(ics)
    assert_equal [ "Café IA", "Bootcamp" ], parsed.events.map { |event| event.summary.to_s }
    lines = unfolded(ics)
    assert_includes lines, "VERSION:2.0"
    assert(lines.none? { |line| line.start_with?("METHOD") }, "pas de METHOD : ce n'est pas un message iTIP")
    assert_includes lines, "X-WR-CALNAME:Webinaires Studio Exemple"
    assert_includes lines, "REFRESH-INTERVAL;VALUE=DURATION:PT1H"
    assert_includes lines, "X-PUBLISHED-TTL:PT1H"
  end

  test "heure de Paris : UTC exact en hiver, en été et le jour du changement d'heure" do
    {
      Time.zone.local(2026, 11, 5, 18, 0) => "20261105T170000Z",
      Time.zone.local(2026, 7, 2, 18, 0)  => "20260702T160000Z",
      Time.zone.local(2026, 3, 29, 9, 0)  => "20260329T070000Z"
    }.each do |starts_at, expected|
      lines = unfolded(calendar.event(webinar(starts_at: starts_at)))
      assert_includes lines, "DTSTART:#{expected}", "début #{starts_at}"
    end
  end

  test "fin = durée prévue du format : 1 h pour un Café IA, 3 h pour un bootcamp" do
    assert_includes unfolded(calendar.event(webinar)), "DTEND:20261105T180000Z"
    bootcamp = webinar(kind: "bootcamp", starts_at: Time.zone.local(2026, 12, 3, 9, 30))
    assert_includes unfolded(calendar.event(bootcamp)), "DTEND:20261203T113000Z"
  end

  test "UID stable, SEQUENCE et LAST-MODIFIED suivent les modifications" do
    created_at = Time.utc(2026, 10, 1, 8, 0, 0)
    item = travel_to(created_at) { webinar(title: "Café IA de novembre") }
    first = unfolded(calendar.event(item))
    assert_includes first, "UID:#{item.slug}@#{WebinarCalendar::UID_DOMAIN}"
    assert_includes first, "SEQUENCE:0"
    assert_includes first, "DTSTAMP:20261001T080000Z"
    assert_includes first, "LAST-MODIFIED:20261001T080000Z"

    travel_to(created_at + 90.seconds) { item.update!(title: "Café IA décalé", starts_at: item.starts_at + 1.hour) }
    second = unfolded(calendar.event(item))
    assert_includes second, "UID:#{item.slug}@#{WebinarCalendar::UID_DOMAIN}"
    assert_includes second, "SEQUENCE:90"
    assert_includes second, "DTSTAMP:20261001T080130Z"
    assert_includes second, "LAST-MODIFIED:20261001T080130Z"
    assert_includes second, "DTSTART:20261105T180000Z"
  end

  test "rendu déterministe : deux rendus du même état sont identiques" do
    item = webinar
    assert_equal calendar.feed([ item ]), calendar.feed([ item ])
  end

  test "TEXT échappé : séparateurs, antislash et retour à la ligne ne fabriquent aucune propriété" do
    item = webinar(title: "Café; IA, \\ demo\r\nATTENDEE:mailto:evil@example.test",
                   description: "Ligne 1\nLigne 2; virgule, fin")
    ics = calendar.event(item)
    lines = unfolded(ics)

    assert_includes lines, 'SUMMARY:Café\; IA\, \\\\ demo\nATTENDEE:mailto:evil@example.test'
    assert(lines.none? { |line| line.start_with?("ATTENDEE") }, "aucune propriété injectée")
    description = lines.find { |line| line.start_with?("DESCRIPTION:") }
    assert_includes description, 'Ligne 1\nLigne 2\; virgule\, fin'
    assert_equal "Café; IA, \\ demo\nATTENDEE:mailto:evil@example.test", strict_parse(ics).events.sole.summary.to_s
  end

  test "lignes pliées à 75 octets sans couper un caractère multi-octets" do
    long_text = Array.new(20, "Élan, été, œuvre").join(" — ")
    ics = calendar.event(webinar(description: long_text))

    physical = ics.split("\r\n")
    assert physical.all? { |line| line.bytesize <= 75 }, "ligne > 75 octets"
    assert physical.all?(&:valid_encoding?), "caractère UTF-8 coupé au pliage"
    assert physical.count { |line| line.start_with?(" ") } > 1, "la description doit être pliée"
    assert_includes strict_parse(ics).events.sole.description.to_s, long_text
  end

  test "DESCRIPTION en texte brut : format, prix et lien de la page, balisage retiré" do
    item = webinar(description: "<p>Démo <b>live</b> & questions</p><script>alert(1)</script>")
    description = strict_parse(calendar.event(item)).events.sole.description.to_s

    assert_equal "Démo live & questions\n\nCafé IA · Gratuit\n\nPage du webinaire : https://live.example.test/w/#{item.slug}",
                 description
  end

  test "URL et LOCATION = page publique du webinaire" do
    item = webinar
    event = strict_parse(calendar.event(item)).events.sole
    assert_equal "https://live.example.test/w/#{item.slug}", event.url.to_s
    assert_equal "https://live.example.test/w/#{item.slug}", event.location.to_s
  end

  test "Google Agenda : événement prérempli, même description que le .ics" do
    item = webinar(kind: "bootcamp", price_cents: 9900, description: "Atelier pratique")
    url = URI(calendar.google_event_url(item))
    query = Rack::Utils.parse_query(url.query)

    assert_equal "https://calendar.google.com/calendar/render", "#{url.scheme}://#{url.host}#{url.path}"
    assert_equal "TEMPLATE", query["action"]
    assert_equal "Café IA", query["text"]
    assert_equal "20261105T170000Z/20261105T200000Z", query["dates"]
    assert_equal "Atelier pratique\n\nBootcamp · 99,00 €\n\nPage du webinaire : https://live.example.test/w/#{item.slug}",
                 query["details"]
    assert_equal "https://live.example.test/w/#{item.slug}", query["location"]
    assert_equal "Europe/Paris", query["ctz"]
  end

  test "Google Agenda : texte libre tronqué, format, prix et lien conservés" do
    item = webinar(description: "x" * 2000)
    details = Rack::Utils.parse_query(URI(calendar.google_event_url(item)).query)["details"]

    assert_equal "#{"x" * 497}...", details.split("\n\n").first
    assert details.end_with?("Café IA · Gratuit\n\nPage du webinaire : https://live.example.test/w/#{item.slug}")
  end

  test "fichier unitaire : un seul VEVENT, sans propriétés d'abonnement" do
    ics = calendar.event(webinar)
    assert_equal 1, ics.scan("BEGIN:VEVENT").size
    assert_no_match(/X-WR-CALNAME|REFRESH-INTERVAL|X-PUBLISHED-TTL/, ics)
  end
end
