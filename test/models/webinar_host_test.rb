require "test_helper"

class WebinarHostTest < ActiveSupport::TestCase
  setup do
    @webinar = Webinar.create!(title: "demo", starts_at: 1.day.from_now, host_sub: "sub-owner")
  end

  test "normalise l'email en downcase + strip" do
    host = @webinar.webinar_hosts.create!(email: "  Jean.DUPONT@partenaire.example.org ", invited_by_sub: "sub-owner")
    assert_equal "jean.dupont@partenaire.example.org", host.email
  end

  test "unicite case-insensitive par webinaire" do
    @webinar.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: "sub-owner")
    dup = @webinar.webinar_hosts.build(email: "JEAN@partenaire.example.org", invited_by_sub: "sub-owner")
    assert_not dup.valid?
    assert dup.errors.of_kind?(:email, :taken)
  end

  test "email requis et formate" do
    host = @webinar.webinar_hosts.build(email: "pas-un-email", invited_by_sub: "sub-owner")
    assert_not host.valid?
    assert host.errors.of_kind?(:email, :invalid)
  end

  test "invited_by_sub requis" do
    host = @webinar.webinar_hosts.build(email: "jean@partenaire.example.org", invited_by_sub: nil)
    assert_not host.valid?
    assert host.errors.of_kind?(:invited_by_sub, :blank)
  end

  test "destroy webinaire supprime les co-animateurs" do
    @webinar.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: "sub-owner")
    @webinar.webinar_hosts.create!(email: "paul@partenaire.example.org", invited_by_sub: "sub-owner")
    assert_difference -> { WebinarHost.count }, -2 do
      @webinar.destroy!
    end
  end
end
