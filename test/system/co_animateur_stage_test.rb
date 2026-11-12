require "application_system_test_case"

# Un co-animateur connecté voit la scène ; le bouton
# d'état est dans la régie.
class CoAnimateurStageTest < JsSystemTestCase
  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  setup do
    @owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    @guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean")
    @webinar = Webinar.create!(
      title: "Co-animation",
      starts_at: 1.day.from_now,
      host_sub: @owner.oidc_sub
    )
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)

    @prev_key    = ENV["LIVEKIT_API_KEY"]
    @prev_secret = ENV["LIVEKIT_API_SECRET"]
    @prev_url    = ENV["LIVEKIT_URL"]
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
  end

  teardown do
    ENV["LIVEKIT_API_KEY"]    = @prev_key
    ENV["LIVEKIT_API_SECRET"] = @prev_secret
    ENV["LIVEKIT_URL"]        = @prev_url
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "co_animateur_connecte_voit_la_scene_et_le_bouton_d_etat_dans_la_regie" do
    sign_in_as(@guest)
    visit stage_webinar_path(slug: @webinar.slug)

    # Même salle que le propriétaire (celle des participants),
    # avec le lien vers la régie — c'est la décision serveur
    # `where_animated_by` qui autorise.
    assert_selector "#livekit-room[data-regie-url='#{webinar_regie_path(@webinar)}']", visible: :all
    assert_no_selector "#livekit-room[data-go-live-url]", visible: :all

    # Le DB a bien enregistré email_verified=true (sanity : sinon
    # `role_for` refuserait le :guest_host et ni la scène ni la régie ne
    # lui seraient ouvertes).
    assert @guest.reload.email_verified, "email_verified doit être true pour que l'invité soit résolu :guest_host"

    # Montage React : le container #livekit-room n'est PAS vide (la
    # décision serveur a bien livré un payload après POST /api/token).
    # Le rendu interne (PreJoin, barre media…) dépend de LiveKit lui-
    # même qui n'est pas joignable depuis la CI (livekit.invalid) ;
    # on vérifie côté serveur (controllers tokens_controller_test :
    # "guest_host obtient role cohost SANS roomAdmin") que le token
    # LiveKit sort bien en `cohost` avec les bons grants.
    assert_no_selector "#livekit-room:empty", wait: 15

    # Le bouton d'état est dans la régie, ouverte au co-animateur.
    visit webinar_regie_path(@webinar)
    assert_selector "[data-testid='state-button'][data-state='draft']", exact_text: "Démarrer le direct", wait: 10
  end

  private

  def sign_in_as(user, email_verified: true, groups: nil)
    OmniAuth.config.test_mode = true
    raw_info = { email_verified: email_verified }
    raw_info[:groups] = groups if groups
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id",
      uid: user.oidc_sub,
      info: { email: user.email, email_verified: email_verified },
      extra: { raw_info: raw_info }
    )
    visit "/auth/pocket_id/callback"
  end
end
