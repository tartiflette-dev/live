require "test_helper"

# Matrice d'élévation des co-animateurs.
#
# Un `guest_host` peut ANIMER (scène, go_live, mains levées, start/stop
# du composite) mais ne doit PAS avoir accès aux PII (inscrits),
# archives (enregistrements, transcripts), intervenants, ou gestion
# des co-animateurs. 404 systématique (défense énumération, cohérent
# avec le reste de l'app).
class CoAnimateursElevationTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers
  setup do
    @owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner", email_verified: true, email_verified_for: "owner@example.net")
    @guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean", email_verified: true, email_verified_for: "jean@partenaire.example.org")
    @webinar = Webinar.create!(
      title: "demo", starts_at: 1.day.from_now, host_sub: @owner.oidc_sub, visibility: "published"
    )
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
    @speaker = @webinar.speakers.create!(name: "Basile")
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  # ---- Autorisé : scène et direct ----

  test "guest_host voit la scene" do
    sign_in_as(@guest)
    get stage_webinar_path(slug: @webinar.slug)
    assert_response :success
  end

  test "guest_host demarre et termine le direct" do
    sign_in_as(@guest)
    post go_live_webinar_path(@webinar.slug)
    assert_response :redirect
    assert_equal "live", @webinar.reload.state

    post end_webinar_path(@webinar.slug)
    assert_response :redirect
    assert_equal "ended", @webinar.reload.state
  end

  test "guest_host voit la page webinaire (role_badge affiche co-animateur)" do
    sign_in_as(@guest)
    get webinar_path(@webinar)
    assert_response :success
    assert_match(/Co-animateur invit/, response.body)
  end

  # ---- Refusé : inscrits, enregistrements, transcripts, intervenants ----

  test "guest_host n_accede_pas_aux_inscrits" do
    sign_in_as(@guest)
    get webinar_registrations_path(@webinar)
    assert_response :not_found
  end

  test "guest_host n_accede_pas_aux_enregistrements_index" do
    sign_in_as(@guest)
    get webinar_recordings_path(@webinar)
    assert_response :not_found
  end

  test "guest_host n_accede_pas_au_transcript_txt" do
    sign_in_as(@guest)
    get transcript_webinar_recordings_path(@webinar)
    assert_response :not_found
  end

  test "guest_host n_ajoute_pas_d_intervenant" do
    sign_in_as(@guest)
    assert_no_difference -> { Speaker.count } do
      post webinar_speakers_path(@webinar), params: { speaker: { name: "Bob" } }
    end
    assert_response :not_found
  end

  test "guest_host n_accede_pas_au_share_link_intervenants" do
    sign_in_as(@guest)
    # POST (générer / régénérer)
    assert_no_changes -> { @webinar.reload.share_token } do
      post webinar_share_link_path(@webinar)
    end
    assert_response :not_found
    # DELETE (désactiver)
    delete webinar_share_link_path(@webinar)
    assert_response :not_found
  end

  test "guest_host n_ajoute_pas_de_coanimateur" do
    sign_in_as(@guest)
    assert_no_difference -> { WebinarHost.count } do
      post webinar_hosts_path(@webinar), params: { webinar_host: { email: "autre@example.net" } }
    end
    assert_response :not_found
  end

  test "guest_host ne crée pas de webinaire" do
    sign_in_as(@guest)
    get new_webinar_path
    assert_response :not_found

    assert_no_difference -> { Webinar.count } do
      post webinars_path, params: { webinar: { title: "pirate", starts_at: 1.day.from_now } }
    end
    assert_response :not_found
  end

  test "guest_host voit uniquement ses webinaires animés dans l_index" do
    _solo = Webinar.create!(title: "pas pour jean", starts_at: 1.day.from_now, host_sub: @owner.oidc_sub)
    sign_in_as(@guest)
    get webinars_path
    assert_response :success
    assert_includes response.body, @webinar.title
    assert_not_includes response.body, "pas pour jean"
  end

  # ---- Email NON vérifié : aucune élévation (broken-authentication) ----

  test "guest_sans_email_verified_ne_recoit_aucune_elevation" do
    unverified = User.create!(email: "pierre@partenaire.example.org", oidc_sub: "sub-pierre", email_verified: false)
    @webinar.webinar_hosts.create!(email: unverified.email, invited_by_sub: @owner.oidc_sub)
    sign_in_as(unverified, email_verified: false)

    # Scène : 404 (le find_by! sur `where_animated_by` refuse l'invité
    # non vérifié, puisque son `role_for` retourne nil).
    get stage_webinar_path(slug: @webinar.slug)
    assert_response :not_found

    # Mains levées / direct : 404 également.
    post go_live_webinar_path(@webinar.slug)
    assert_response :not_found
  end

  test "callback_email_verified_absent_pose_false_et_bloque_role" do
    # OIDC émet le callback sans aucun claim email_verified → User créé
    # avec `email_verified = false` → aucun :guest_host accordé.
    sans_claim = User.create!(email: "sans-claim@partenaire.example.org", oidc_sub: "sub-sc", email_verified: false)
    @webinar.webinar_hosts.create!(email: sans_claim.email, invited_by_sub: @owner.oidc_sub)
    # Signe-in sans transmettre email_verified
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id",
      uid: sans_claim.oidc_sub,
      info: { email: sans_claim.email }
    )
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:pocket_id]
    get "/auth/pocket_id/callback"
    Rails.application.env_config.delete("omniauth.auth")

    assert_equal false, sans_claim.reload.email_verified
    get stage_webinar_path(slug: @webinar.slug)
    assert_response :not_found
  end

  # ---- Révocation immédiate (stale-authorization §2a) ----

  test "revocation_coupe_les_droits_immediatement_au_prochain_hit" do
    # Le co-animateur a une session Pocket ID OUVERTE. On supprime son
    # WebinarHost. Sa requête suivante doit répondre 404 (défense
    # stale-authorization) — même avant la fin de
    # la fenêtre de session.
    sign_in_as(@guest)
    get stage_webinar_path(slug: @webinar.slug)
    assert_response :success

    # Suppression admin.
    @webinar.webinar_hosts.find_by!(email: @guest.email).destroy!

    # Prochain hit du MÊME browser (session cookie conservé).
    get stage_webinar_path(slug: @webinar.slug)
    assert_response :not_found

    post go_live_webinar_path(@webinar.slug)
    assert_response :not_found
  end

  # ---- Un spectateur ou intervenant ne devient JAMAIS animateur ----

  test "spectateur_meme_inscrit_ne_devient_pas_animateur" do
    # Un visiteur anonyme (pas de session Pocket ID) n'a aucun droit
    # d'animation ; stage/go_live redirigent vers sign_in.
    get stage_webinar_path(slug: @webinar.slug)
    assert_redirected_to sign_in_path

    post go_live_webinar_path(@webinar.slug)
    assert_redirected_to sign_in_path
  end

  test "session_expiree_bloque_les_droits_projet" do
    # Défense fail-open-state-drift : au-delà de la fenêtre
    # `LIVE_SESSION_MAX_AGE_SECONDS`, la session est purgée au prochain
    # hit — current_user retourne nil → authentication requise.
    admin = User.create!(email: "admin@example.net", oidc_sub: "sub-admin", admin: true,
                         oidc_groups: [ "live-animateurs" ], oidc_groups_fetched_at: Time.current)
    ENV["LIVE_SESSION_MAX_AGE_SECONDS"] = "60" # 1 min
    sign_in_as(admin)
    get webinars_path
    assert_response :success

    travel 2.minutes do
      get webinars_path
      assert_redirected_to sign_in_path
    end
  ensure
    ENV.delete("LIVE_SESSION_MAX_AGE_SECONDS")
  end

  test "session_fraiche_reste_valide_dans_la_fenetre" do
    admin = User.create!(email: "admin@example.net", oidc_sub: "sub-admin", admin: true)
    ENV["LIVE_SESSION_MAX_AGE_SECONDS"] = "3600" # 1 h
    sign_in_as(admin)
    travel 30.minutes do
      get webinars_path
      assert_response :success
    end
  ensure
    ENV.delete("LIVE_SESSION_MAX_AGE_SECONDS")
  end

  test "intervenant_sur_le_lien_signe_ne_devient_pas_animateur" do
    # Un intervenant qui GET /join reçoit la room en speaker, mais SANS
    # session Pocket ID il ne peut toucher à stage/go_live/end.
    speaker = @webinar.speakers.create!(name: "Intervenant")
    get join_webinar_path(slug: @webinar.slug, t: speaker.token)
    assert_response :success # /join = page publique via token

    get stage_webinar_path(slug: @webinar.slug)
    assert_redirected_to sign_in_path

    post go_live_webinar_path(@webinar.slug)
    assert_redirected_to sign_in_path
  end

  private

  # Helper OIDC enrichi : `email_verified` et `groups`
  # transmis comme claims OIDC. Par défaut `email_verified: true` →
  # les tests existants qui exercent le chemin « invité » restent au
  # vert sans toucher à chaque appel.
  def sign_in_as(user, email_verified: true, groups: nil)
    OmniAuth.config.test_mode = true
    info = { email: user.email, email_verified: email_verified }
    raw_info = { email_verified: email_verified }
    raw_info[:groups] = groups if groups
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id",
      uid: user.oidc_sub,
      info: info,
      extra: { raw_info: raw_info }
    )
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:pocket_id]
    get "/auth/pocket_id/callback"
    Rails.application.env_config.delete("omniauth.auth")
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end
end
