require "test_helper"

class WebinarHostsControllerTest < ActionDispatch::IntegrationTest
  # CRUD minimal (create / destroy) sur
  # /webinars/:webinar_id/hosts. Autorisation : owner / project_host.
  # Un guest_host ne peut PAS gérer la liste.
  setup do
    @owner  = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    @admin  = User.create!(email: "admin@example.net", oidc_sub: "sub-admin", admin: true)
    @guest  = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean")
    @other  = User.create!(email: "autre@example.net", oidc_sub: "sub-autre")
    @webinar = Webinar.create!(title: "demo", starts_at: 1.day.from_now, host_sub: @owner.oidc_sub)
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
    Rails.configuration.x.room_service_client_factory = @prev_room if defined?(@prev_room)
  end

  # Stub RoomServiceClient capturant les appels remove_participant —
  # défense stale-authorization §2b. Le stub réussit par défaut ; les
  # tests qui veulent exercer la branche « expulsion échoue » peuvent
  # poser `raise_on_remove: RoomServiceClient::Error.new(...)`.
  class FakeRoomService
    attr_reader :removed
    def initialize(raise_on_remove: nil)
      @raise = raise_on_remove
      @removed = []
    end
    def remove_participant(room:, identity:)
      @removed << [ room, identity ]
      raise @raise if @raise
    end
  end

  def stub_room_service(**opts)
    @prev_room = Rails.configuration.x.room_service_client_factory
    fake = FakeRoomService.new(**opts)
    Rails.configuration.x.room_service_client_factory = -> { fake }
    fake
  end

  test "unauthenticated redirect sign_in" do
    post webinar_hosts_path(@webinar), params: { webinar_host: { email: "x@y.example.net" } }
    assert_redirected_to sign_in_path
  end

  test "owner ajoute un co-animateur par email" do
    sign_in_as(@owner)
    assert_difference -> { WebinarHost.count }, 1 do
      post webinar_hosts_path(@webinar), params: { webinar_host: { email: "Jean@partenaire.example.org" } }
    end
    assert_redirected_to webinar_path(@webinar)
    assert_equal "jean@partenaire.example.org", @webinar.webinar_hosts.last.email
    assert_equal @owner.oidc_sub, @webinar.webinar_hosts.last.invited_by_sub
  end

  test "project_host (admin) ajoute un co-animateur sur un webinaire d'autrui" do
    sign_in_as(@admin)
    assert_difference -> { WebinarHost.count }, 1 do
      post webinar_hosts_path(@webinar), params: { webinar_host: { email: "jean@partenaire.example.org" } }
    end
  end

  test "guest_host NE peut PAS ajouter un co-animateur (404 défense énumération)" do
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
    sign_in_as(@guest)
    assert_no_difference -> { WebinarHost.count } do
      post webinar_hosts_path(@webinar), params: { webinar_host: { email: "autre@example.net" } }
    end
    assert_response :not_found
  end

  test "user inconnu NE peut PAS ajouter (404)" do
    sign_in_as(@other)
    assert_no_difference -> { WebinarHost.count } do
      post webinar_hosts_path(@webinar), params: { webinar_host: { email: "x@y.example.net" } }
    end
    assert_response :not_found
  end

  test "email invalide = flash alerte, pas de creation" do
    sign_in_as(@owner)
    assert_no_difference -> { WebinarHost.count } do
      post webinar_hosts_path(@webinar), params: { webinar_host: { email: "pas-un-email" } }
    end
    assert_redirected_to webinar_path(@webinar)
  end

  test "doublon case-insensitive = flash alerte" do
    @webinar.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: @owner.oidc_sub)
    sign_in_as(@owner)
    assert_no_difference -> { WebinarHost.count } do
      post webinar_hosts_path(@webinar), params: { webinar_host: { email: "JEAN@partenaire.example.org" } }
    end
  end

  test "owner retire un co-animateur" do
    host = @webinar.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: @owner.oidc_sub)
    sign_in_as(@owner)
    assert_difference -> { WebinarHost.count }, -1 do
      delete webinar_host_path(@webinar, host)
    end
    assert_redirected_to webinar_path(@webinar)
  end

  test "guest_host NE peut PAS retirer (404)" do
    host = @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
    sign_in_as(@guest)
    assert_no_difference -> { WebinarHost.count } do
      delete webinar_host_path(@webinar, host)
    end
    assert_response :not_found
  end

  test "idor_destroy_webinar_host_d_un_autre_webinaire_renvoie_404" do
    # Défense IDOR §2d : un WebinarHost appartenant à
    # un AUTRE webinaire ne doit pas être supprimable via son id. Le
    # scope `@webinar.webinar_hosts.find` fait le travail (ActiveRecord
    # restreint à la relation).
    other_webinar = Webinar.create!(title: "autre", starts_at: 1.day.from_now, host_sub: @owner.oidc_sub)
    other_host = other_webinar.webinar_hosts.create!(email: "autre@partenaire.example.org", invited_by_sub: @owner.oidc_sub)

    sign_in_as(@owner)
    assert_no_difference -> { WebinarHost.count } do
      # On passe le @webinar en URL mais l'id d'un host appartenant à
      # l'autre webinaire.
      delete webinar_host_path(@webinar, other_host)
    end
    assert_response :not_found
    assert WebinarHost.exists?(other_host.id)
  end

  test "destroy_expulse_le_coanimateur_du_livekit_quand_il_a_deja_claim_et_le_webinaire_est_live" do
    # Défense stale-authorization §2b : retirer un co-animateur doit
    # couper ses droits IMMÉDIATEMENT, y compris une session LiveKit
    # ouverte. On expulse via RoomServiceClient#remove_participant.
    fake_room = stub_room_service
    host = @webinar.webinar_hosts.create!(
      email: @guest.email, invited_by_sub: @owner.oidc_sub, claimed_sub: @guest.oidc_sub
    )
    @webinar.update!(state: "live", started_at: 1.minute.ago)

    sign_in_as(@owner)
    delete webinar_host_path(@webinar, host)
    assert_response :redirect

    assert_equal 1, fake_room.removed.size
    room, identity = fake_room.removed.first
    assert_equal @webinar.room_name, room
    assert_equal "host-#{@guest.oidc_sub}", identity
  end

  test "destroy_ne_tente_pas_d_expulsion_quand_claimed_sub_nil" do
    fake_room = stub_room_service
    host = @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    sign_in_as(@owner)
    delete webinar_host_path(@webinar, host)
    assert_empty fake_room.removed
  end

  test "destroy_ne_tente_pas_d_expulsion_hors_live" do
    fake_room = stub_room_service
    host = @webinar.webinar_hosts.create!(
      email: @guest.email, invited_by_sub: @owner.oidc_sub, claimed_sub: @guest.oidc_sub
    )
    # @webinar reste en draft.
    sign_in_as(@owner)
    delete webinar_host_path(@webinar, host)
    assert_empty fake_room.removed
  end

  test "destroy_tolere_un_echec_d_expulsion_livekit_et_flashe_une_alerte" do
    # L'expulsion est best-effort — un échec LiveKit (down, participant
    # déjà parti) ne doit PAS bloquer la suppression. Le droit est déjà
    # coupé côté app Rails, c'est l'invariant central. L'échec DOIT
    # être VISIBLE pour l'animateur — pas seulement
    # loggé — pour qu'il décide (ré-essayer, terminer le direct…).
    stub_room_service(raise_on_remove: RoomServiceClient::Error.new("boom"))
    host = @webinar.webinar_hosts.create!(
      email: @guest.email, invited_by_sub: @owner.oidc_sub, claimed_sub: @guest.oidc_sub
    )
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    sign_in_as(@owner)
    assert_difference -> { WebinarHost.count }, -1 do
      delete webinar_host_path(@webinar, host)
    end
    assert_response :redirect
    assert_match(/expulsion LiveKit a échoué|expiration du jeton/, flash[:alert])
  end

  private

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
