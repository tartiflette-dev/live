require "test_helper"

# Agenda public : page /agenda, ancien flux public /agenda.ics (fermé, 410),
# fichier unitaire /w/:slug.ics. Anonyme partout ; seuls les webinaires
# publiés. Le flux personnel : CalendarFeedsControllerTest.
class AgendaControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  OLD_CHROME_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " \
                  "(KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36".freeze

  setup do
    travel_to Time.zone.local(2026, 10, 30, 10, 0)
    @november = publish(title: "Café IA de novembre", starts_at: Time.zone.local(2026, 11, 5, 18, 0))
    @december = publish(title: "Bootcamp de décembre", starts_at: Time.zone.local(2026, 12, 3, 9, 30),
                        kind: "bootcamp", price_cents: 9900)
    @past     = publish(title: "Café IA de septembre", starts_at: Time.zone.local(2026, 9, 24, 9, 30), state: "ended")
    @draft    = Webinar.create!(title: "Brouillon non annoncé", starts_at: Time.zone.local(2026, 11, 12, 18, 0),
                                host_sub: "sub-marc", visibility: "draft")
  end

  def publish(**attributes)
    Webinar.create!({ host_sub: "sub-marc", visibility: "published", kind: "cafe_ia" }.merge(attributes))
  end

  def feed_summaries
    Icalendar::Parser.new(response.body, true).parse.sole.events.map { |event| event.summary.to_s }
  end

  # ---- Ancien flux public ------------------------------------------------

  # Fermé : un agenda abonné reçoit Gone et cesse d'interroger,
  # une personne qui ouvre l'adresse lit comment obtenir son lien.
  test "ancien flux public : 410, texte qui renvoie vers l'inscription, aucun webinaire" do
    [ agenda_path(format: :ics), agenda_path(format: :ics, kind: "cafe_ia"), agenda_path(format: :ics, kind: "masterclass") ].each do |path|
      get path

      assert_response :gone, path
      assert_equal "text/plain", response.media_type
      assert_equal "Ce flux public est fermé. Inscrivez-vous à un webinaire (http://www.example.com/agenda) " \
                   "pour recevoir votre lien d'agenda personnel, mis à jour à chaque nouvelle date.", response.body
      assert_no_match(/BEGIN:VCALENDAR|Café IA de novembre/, response.body)
    end
  end

  test "l'agenda n'accepte ni JSON ni autre format que la page et le 410" do
    get agenda_path(format: :json)
    assert_response :not_acceptable
  end

  # ---- Fichier unitaire -------------------------------------------------

  test "fichier unitaire : un seul événement, en pièce jointe nommée d'après le slug" do
    get webinar_calendar_path(slug: @november.slug, format: :ics)

    assert_response :success
    assert_equal "text/calendar", response.media_type
    assert_equal "utf-8", response.charset
    assert_match(/\Aattachment; filename="#{@november.slug}\.ics"/, response.headers["Content-Disposition"])
    assert_equal [ "Café IA de novembre" ], feed_summaries
  end

  test "fichier unitaire : 404 pour un brouillon ou un slug inconnu" do
    get webinar_calendar_path(slug: @draft.slug, format: :ics)
    assert_response :not_found

    get webinar_calendar_path(slug: "inconnu", format: :ics)
    assert_response :not_found
  end

  test "la route .ics ne détourne pas la page publique /w/:slug" do
    assert_equal "/w/#{@november.slug}.ics", webinar_calendar_path(slug: @november.slug, format: :ics)

    get public_webinar_path(slug: @november.slug)
    assert_response :success
    assert_select "[data-role='pre-live']"

    get "/w/#{@november.slug}.json"
    assert_response :not_acceptable
  end

  # ---- Page agenda -------------------------------------------------------

  test "page : dates à venir par mois, heure de Paris, format, prix et lien vers la page" do
    get agenda_path

    assert_response :success
    assert_select "section[data-role='agenda-mois']", count: 2
    assert_select "section[data-role='agenda-mois'] h2", text: "Novembre 2026"
    assert_select "section[data-role='agenda-mois'] h2", text: "Décembre 2026"

    november = css_select("section[data-role='agenda-mois']").first
    assert_includes november.text, "jeudi 5 novembre · 18h00"
    assert_includes november.text, "Café IA · Gratuit"
    assert_select november, "a[href=?]", public_webinar_path(slug: @november.slug), text: "Café IA de novembre"

    assert_includes response.body, "Bootcamp · 99,00 €"
    assert_no_match(/Brouillon non annoncé/, response.body)
  end

  test "page : le programme annoncé suit le titre de sa date, échappé ; rien sans programme" do
    @november.update!(topic: "Agents <IA>", announced_speakers: [ "Karim", "Anne" ], lead_host_name: "Marc")
    @december.update!(lead_host_name: "Jean")

    get agenda_path

    november, december = css_select("section[data-role='agenda-mois']")
    assert_select november, "[data-role='agenda-program']", text: "Agents <IA> · avec Karim et Anne · animé par Marc"
    assert_includes response.body, "Agents &lt;IA&gt;"
    assert_select december, "[data-role='agenda-program']", text: "Animé par Jean"

    @november.update!(topic: nil, announced_speakers: [], lead_host_name: nil)
    get agenda_path
    assert_select "[data-role='agenda-program']", count: 1, text: "Animé par Jean"
  end

  test "page publique d'un café : programme en texte brut, jamais interprété" do
    @november.update!(topic: "<script>alert(1)</script>", topic_summary: "<b>gras</b>",
                      announced_speakers: [ "<i>Karim</i>" ], lead_host_name: "<u>Marc</u>")

    get public_webinar_path(slug: @november.slug)

    assert_select "[data-role='webinar-program'] script", count: 0
    assert_select "[data-role='webinar-program'] b, [data-role='webinar-program'] i, [data-role='webinar-program'] u",
                  count: 0
    assert_select "[data-role='program-topic']", text: "<script>alert(1)</script>"
    assert_select "[data-role='program-topic-summary']", text: "<b>gras</b>"
    assert_select "[data-role='program-speakers']", text: "<i>Karim</i>"
    assert_select "[data-role='program-lead-host']", text: "<u>Marc</u>"
  end

  test "page : les webinaires passés sont repliés à part" do
    get agenda_path

    assert_select "section[data-role='agenda-mois']", text: /Café IA de septembre/, count: 0
    assert_select "[data-role='agenda-passes'] details summary", text: "Afficher le webinaire passé"
    assert_select "[data-role='agenda-passes'] details a[href=?]", public_webinar_path(slug: @past.slug)
    assert_select "[data-role='agenda-passes'] .quand", text: /jeudi 24 septembre 2026 · 9h30/
  end

  test "page : un direct en cours reste à venir, marqué en direct, même après sa fin prévue" do
    late = publish(title: "Direct prolongé", starts_at: 3.hours.ago, state: "live")

    get agenda_path

    assert_select "section[data-role='agenda-mois'] li.est-accent", text: /en direct/ do
      assert_select "a[href=?]", public_webinar_path(slug: late.slug)
    end
  end

  test "page : un direct non lancé reste à venir pendant la fenêtre de retard de l'accueil, pas au-delà" do
    waiting = publish(title: "Café en retard", starts_at: 2.hours.ago)
    abandoned = publish(title: "Café jamais lancé", starts_at: 4.hours.ago)

    get agenda_path

    assert_select "section[data-role='agenda-mois'] a[href=?]", public_webinar_path(slug: waiting.slug)
    assert_select "[data-role='agenda-passes'] a[href=?]", public_webinar_path(slug: abandoned.slug)
  end

  test "page : plus de lien d'abonnement public, l'inscription donne le lien personnel" do
    get agenda_path

    assert_select "section#inscription[data-role='agenda-inscription']" do
      assert_select "h2", text: "Toutes les dates dans votre agenda"
      assert_select "p", text: /\AInscrivez-vous à un webinaire : vous recevrez par mail votre lien d'agenda personnel, mis à jour à chaque nouvelle date\./
    end
    assert_select "a[href*='agenda.ics'], a[href^='webcal:'], input[data-role='agenda-flux']", count: 0
    assert_select "head link[type='text/calendar']", count: 0
  end

  test "page : état vide qui rappelle le flux personnel" do
    Webinar.where.not(id: @past.id).destroy_all

    get agenda_path

    assert_select "[data-role='agenda-vide']", text: /Aucune date à venir/
    assert_select "[data-role='agenda-vide']", text: /Déjà inscrit·e \?/
    assert_select "section[data-role='agenda-mois']", count: 0
  end

  test "page : publique, sans contrôle animateur, servie à un navigateur ancien" do
    get agenda_path, headers: { "User-Agent" => OLD_CHROME_UA }

    assert_response :success
    assert_select ".chrome-bas-centre > *", count: 0
    assert_select ".chrome-bas-droite > *", count: 0
  end

  test "page en anglais : dates rendues avec les formats EN" do
    get agenda_path(locale: "en")

    assert_response :success
    assert_select "section[data-role='agenda-mois'] h2", text: "November 2026"
    assert_select "section[data-role='agenda-mois'] .quand", text: /Thursday November 5 · 18:00/
  end

  test "l'accueil renvoie vers l'agenda" do
    get root_path
    assert_select "a[data-role='catalogue-agenda'][href=?]", agenda_path
  end

  # ---- Bouton « Ajouter à mon agenda » de la page publique ---------------

  test "page publique d'un webinaire à venir : .ics unitaire et Google Agenda prérempli" do
    get public_webinar_path(slug: @november.slug)

    assert_select "[data-role='add-to-calendar']" do
      assert_select "a[data-role='add-to-calendar-ics'][href=?]", "/w/#{@november.slug}.ics", text: "Ajouter à mon agenda"
      google = css_select("a[data-role='add-to-calendar-google']").sole["href"]
      query = Rack::Utils.parse_query(URI(google).query)
      assert_equal "TEMPLATE", query["action"]
      assert_equal "Café IA de novembre", query["text"]
      assert_equal "20261105T170000Z/20261105T180000Z", query["dates"]
      assert_equal "Café IA · Gratuit\n\nPage du webinaire : http://www.example.com/w/#{@november.slug}", query["details"]
      assert_equal "http://www.example.com/w/#{@november.slug}", query["location"]
      assert_select "a[href=?]", agenda_path
    end
  end

  test "page publique d'un brouillon jamais lancé au-delà de la fenêtre de retard : pas de bouton" do
    abandoned = publish(title: "Café jamais lancé", starts_at: 4.hours.ago)

    get public_webinar_path(slug: abandoned.slug)

    assert_select "[data-role='pre-live']"
    assert_select "[data-role='add-to-calendar']", count: 0
  end

  test "aperçu animateur d'un brouillon : pas de bouton (son .ics répondrait 404)" do
    owner = User.create!(email: "marc@example.com", oidc_sub: "sub-marc")
    sign_in_as(owner)

    get public_webinar_path(slug: @draft.slug)

    assert_response :success
    assert_select "[data-role='pre-live']"
    assert_select "[data-role='add-to-calendar']", count: 0
  end
end
