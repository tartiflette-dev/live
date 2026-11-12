require "test_helper"

# Rôle spectateur : un compte Pocket ID n'anime que par le groupe des
# animateurs, la propriété d'un webinaire ou une invitation de co-animateur.
class UserAnimateurTest < ActiveSupport::TestCase
  setup do
    @webinar = Webinar.create!(title: "Café", starts_at: 1.day.from_now, host_sub: "sub-proprio")
  end

  test "compte sans groupe ni webinaire : spectateur" do
    assert_not User.create!(email: "a@example.test", oidc_sub: "sub-a").animateur?
  end

  test "groupe spectateurs, ou groupe inconnu : spectateur" do
    %w[live-spectateurs live-invites autre].each_with_index do |group, index|
      user = User.create!(email: "s#{index}@example.test", oidc_sub: "sub-s#{index}",
                          oidc_groups: [ group ], oidc_groups_fetched_at: Time.current)
      assert_not user.animateur?, group
    end
  end

  test "groupe des animateurs, encore frais : animateur ; périmé : spectateur" do
    user = User.create!(email: "anim@example.test", oidc_sub: "sub-anim",
                        oidc_groups: [ "live-animateurs" ], oidc_groups_fetched_at: Time.current)
    assert user.animateur?

    user.update!(oidc_groups_fetched_at: 13.hours.ago)
    assert_not user.animateur?
  end

  test "propriétaire d'un webinaire : animateur" do
    assert User.create!(email: "proprio@example.test", oidc_sub: "sub-proprio").animateur?
  end

  test "co-animateur invité à l'adresse vérifiée : animateur ; adresse non vérifiée : spectateur" do
    @webinar.webinar_hosts.create!(email: "co@example.test", invited_by_sub: "sub-proprio")
    user = User.create!(email: "co@example.test", oidc_sub: "sub-co")
    assert_not user.animateur?

    user.update!(email_verified: true, email_verified_for: "co@example.test")
    assert user.animateur?
  end

  test "admin : animateur" do
    assert User.create!(email: "admin@example.test", oidc_sub: "sub-admin", admin: true).animateur?
  end
end
