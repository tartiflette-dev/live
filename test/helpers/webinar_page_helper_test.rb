# frozen_string_literal: true

require "test_helper"

# Page d'un webinaire rangée par moment : état en français
# et bouton principal selon le moment.
class WebinarPageHelperTest < ActionView::TestCase
  setup do
    @owner = User.create!(email: "owner@example.test", oidc_sub: "helper-owner")
    @guest = User.create!(email: "jean@partenaire.test", oidc_sub: "helper-guest",
                          email_verified: true, email_verified_for: "jean@partenaire.test")
  end

  test "état en français : Brouillon, Programmé, En direct, Terminé" do
    expected = { [ "draft", "draft" ] => "Brouillon", [ "draft", "published" ] => "Programmé",
                 [ "live", "published" ] => "En direct", [ "ended", "published" ] => "Terminé" }
    expected.each do |(state, visibility), label|
      render html: webinar_state_badge(webinar(state: state, visibility: visibility))
      assert_select "span.etat[data-role='webinar-state']", text: label
    end
  end

  test "bouton principal : avant le lien public, pendant la régie, après les vidéos puis les enregistrements" do
    assert_equal :copy_public_link, webinar_primary_action(webinar(state: "draft"), @owner, videos_to_review: false)
    assert_equal :regie, webinar_primary_action(webinar(state: "live"), @owner, videos_to_review: false)
    assert_equal :review_videos, webinar_primary_action(webinar(state: "ended"), @owner, videos_to_review: true)
    assert_equal :recordings, webinar_primary_action(webinar(state: "ended"), @owner, videos_to_review: false)
  end

  test "après le direct, un co-animateur invité n'a pas de bouton principal" do
    ended = webinar(state: "ended")
    ended.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)

    assert_nil webinar_primary_action(ended, @guest, videos_to_review: false)
  end

  test "classe d'une action : principale ou secondaire" do
    assert_equal "btn", webinar_action_class(:regie, :regie)
    assert_equal "btn btn--secondary", webinar_action_class(:regie, :recordings)
    assert_equal "btn btn--secondary", webinar_action_class(nil, :regie)
  end

  private

  def webinar(state:, visibility: "published")
    Webinar.create!(title: "Café", starts_at: 1.day.from_now, host_sub: @owner.oidc_sub, state: state,
                    visibility: visibility, started_at: (Time.current unless state == "draft"),
                    ended_at: (Time.current if state == "ended"))
  end
end
