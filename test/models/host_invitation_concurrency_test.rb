require "test_helper"

# Lien animateur : acceptations simultanées (vrais threads, vraies connexions
# SQLite, sans transaction de test). Le verrou de l'invitation sérialise le
# contrôle des usages et leur incrément : jamais plus de `max_uses`
# co-animateurs, même quand tout le monde clique en même temps.
class HostInvitationConcurrencyTest < ActiveSupport::TestCase
  include ConcurrentOperations

  self.use_transactional_tests = false

  setup do
    suffix = SecureRandom.hex(6)
    @webinar = Webinar.create!(title: "Concurrence #{suffix}", starts_at: 1.day.from_now, host_sub: "sub-owner-#{suffix}")
    @invitation = @webinar.host_invitations.create!(created_by_sub: @webinar.host_sub, max_uses: 2)
    @users = Array.new(5) do |index|
      email = "invite-#{index}-#{suffix}@partenaire.example.org"
      User.create!(email: email, oidc_sub: "sub-#{index}-#{suffix}", email_verified: true, email_verified_for: email)
    end
  end

  teardown do
    WebinarHost.where(webinar_id: @webinar.id).delete_all
    HostInvitation.where(webinar_id: @webinar.id).delete_all
    User.where(id: @users.map(&:id)).delete_all
    @webinar.reload.destroy!
  end

  test "cinq acceptations simultanées d'un lien à deux usages : deux co-animateurs, pas un de plus" do
    outcomes = concurrently(*@users.map { |user| -> { HostInvitation.find(@invitation.id).accept(user) } })

    assert outcomes.none? { |outcome| outcome.is_a?(Exception) }, outcomes.inspect
    assert_equal 2, outcomes.count(:accepted), outcomes.inspect
    assert_equal 3, outcomes.count(:unusable), outcomes.inspect
    assert_equal 2, @invitation.reload.uses_count
    assert_equal 2, @webinar.webinar_hosts.count
  end

  test "le même compte accepte deux fois en même temps : un seul co-animateur, un seul usage" do
    user = @users.first
    outcomes = concurrently(-> { HostInvitation.find(@invitation.id).accept(user) },
                            -> { HostInvitation.find(@invitation.id).accept(user) })

    assert_equal %i[accepted already_animator], outcomes.sort, outcomes.inspect
    assert_equal 1, @invitation.reload.uses_count
    assert_equal 1, @webinar.webinar_hosts.count
  end
end
