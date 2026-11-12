require "test_helper"

# Édition par le propriétaire (Webinar::Edition) : une seule écriture, dans le
# contexte `:edition`, refusée dès que le direct a commencé.
class WebinarEditionTest < ActiveSupport::TestCase
  setup do
    travel_to Time.zone.local(2026, 11, 10, 10, 0)
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: Time.zone.local(2026, 11, 12, 18, 0),
                               host_sub: "sub-owner", visibility: "published")
  end

  test "revise déplace la date, change titre et description" do
    assert @webinar.revise(title: "Café IA #9 bis", description: "Nouvel ordre du jour",
                           starts_at: "2026-11-13T19:30")

    @webinar.reload
    assert_equal Time.zone.local(2026, 11, 13, 19, 30), @webinar.starts_at
    assert_equal "Café IA #9 bis", @webinar.title
    assert_equal "Nouvel ordre du jour", @webinar.description
  end

  test "revise refuse une date passée ou illisible sans rien écrire" do
    assert_not @webinar.revise(starts_at: "2026-11-09T18:00")
    assert @webinar.errors.of_kind?(:starts_at, :too_soon)

    # Une requête = une instance : le formulaire refusé garde la saisie.
    assert_not @webinar.reload.revise(starts_at: "pas une date")
    assert @webinar.errors.of_kind?(:starts_at, :blank)

    assert_equal Time.zone.local(2026, 11, 12, 18, 0), @webinar.reload.starts_at
  end

  test "une nouvelle date est au moins INSTANT_ACCESS_LEAD après maintenant" do
    assert_equal 15.minutes, Webinar::INSTANT_ACCESS_LEAD

    assert_not @webinar.revise(starts_at: Time.zone.local(2026, 11, 10, 10, 14, 59))
    assert_includes @webinar.errors[:starts_at], "doit être au moins 15 minutes après maintenant"

    assert @webinar.reload.revise(starts_at: Time.zone.local(2026, 11, 10, 10, 15))
    assert_equal Time.zone.local(2026, 11, 10, 10, 15), @webinar.reload.starts_at
  end

  test "café imminent : annulation et correction du titre restent possibles" do
    soon = Webinar.create!(title: "Dans 5 min", starts_at: 5.minutes.from_now, host_sub: "sub-owner",
                           visibility: "published")

    assert soon.editable?
    assert soon.revise(title: "Dans 5 min, corrigé", starts_at: soon.starts_at.change(usec: 0))
    assert_not soon.revise(starts_at: 10.minutes.from_now)
    assert soon.reload.unpublish
    assert soon.reload.visibility_draft?
  end

  test "revise refuse un webinaire commencé, en direct ou passé" do
    late = Webinar.create!(title: "En retard", starts_at: 10.minutes.ago, host_sub: "sub-owner")
    live = Webinar.create!(title: "En direct", starts_at: 1.hour.from_now, host_sub: "sub-owner",
                           state: "live", started_at: Time.current)
    ended = Webinar.create!(title: "Terminé", starts_at: 2.days.ago, host_sub: "sub-owner",
                            state: "ended", started_at: 2.days.ago, ended_at: 2.days.ago + 1.hour)

    [ late, live, ended ].each do |webinar|
      assert_not webinar.editable?, webinar.title
      assert_not webinar.revise(starts_at: 3.days.from_now), webinar.title
      assert webinar.errors.of_kind?(:base, :started), webinar.title
    end
  end

  test "une date future saisie ne rouvre pas un webinaire passé" do
    @webinar.update!(starts_at: 1.hour.ago)

    assert_not @webinar.revise(starts_at: 2.days.from_now)
    assert_in_delta 1.hour.ago, @webinar.reload.starts_at, 1.second
  end

  test "unpublish retire du catalogue ; refusé sur un brouillon ou un webinaire passé" do
    assert @webinar.unpublish
    assert @webinar.reload.visibility_draft?
    assert_not_includes Webinar.published, @webinar

    assert_not @webinar.unpublish
    assert @webinar.errors.of_kind?(:visibility, :not_published)

    past = Webinar.create!(title: "Passé", starts_at: 1.hour.ago, host_sub: "sub-owner", visibility: "published")
    assert_not past.unpublish
    assert past.reload.visibility_published?
  end

  test "les règles d'édition ne pèsent pas sur les autres écritures" do
    @webinar.update!(starts_at: 1.hour.ago)
    assert @webinar.go_live!
  end

  test "registrations_to_notify : confirmées, jamais retirées de la salle" do
    confirmed = @webinar.registrations.create!(name: "Alice", email: "alice@example.com", confirmed_at: 1.hour.ago)
    @webinar.registrations.create!(name: "Bob", email: "bob@example.com")
    @webinar.registrations.create!(name: "Carol", email: "carol@example.com", confirmed_at: 1.hour.ago,
                                   room_removed_at: 5.minutes.ago)

    assert_equal [ confirmed ], @webinar.registrations_to_notify.to_a
  end
end
