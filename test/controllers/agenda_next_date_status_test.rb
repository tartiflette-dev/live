require "test_helper"

# Champ `date_status` ajouté à /agenda/next.json (ajout compatible du contrat,
# docs/agenda.md) : « confirmed » quand tous les animateurs sont présents pour
# la date actuelle (propriétaire présumé présent : un café sans co-animateur
# l'est d'office), « to_confirm » sinon ; un direct en cours est « confirmed ».
class AgendaNextDateStatusTest < ActionDispatch::IntegrationTest
  setup do
    owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    @confirmed = Webinar.create!(title: "Confirmé", starts_at: 2.days.from_now, host_sub: owner.oidc_sub, visibility: "published")
    @pending = Webinar.create!(title: "À confirmer", starts_at: 3.days.from_now, host_sub: owner.oidc_sub, visibility: "published")
    @pending.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: owner.oidc_sub)
    @live = Webinar.create!(title: "En direct", starts_at: 10.minutes.ago, state: "live", host_sub: owner.oidc_sub, visibility: "published")
  end

  test "un statut par date, sans requête par webinaire" do
    queries = count_queries { get agenda_next_path }

    statuses = response.parsed_body["webinars"].to_h { |webinar| [ webinar["slug"], webinar["date_status"] ] }
    assert_equal({ @live.slug => "confirmed", @confirmed.slug => "confirmed", @pending.slug => "to_confirm" }, statuses)

    more = Webinar.create!(title: "Encore", starts_at: 4.days.from_now, host_sub: "sub-owner", visibility: "published")
    more.webinar_hosts.create!(email: "paul@partenaire.example.org", invited_by_sub: "sub-owner")
    assert_equal queries, count_queries { get agenda_next_path(limit: 4) }, "préchargé : pas de N+1"
  end

  test "/agenda : le statut s'affiche sans requête par webinaire" do
    queries = count_queries { get agenda_path }
    Webinar.create!(title: "Encore", starts_at: 4.days.from_now, host_sub: "sub-owner", visibility: "published")
      .webinar_hosts.create!(email: "paul@partenaire.example.org", invited_by_sub: "sub-owner")

    assert_equal queries, count_queries { get agenda_path }
    assert_select "[data-role='date-status']", count: 3
  end

  private

  def count_queries(&block)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end
end
