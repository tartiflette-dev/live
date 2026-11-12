require "test_helper"

class PacksControllerTest < ActionDispatch::IntegrationTest
  # Critère d'acceptation :
  # « CRUD animateur minimal /packs (index/new/create, host Pocket ID,
  #   pas de destroy) ; le formulaire webinar propose le select pack. »

  setup do
    @host  = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @other = User.create!(email: "eve@example.com", oidc_sub: "sub-eve")
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  # ---- Auth animateur (host-only) ----

  test "index redirige vers sign_in si non authentifié" do
    get packs_path
    assert_redirected_to sign_in_path
  end

  test "new redirige vers sign_in si non authentifié" do
    get new_pack_path
    assert_redirected_to sign_in_path
  end

  test "create refusé si non authentifié" do
    assert_no_difference -> { Pack.count } do
      post packs_path, params: { pack: { name: "X", price_cents: 100 } }
    end
    assert_redirected_to sign_in_path
  end

  # ---- Create ----

  test "create pose host_sub = current_user.oidc_sub" do
    sign_in_as(@host)
    assert_difference -> { Pack.count }, 1 do
      post packs_path, params: { pack: { name: "Bootcamp IA", price_cents: 49000, host_sub: "sub-attaquant" } }
    end
    assert_response :redirect
    pack = Pack.last
    assert_equal "sub-marc", pack.host_sub
    assert_equal "Bootcamp IA", pack.name
    assert_equal 49000, pack.price_cents
  end

  test "create refuse un pack invalide (422, form re-rendu)" do
    sign_in_as(@host)
    assert_no_difference -> { Pack.count } do
      post packs_path, params: { pack: { name: "", price_cents: -1 } }
    end
    assert_response :unprocessable_entity
  end

  # Comptes `live-invites` (lien animateur) : connectés sans autre rôle, ils
  # n'ont pas accès aux packs, même s'ils co-animent un webinaire.
  test "invité sans rôle : 404 sur index, new et create" do
    invite = User.create!(email: "invite@partenaire.example.org", oidc_sub: "sub-invite",
                          oidc_groups: [ "live-invites" ], oidc_groups_fetched_at: Time.current)
    webinar = Webinar.create!(title: "demo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    webinar.webinar_hosts.create!(email: invite.email, invited_by_sub: @host.oidc_sub, claimed_sub: invite.oidc_sub)
    sign_in_as(invite)

    get packs_path
    assert_response :not_found
    get new_pack_path
    assert_response :not_found
    assert_no_difference -> { Pack.count } do
      post packs_path, params: { pack: { name: "Intrus", price_cents: 100 } }
    end
    assert_response :not_found
  end

  test "propriétaire d'un webinaire, sans être animateur du projet : accès aux packs" do
    Webinar.create!(title: "Le sien", starts_at: 1.day.from_now, host_sub: @other.oidc_sub)
    sign_in_as(@other)

    get packs_path
    assert_response :success
    post packs_path, params: { pack: { name: "Pack eve", price_cents: 100 } }
    assert_redirected_to packs_path
    assert_equal @other.oidc_sub, Pack.find_by!(name: "Pack eve").host_sub
  end

  # ---- Isolation host_sub ----

  test "index n'expose PAS les packs des autres animateurs" do
    _mine  = Pack.create!(name: "Bootcamp perso", price_cents: 49000, host_sub: @host.oidc_sub)
    _other = Pack.create!(name: "Pack eve",       price_cents: 12000, host_sub: @other.oidc_sub)

    sign_in_as(@host)
    get packs_path
    assert_response :success
    assert_includes response.body, "Bootcamp perso"
    assert_not_includes response.body, "Pack eve"
  end

  # ---- NG-3 : pas de destroy ----

  test "aucune route destroy sur /packs (NG-3 spec)" do
    # `resources :packs, only: [:index, :new, :create]` n'expose ni
    # `pack_path` ni verbe DELETE. Inspecter la table de routes directement
    # (plus lisible qu'un rescue NoMethodError sur un helper absent).
    pack_routes = Rails.application.routes.routes.select do |r|
      r.path.spec.to_s.include?("/packs")
    end
    verbs = pack_routes.map { |r| r.verb }.uniq
    assert_not_includes verbs, "DELETE",
      "aucune route DELETE sur /packs (NG-3 spec)"
  end

  # ---- Formulaire webinar propose le select pack (done_when 2) ----

  test "GET /webinars/new expose select[pack_id] avec les packs du host" do
    Pack.create!(name: "Bootcamp perso", price_cents: 49000, host_sub: @host.oidc_sub)
    Pack.create!(name: "Pack eve",       price_cents: 12000, host_sub: @other.oidc_sub)

    sign_in_as(@host)
    get new_webinar_path
    assert_response :success
    assert_select "select[name='webinar[pack_id]']" do
      assert_select "option", text: "Bootcamp perso"
      assert_select "option", text: "Pack eve", count: 0
    end
  end

  # ---- POST /webinars refuse un pack d'un autre host (422) ----

  test "create webinar rejette pack_id appartenant à un autre host" do
    foreign_pack = Pack.create!(name: "Pack eve", price_cents: 12000, host_sub: @other.oidc_sub)

    sign_in_as(@host)
    assert_no_difference -> { Webinar.count } do
      post webinars_path, params: { webinar: {
        title: "Détournement", starts_at: 1.day.from_now, pack_id: foreign_pack.id
      } }
    end
    assert_response :unprocessable_entity
  end

  # ---- POST /webinars accepte un pack du host (webinar créé avec pack_id) ----

  test "create webinar accepte pack_id du host courant" do
    pack = Pack.create!(name: "Bootcamp perso", price_cents: 49000, host_sub: @host.oidc_sub)

    sign_in_as(@host)
    assert_difference -> { Webinar.count }, 1 do
      post webinars_path, params: { webinar: {
        title: "Session inaugurale", starts_at: 1.day.from_now, pack_id: pack.id
      } }
    end
    w = Webinar.last
    assert_equal pack.id, w.pack_id
  end

  private

  # Copié à l'identique de WebinarsControllerTest — le flow OIDC en
  # test_mode reste la référence.
  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id",
      uid: user.oidc_sub,
      info: { email: user.email }
    )
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:pocket_id]
    get "/auth/pocket_id/callback"
    Rails.application.env_config.delete("omniauth.auth")
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end
end
