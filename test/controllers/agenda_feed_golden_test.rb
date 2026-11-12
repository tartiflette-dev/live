require "test_helper"

# Non-régression du flux d'abonnement sans paramètre — aujourd'hui le flux
# personnel /agenda/<jeton>.ics, qui reprend la sérialisation de l'ancien flux
# public /agenda.ics : octets attendus figés dans
# test/fixtures/files/agenda_feed.ics, produits par le flux public d'origine
# (avant le filtre `kind`). Les agendas abonnés comparent
# ce flux à chaque rafraîchissement : toute dérive (pliage, échappement,
# DTSTAMP, SEQUENCE, nom du calendrier) doit être un choix, pas un accident.
# UID_DOMAIN suit APP_HOST : le fichier suppose la valeur par défaut.
class AgendaFeedGoldenTest < ActionDispatch::IntegrationTest
  GOLDEN = Rails.root.join("test/fixtures/files/agenda_feed.ics")

  setup do
    travel_to Time.zone.local(2026, 10, 1, 9, 0)
    base = { host_sub: "sub-marc", visibility: "published", kind: "cafe_ia" }
    pack = Pack.create!(name: "Parcours agents", price_cents: 29_900, host_sub: "sub-marc")

    Webinar.create!(base.merge(slug: "cafe-ia-septembre", title: "Café IA de septembre", state: "ended",
                               starts_at: Time.zone.local(2026, 9, 24, 9, 30)))
    november = Webinar.create!(base.merge(
      slug: "cafe-ia-novembre", title: "Café IA de novembre ; virgules, et points-virgules",
      starts_at: Time.zone.local(2026, 11, 5, 18, 0),
      description: "<p>Une heure pour <strong>apprivoiser</strong> les agents.</p>" \
                   "<p>Questions en direct, replay ensuite. #{"Texte long pour forcer le pliage à 75 octets. " * 3}</p>"
    ))
    Webinar.create!(base.merge(slug: "bootcamp-decembre", title: "Bootcamp de décembre", kind: "bootcamp",
                               price_cents: 9900, starts_at: Time.zone.local(2026, 12, 3, 9, 30)))
    Webinar.create!(base.merge(slug: "bootcamp-pack", title: "Bootcamp du parcours", kind: "bootcamp",
                               pack: pack, starts_at: Time.zone.local(2027, 1, 14, 9, 30)))
    Webinar.create!(slug: "brouillon", title: "Brouillon non annoncé", host_sub: "sub-marc",
                    visibility: "draft", starts_at: Time.zone.local(2026, 11, 12, 18, 0))

    travel 2.days
    november.update!(starts_at: Time.zone.local(2026, 11, 5, 18, 30))
    @subscription = CalendarSubscription.create!(email: "abonnee@example.test")
  end

  test "flux personnel sans paramètre : octets identiques au flux de référence" do
    require_undust_theme!
    get personal_agenda_path(@subscription.token, format: :ics)

    assert_response :success
    assert_equal GOLDEN.binread, response.body.b
  end
end
