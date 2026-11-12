require "test_helper"

# Lien animateur : jeton, expiration, usages,
# révocation, lien d'inscription Pocket ID, acceptation.
class HostInvitationTest < ActiveSupport::TestCase
  setup do
    @webinar = Webinar.create!(title: "Café IA", starts_at: 2.days.from_now, host_sub: "sub-owner")
    @guest = verified_user("jean@partenaire.example.org", "sub-jean")
  end

  test "jeton opaque urlsafe de 32 caractères, distinct d'une invitation à l'autre" do
    first = create_invitation
    second = create_invitation

    assert_match(/\A[A-Za-z0-9_-]{32}\z/, first.token)
    assert_not_equal first.token, second.token
  end

  test "le jeton et le lien d'inscription sont masqués à l'inspection" do
    invitation = create_invitation(signup_url: "https://id.example.test/st/secret-signup")

    assert_no_match(/#{invitation.token}/, invitation.inspect)
    assert_no_match(/secret-signup/, invitation.inspect)
  end

  test "find_by_token retrouve l'invitation, refuse le reste" do
    invitation = create_invitation

    assert_equal invitation, HostInvitation.find_by_token(invitation.token)
    assert_nil HostInvitation.find_by_token("#{invitation.token}x")
    assert_nil HostInvitation.find_by_token("")
    assert_nil HostInvitation.find_by_token(nil)
    assert_nil HostInvitation.find_by_token([ invitation.token ])
  end

  test "usages par défaut : 3" do
    assert_equal 3, create_invitation.max_uses
  end

  test "usages bornés de 1 à 20" do
    assert_not build_invitation(max_uses: 0).valid?
    assert_not build_invitation(max_uses: 21).valid?
    assert_not build_invitation(max_uses: 2.5).valid?
    assert build_invitation(max_uses: 1).valid?
    assert build_invitation(max_uses: 20).valid?
  end

  test "expiration par défaut : lendemain de la fin prévue du webinaire" do
    freeze_time do
      invitation = create_invitation

      assert_equal @webinar.starts_at + 1.hour + 1.day, invitation.expires_at
    end
  end

  test "expiration par défaut plafonnée à 7 jours quand le webinaire est plus loin" do
    freeze_time do
      @webinar.update!(starts_at: 30.days.from_now)

      assert_equal 7.days.from_now, create_invitation.expires_at
    end
  end

  test "une expiration explicite est gardée, et doit être dans le futur" do
    at = 3.days.from_now.change(usec: 0)

    assert_equal at, create_invitation(expires_at: at).expires_at
    past = build_invitation(expires_at: 1.minute.ago)
    assert_not past.valid?
    assert past.errors.of_kind?(:expires_at, :not_in_future)
  end

  test "expiration choisie : 30 jours au plus après la création" do
    freeze_time do
      assert build_invitation(expires_at: 30.days.from_now).valid?
      too_far = build_invitation(expires_at: 30.days.from_now + 1.minute)
      assert_not too_far.valid?
      assert too_far.errors.of_kind?(:expires_at, :too_far)
    end
  end

  test "repousser l'expiration d'un lien existant reste borné à 30 jours après sa création" do
    invitation = create_invitation

    travel 10.days do
      invitation.expires_at = invitation.created_at + 30.days + 1.minute
      assert_not invitation.valid?
      assert invitation.errors.of_kind?(:expires_at, :too_far)
    end
  end

  test "statut : actif, expiré, épuisé, révoqué" do
    invitation = create_invitation(max_uses: 1)
    assert_equal :active, invitation.status
    assert invitation.usable?

    travel_to(invitation.expires_at + 1.second) { assert_equal :expired, invitation.status }

    invitation.update_columns(uses_count: 1)
    assert_equal :exhausted, invitation.status
    assert_equal 0, invitation.remaining_uses

    invitation.revoke!
    assert_equal :revoked, invitation.status
    assert_not invitation.usable?
  end

  test "revoke! est idempotent : l'horodatage de la première révocation reste" do
    invitation = create_invitation
    invitation.revoke!
    first = invitation.reload.revoked_at

    travel 1.minute do
      invitation.revoke!
    end
    assert_equal first, invitation.reload.revoked_at
  end

  test "lien d'inscription : seul un lien vers l'émetteur Pocket ID est accepté" do
    assert build_invitation(signup_url: "https://id.example.test/st/abc123").valid?
    assert build_invitation(signup_url: "  https://ID.example.test/st/abc123  ").valid?
    assert build_invitation(signup_url: "").valid?

    [
      "https://evil.example/st/abc",
      "http://id.example.test/st/abc",
      "https://id.example.test.evil.example/st/abc",
      "https://evil.example@id.example.test/st/abc",
      "https://id.example.test:8443/st/abc",
      "javascript:alert(1)",
      "id.example.test/st/abc",
      "https://id.example.test/st/ abc"
    ].each do |url|
      invitation = build_invitation(signup_url: url)
      assert_not invitation.valid?, "#{url} devrait être refusé"
      assert invitation.errors.of_kind?(:signup_url, :not_pocket_id)
    end
  end

  test "révoquer reste possible après un changement d'OIDC_ISSUER ou une fois expiré" do
    with_signup = create_invitation(signup_url: "https://id.example.test/st/abc123")
    expired = create_invitation.tap { |invitation| invitation.update_columns(expires_at: 1.minute.ago) }
    previous = ENV["OIDC_ISSUER"]
    ENV["OIDC_ISSUER"] = "https://auth.example.test"

    [ with_signup, expired ].each do |invitation|
      invitation.revoke!
      assert_equal :revoked, invitation.reload.status
    end
    assert with_signup.valid?, "un lien déjà créé reste valide quand l'émetteur change"
  ensure
    ENV["OIDC_ISSUER"] = previous
  end

  test "lien d'inscription : l'émetteur vient d'OIDC_ISSUER" do
    previous = ENV["OIDC_ISSUER"]
    ENV["OIDC_ISSUER"] = "https://auth.example.test"

    assert build_invitation(signup_url: "https://auth.example.test/st/abc").valid?
    assert_not build_invitation(signup_url: "https://id.example.test/st/abc").valid?
  ensure
    ENV["OIDC_ISSUER"] = previous
  end

  test "lien d'inscription sans fournisseur OIDC configuré : refusé, sans erreur" do
    previous = ENV.delete("OIDC_ISSUER")

    invitation = build_invitation(signup_url: "https://auth.example.test/st/abc")
    assert_not invitation.valid?
    assert invitation.errors.of_kind?(:signup_url, :no_oidc_provider)
    assert build_invitation(signup_url: "").valid?
  ensure
    ENV["OIDC_ISSUER"] = previous
  end

  test "accept crée un co-animateur verrouillé sur le compte et consomme un usage" do
    invitation = create_invitation(created_by_sub: "sub-createur")

    assert_equal :accepted, invitation.accept(@guest)

    host = @webinar.webinar_hosts.sole
    assert_equal [ "jean@partenaire.example.org", "sub-createur", "sub-jean" ], [ host.email, host.invited_by_sub, host.claimed_sub ]
    assert_equal 1, invitation.reload.uses_count
    assert_equal :guest_host, @webinar.role_for(@guest)
  end

  test "accept : email non vérifié, rien n'est créé ni consommé" do
    unverified = User.create!(email: "paul@partenaire.example.org", oidc_sub: "sub-paul", email_verified: false)
    invitation = create_invitation

    assert_equal :email_unverified, invitation.accept(unverified)
    assert_empty @webinar.webinar_hosts
    assert_equal 0, invitation.reload.uses_count
  end

  test "accept : propriétaire et animateur du projet n'ont besoin de rien" do
    owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    admin = User.create!(email: "admin@example.net", oidc_sub: "sub-admin", admin: true)
    invitation = create_invitation

    assert_equal :already_animator, invitation.accept(owner)
    assert_equal :already_animator, invitation.accept(admin)
    assert_empty @webinar.webinar_hosts
    assert_equal 0, invitation.reload.uses_count
  end

  test "accept une seconde fois par le même compte : rien n'est consommé" do
    invitation = create_invitation
    invitation.accept(@guest)

    assert_equal :already_animator, invitation.accept(@guest)
    assert_equal 1, invitation.reload.uses_count
    assert_equal 1, @webinar.webinar_hosts.count
  end

  test "accept : une désignation par email encore libre est rattachée sans consommer" do
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: "sub-owner")
    invitation = create_invitation

    assert_equal :already_animator, invitation.accept(@guest)
    assert_equal "sub-jean", @webinar.webinar_hosts.sole.claimed_sub
    assert_equal 0, invitation.reload.uses_count
  end

  test "accept : désignation posée par un gestionnaire pendant l'acceptation, revendiquée par ce compte" do
    invitation = create_invitation
    # La désignation arrive entre la vérification des rôles et le verrou.
    @webinar.define_singleton_method(:animated_by?) do |user|
      webinar_hosts.create!(email: user.normalized_email, invited_by_sub: "sub-owner")
      false
    end

    assert_equal :already_animator, invitation.accept(@guest)
    assert_equal "sub-jean", WebinarHost.find_by!(webinar: @webinar).claimed_sub
    assert_equal 0, invitation.reload.uses_count
  end

  test "accept : une adresse liée à un autre compte reste à cet autre compte" do
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: "sub-owner", claimed_sub: "sub-ancien")
    invitation = create_invitation

    assert_equal :claimed_by_other, invitation.accept(@guest)
    assert_equal "sub-ancien", @webinar.webinar_hosts.sole.claimed_sub
    assert_equal 0, invitation.reload.uses_count
    assert_nil @webinar.role_for(@guest)
  end

  test "accept : lien révoqué, expiré ou épuisé, rien n'est créé" do
    revoked = create_invitation.tap(&:revoke!)
    exhausted = create_invitation(max_uses: 1).tap { |invitation| invitation.update_columns(uses_count: 1) }
    expired = create_invitation.tap { |invitation| invitation.update_columns(expires_at: 1.minute.ago) }

    [ revoked, exhausted, expired ].each do |invitation|
      assert_equal :unusable, invitation.accept(@guest)
    end
    assert_empty @webinar.webinar_hosts
  end

  test "après la fin du webinaire : le lien ne s'accepte plus, statut ended" do
    invitation = create_invitation
    @webinar.update!(state: "ended", ended_at: Time.current)

    assert_equal :ended, invitation.status
    assert_not invitation.usable?
    assert_equal :unusable, invitation.accept(@guest)
    assert_empty @webinar.webinar_hosts
  end

  test "la base refuse un dépassement des usages écrit hors du verrou" do
    invitation = create_invitation(max_uses: 1)

    assert_raises(ActiveRecord::StatementInvalid) { invitation.update_columns(uses_count: 2) }
  end

  test "supprimer le webinaire supprime ses liens animateur" do
    create_invitation

    assert_difference -> { HostInvitation.count }, -1 do
      @webinar.destroy!
    end
  end

  private

  def build_invitation(**attributes)
    @webinar.host_invitations.build({ created_by_sub: "sub-owner" }.merge(attributes))
  end

  def create_invitation(**attributes)
    build_invitation(**attributes).tap(&:save!)
  end

  def verified_user(email, sub)
    User.create!(email: email, oidc_sub: sub, email_verified: true, email_verified_for: email)
  end
end
