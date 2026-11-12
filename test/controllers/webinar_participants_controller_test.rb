require "test_helper"

# Modération du direct depuis la régie : toute
# l'animation coupe le micro d'un intervenant ou d'un spectateur, ou le
# retire durablement ; jamais une identité d'animation. Chaque refus est
# vérifié SANS appel LiveKit.
class WebinarParticipantsControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  class FakeRoom
    attr_reader :calls
    attr_accessor :participants, :remove_error, :gone_tracks

    def initialize
      @calls = []
      @participants = []
      @gone_tracks = []
    end

    def list_participants(room:)
      @calls << [ :list_participants, room ]
      participants
    end

    def mute_track(room:, identity:, track_sid:)
      @calls << [ :mute_track, room, identity, track_sid ]
      raise RoomServiceClient::RemoteError.new("piste inconnue", code: "not_found") if gone_tracks.include?(track_sid)

      {}
    end

    def remove_participant(room:, identity:)
      @calls << [ :remove_participant, room, identity ]
      raise remove_error if remove_error

      {}
    end
  end

  setup do
    @owner = User.create!(email: "marc@example.test", oidc_sub: "sub-marc")
    @guest = User.create!(email: "co@partenaire.test", oidc_sub: "sub-co", email_verified: true, email_verified_for: "co@partenaire.test")
    @project_host = User.create!(email: "projet@example.test", oidc_sub: "sub-projet", admin: true)
    @stranger = User.create!(email: "autre@example.test", oidc_sub: "sub-autre")
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: Time.current, host_sub: @owner.oidc_sub,
                               visibility: "published", state: "live", started_at: Time.current)
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
    @speaker = @webinar.speakers.create!(name: "Basile")
    @viewer = @webinar.registrations.create!(name: "Inès", email: "ines@example.test", confirmed_at: Time.current)
    @room = FakeRoom.new
    @room.participants = [
      participant("host-#{@owner.oidc_sub}", tracks: [ track("TR_host_mic", "AUDIO", "MICROPHONE") ]),
      participant("speaker-#{@speaker.id}", tracks: [
        track("TR_cam", "VIDEO", "CAMERA"),
        track("TR_mic", "AUDIO", "MICROPHONE"),
        track("TR_screen_audio", "AUDIO", "SCREEN_SHARE_AUDIO"),
        track("TR_old_mic", "AUDIO", "MICROPHONE", muted: true)
      ]),
      participant("viewer-#{@viewer.id}")
    ]
    @old_factory = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { @room }
  end

  teardown do
    Rails.configuration.x.room_service_client_factory = @old_factory
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "couper le micro : seules les pistes audio audibles de la personne sont coupées" do
    sign_in_as(@owner)

    post mute_webinar_participant_path(@webinar, "speaker-#{@speaker.id}"), as: :json

    assert_response :success
    assert_equal({ "muted_tracks" => 2 }, response.parsed_body)
    assert_equal [ [ :mute_track, @webinar.room_name, "speaker-#{@speaker.id}", "TR_mic" ],
                   [ :mute_track, @webinar.room_name, "speaker-#{@speaker.id}", "TR_screen_audio" ] ],
                 @room.calls.select { |call| call.first == :mute_track }
    assert_nil @speaker.reload.revoked_at, "couper le micro ne révoque pas"
  end

  test "couper le micro d'une personne absente ou muette : rien à couper, pas d'erreur" do
    sign_in_as(@owner)

    post mute_webinar_participant_path(@webinar, "viewer-#{@viewer.id}"), as: :json
    assert_response :success
    assert_equal({ "muted_tracks" => 0 }, response.parsed_body)

    @room.participants = []
    post mute_webinar_participant_path(@webinar, "speaker-#{@speaker.id}"), as: :json
    assert_response :success
    assert_equal({ "muted_tracks" => 0 }, response.parsed_body)
    assert_empty @room.calls.select { |call| call.first == :mute_track }
  end

  # La personne (ou sa piste) part entre la lecture de
  # la salle et la coupure ; ce n'est pas une panne de LiveKit.
  test "couper le micro : une piste partie entre-temps n'est pas une erreur" do
    @room.gone_tracks = [ "TR_screen_audio" ]
    sign_in_as(@owner)

    post mute_webinar_participant_path(@webinar, "speaker-#{@speaker.id}"), as: :json

    assert_response :success
    assert_equal({ "muted_tracks" => 1 }, response.parsed_body)
  end

  test "retirer un intervenant : retiré (lien révoqué avec) puis expulsé de la salle" do
    sign_in_as(@owner)

    post remove_webinar_participant_path(@webinar, "speaker-#{@speaker.id}"), as: :json

    assert_response :success
    assert_equal({ "removed" => true, "share_link_reentry" => false }, response.parsed_body,
                 "ajouté par l'animation : il ne connaît pas le lien partagé")
    assert @speaker.reload.room_removed_at
    assert @speaker.revoked_at, "retirer révoque aussi son lien"
    assert_equal [ [ :remove_participant, @webinar.room_name, "speaker-#{@speaker.id}" ] ], @room.calls
  end

  # La confirmation du retrait propose de régénérer
  # le lien partagé quand la personne pourrait revenir par lui.
  test "retirer un intervenant entré par le lien partagé encore actif : la régie propose de le régénérer" do
    share_token = @webinar.generate_share_token!
    intruder = @webinar.speakers.create!(name: "Intrus", declared_email: "intrus@example.test")
    @room.participants << participant("speaker-#{intruder.id}")
    sign_in_as(@guest, email_verified: true)

    post remove_webinar_participant_path(@webinar, "speaker-#{intruder.id}"), as: :json

    assert_response :success
    assert_equal({ "removed" => true, "share_link_reentry" => true }, response.parsed_body)
    assert_equal share_token, @webinar.reload.share_token, "jamais de régénération d'office"
  end

  test "lien partagé désactivé, ou spectateur retiré : rien à proposer" do
    intruder = @webinar.speakers.create!(name: "Intrus", declared_email: "intrus@example.test")
    sign_in_as(@owner)

    post remove_webinar_participant_path(@webinar, "speaker-#{intruder.id}"), as: :json
    assert_equal false, response.parsed_body.fetch("share_link_reentry"), "aucun lien actif"

    @webinar.generate_share_token!
    post remove_webinar_participant_path(@webinar, "viewer-#{@viewer.id}"), as: :json
    assert_equal false, response.parsed_body.fetch("share_link_reentry"), "spectateur"
  end

  test "retirer un spectateur : retrait durable, main refermée, expulsion" do
    hand = HandRaiseControl.new(@webinar).raise_hand(@viewer)
    sign_in_as(@project_host)

    post remove_webinar_participant_path(@webinar, "viewer-#{@viewer.id}"), as: :json

    assert_response :success
    assert @viewer.reload.room_removed_at
    assert @viewer.confirmed?, "l'inscription reste confirmée (CRM, consentements)"
    assert_equal "revoked", hand.reload.state
    assert hand.revoked_at
    assert_equal [ [ :remove_participant, @webinar.room_name, "viewer-#{@viewer.id}" ] ], @room.calls
  end

  test "le co-animateur invité coupe le micro et retire, comme le propriétaire" do
    sign_in_as(@guest, email_verified: true)

    post mute_webinar_participant_path(@webinar, "speaker-#{@speaker.id}"), as: :json
    assert_response :success
    post remove_webinar_participant_path(@webinar, "viewer-#{@viewer.id}"), as: :json
    assert_response :success

    assert @viewer.reload.room_removed_at
    assert_includes @room.calls, [ :remove_participant, @webinar.room_name, "viewer-#{@viewer.id}" ]
  end

  # Le co-animateur invité ne gère
  # ni les intervenants ni les inscrits (Webinar#can_manage_speakers?,
  # #can_manage_registrations?). Il ne modère que la personne présente dans
  # la salle, pendant le direct ; sinon il révoquerait le lien d'un
  # intervenant ou mettrait l'adresse d'un inscrit en pierre tombale, des
  # jours avant le direct.
  test "le co-animateur ne retire pas un intervenant absent de la salle : 422, lien intact, LiveKit non commandé" do
    @room.participants = []
    sign_in_as(@guest, email_verified: true)

    post remove_webinar_participant_path(@webinar, "speaker-#{@speaker.id}"), as: :json

    assert_response :unprocessable_entity
    assert_equal({ "error" => "not_in_room" }, response.parsed_body)
    @speaker.reload
    assert_nil @speaker.revoked_at
    assert_nil @speaker.room_removed_at
    assert_equal [ :list_participants ], @room.calls.map(&:first)
  end

  test "le co-animateur ne retire pas un inscrit en attente absent : 422, adresse et jeton intacts" do
    pending = @webinar.registrations.create!(name: "Jeanne", email: "jeanne@example.test")
    token = pending.token
    sign_in_as(@guest, email_verified: true)

    post remove_webinar_participant_path(@webinar, "viewer-#{pending.id}"), as: :json

    assert_response :unprocessable_entity
    assert_equal({ "error" => "not_in_room" }, response.parsed_body)
    pending.reload
    assert_equal "jeanne@example.test", pending.email
    assert_equal token, pending.token
    assert_nil pending.room_removed_at
    get confirm_registration_path(token)
    assert_not_equal 404, response.status, "l'ancien lien de confirmation sert toujours"
  end

  test "le co-animateur ne coupe pas le micro d'une personne absente : 422, rien n'est commandé" do
    @room.participants = []
    sign_in_as(@guest, email_verified: true)

    post mute_webinar_participant_path(@webinar, "speaker-#{@speaker.id}"), as: :json

    assert_response :unprocessable_entity
    assert_equal({ "error" => "not_in_room" }, response.parsed_body)
    assert_empty @room.calls.reject { |call| call.first == :list_participants }
  end

  test "hors direct, le co-animateur ne modère personne, même présent : 403, aucun appel LiveKit" do
    sign_in_as(@guest, email_verified: true)

    %w[draft ended].each do |state|
      @webinar.update!(state: state)
      %i[mute remove].each do |action|
        post public_send("#{action}_webinar_participant_path", @webinar, "speaker-#{@speaker.id}"), as: :json
        assert_response :forbidden, "#{state} #{action}"
        assert_equal({ "error" => "not_live" }, response.parsed_body)
      end
    end
    assert_nil @speaker.reload.revoked_at
    assert_nil @speaker.room_removed_at
    assert_empty @room.calls
  end

  # Le co-animateur peut lui-même passer le webinaire en direct
  # des jours avant la date ; la présence dans la salle reste la barrière.
  test "le co-animateur qui passe en direct en avance ne retire toujours pas une personne absente" do
    @webinar.update!(state: "draft", started_at: nil, starts_at: 2.days.from_now)
    @room.participants = []
    pending = @webinar.registrations.create!(name: "Jeanne", email: "jeanne@example.test")
    sign_in_as(@guest, email_verified: true)

    @webinar.go_live! # ce que fait WebinarStatesController#go_live, ouvert à toute l'animation
    post remove_webinar_participant_path(@webinar, "speaker-#{@speaker.id}"), as: :json
    assert_response :unprocessable_entity
    post remove_webinar_participant_path(@webinar, "viewer-#{pending.id}"), as: :json
    assert_response :unprocessable_entity

    assert_nil @speaker.reload.revoked_at
    assert_equal "jeanne@example.test", pending.reload.email
  end

  test "LiveKit injoignable pour le co-animateur : 502, aucune écriture" do
    def @room.list_participants(room:) = raise(RoomServiceClient::Error, "connexion refusée")
    sign_in_as(@guest, email_verified: true)

    %i[mute remove].each do |action|
      post public_send("#{action}_webinar_participant_path", @webinar, "speaker-#{@speaker.id}"), as: :json
      assert_response :bad_gateway, action
      assert_equal({ "error" => "room_update_failed" }, response.parsed_body)
    end
    @speaker.reload
    assert_nil @speaker.revoked_at
    assert_nil @speaker.room_removed_at
  end

  test "le propriétaire et l'animateur du projet retirent durablement, même absent et hors direct" do
    @room.participants = []
    @webinar.update!(state: "draft")
    pending = @webinar.registrations.create!(name: "Jeanne", email: "jeanne@example.test")

    sign_in_as(@owner)
    post remove_webinar_participant_path(@webinar, "speaker-#{@speaker.id}"), as: :json
    assert_response :success
    assert @speaker.reload.revoked_at

    sign_in_as(@project_host)
    post remove_webinar_participant_path(@webinar, "viewer-#{pending.id}"), as: :json
    assert_response :success
    assert pending.reload.retired?, "comportement actuel : inscription non confirmée → pierre tombale"
  end

  test "jamais une identité d'animation : le co-animateur ne peut ni couper ni expulser le propriétaire" do
    sign_in_as(@guest, email_verified: true)

    [ "host-#{@owner.oidc_sub}", "host-#{@guest.oidc_sub}" ].each do |identity|
      %i[mute remove].each do |action|
        post public_send("#{action}_webinar_participant_path", @webinar, identity), as: :json
        assert_response :unprocessable_entity
        assert_equal({ "error" => "invalid_identity" }, response.parsed_body)
      end
    end
    assert_empty @room.calls
  end

  test "identité d'une autre forme : 422, rien n'est touché" do
    sign_in_as(@owner)

    %w[agent-AJ_x viewer-0 speaker-legacy-abc EG_rec viewer-1x].each do |identity|
      post remove_webinar_participant_path(@webinar, identity), as: :json
      assert_response :unprocessable_entity, identity
    end
    assert_empty @room.calls
  end

  test "personne inconnue de ce webinaire : 404, rien n'est touché" do
    other = Webinar.create!(title: "Autre", starts_at: Time.current, host_sub: @owner.oidc_sub)
    foreign_speaker = other.speakers.create!(name: "Eve")
    foreign_viewer = other.registrations.create!(name: "Eva", email: "eva@example.test", confirmed_at: Time.current)
    sign_in_as(@owner)

    [ "speaker-#{foreign_speaker.id}", "viewer-#{foreign_viewer.id}", "viewer-999999" ].each do |identity|
      post remove_webinar_participant_path(@webinar, identity), as: :json
      assert_response :not_found, identity
    end
    assert_nil foreign_speaker.reload.revoked_at
    assert_nil foreign_viewer.reload.room_removed_at
    assert_empty @room.calls
  end

  test "anonyme, intervenant ou spectateur sans session animateur : renvoyés à la connexion, rien n'est touché" do
    post mute_webinar_participant_path(@webinar, "viewer-#{@viewer.id}"), as: :json
    assert_redirected_to sign_in_path

    post remove_webinar_participant_path(@webinar, "viewer-#{@viewer.id}"), params: { t: @speaker.token },
      headers: { "X-Speaker-Token" => @speaker.token }, as: :json
    assert_redirected_to sign_in_path

    post confirm_registration_path(@viewer.token)
    post remove_webinar_participant_path(@webinar, "speaker-#{@speaker.id}"), as: :json
    assert_redirected_to sign_in_path

    assert_nil @speaker.reload.revoked_at
    assert_nil @viewer.reload.room_removed_at
    assert_empty @room.calls
  end

  test "connecté sans rôle sur ce webinaire : 404, rien n'est touché" do
    sign_in_as(@stranger)

    post mute_webinar_participant_path(@webinar, "speaker-#{@speaker.id}"), as: :json
    assert_response :not_found
    post remove_webinar_participant_path(@webinar, "speaker-#{@speaker.id}"), as: :json
    assert_response :not_found

    assert_nil @speaker.reload.revoked_at
    assert_empty @room.calls
  end

  test "LiveKit en échec au retrait : 502, le retrait durable tient et se relance" do
    @room.remove_error = RoomServiceClient::Error.new("connexion refusée")
    sign_in_as(@owner)

    post remove_webinar_participant_path(@webinar, "speaker-#{@speaker.id}"), as: :json
    assert_response :bad_gateway
    assert_equal({ "error" => "room_update_failed" }, response.parsed_body)
    assert @speaker.reload.room_removed_at

    @room.remove_error = nil
    post remove_webinar_participant_path(@webinar, "speaker-#{@speaker.id}"), as: :json
    assert_response :success
  end

  # La main d'un spectateur qui a la parole ne se referme qu'une
  # fois l'expulsion acquise ; sinon il publierait encore, absent de la file
  # des « Mains levées » où l'animation peut lui retirer la parole.
  test "LiveKit en échec au retrait d'un spectateur qui a la parole : sa main reste visible jusqu'à l'expulsion" do
    hand = HandRaiseControl.new(@webinar).raise_hand(@viewer)
    hand.update!(state: "granted", granted_at: Time.current)
    @room.remove_error = RoomServiceClient::Error.new("connexion refusée")
    sign_in_as(@owner)

    post remove_webinar_participant_path(@webinar, "viewer-#{@viewer.id}"), as: :json
    assert_response :bad_gateway
    assert @viewer.reload.room_removed_at, "le retrait durable est acquis"
    assert_equal "granted", hand.reload.state
    assert_includes @webinar.hand_raises.active, hand

    @room.remove_error = nil
    post remove_webinar_participant_path(@webinar, "viewer-#{@viewer.id}"), as: :json
    assert_response :success
    assert_equal "revoked", hand.reload.state
  end

  # Le co-animateur retire
  # l'intervenant entré par le lien partagé ; le même navigateur renvoie le
  # formulaire et n'obtient pas un nouvel intervenant.
  test "intervenant retiré par le co-animateur : le lien partagé du même navigateur ne lui rend pas la salle" do
    previous_privacy = ENV["REGISTRATION_PRIVACY_URL"]
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/confidentialite"
    intruder_entry = { invitation: { name: "Intrus", email: "intrus@example.test", participation: "participant" } }
    share_token = @webinar.generate_share_token!
    intruder_browser = open_session
    intruder_ip = "10.69.#{rand(0..255)}.#{rand(1..254)}"
    intruder_browser.post invitation_create_path(t: share_token), params: intruder_entry,
      env: { "REMOTE_ADDR" => intruder_ip }
    intruder = @webinar.speakers.order(:id).last
    assert_equal "Intrus", intruder.name
    @room.participants << participant("speaker-#{intruder.id}")

    sign_in_as(@guest, email_verified: true)
    post remove_webinar_participant_path(@webinar, "speaker-#{intruder.id}"), as: :json
    assert_response :success

    assert_no_difference "Speaker.count" do
      intruder_browser.post invitation_create_path(t: share_token), params: intruder_entry,
        env: { "REMOTE_ADDR" => intruder_ip }
    end
    assert_equal 403, intruder_browser.response.status
    assert_empty @webinar.speakers.active.where(name: "Intrus")
    assert_nil @webinar.registrations.find_by!(email: "intrus@example.test").room_removed_at,
      "lien non prouvé : le retrait ne descend pas sur l'inscription de cette adresse, le cookie suffit"
  ensure
    ENV["REGISTRATION_PRIVACY_URL"] = previous_privacy
  end

  # L'intrus saisit l'adresse NEUVE d'une victime.
  # L'inscription créée ne lui est pas rattachée ; il est retiré, puis la
  # victime confirme son inscription : rien de lui sur sa fiche, elle entre.
  test "intrus sous l'adresse neuve d'une victime, retiré, puis la victime confirme : rien de lui sur sa fiche, elle entre" do
    previous_privacy = ENV["REGISTRATION_PRIVACY_URL"]
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/confidentialite"
    share_token = @webinar.generate_share_token!
    attacker_browser = open_session
    attacker_browser.post invitation_create_path(t: share_token),
      params: { invitation: { name: "Intrus", email: "victime@example.test", participation: "participant" } },
      env: { "REMOTE_ADDR" => "10.71.#{rand(0..255)}.#{rand(1..254)}" }
    intruder = @webinar.speakers.find_by!(name: "Intrus")
    victim = @webinar.registrations.find_by!(email: "victime@example.test")

    sign_in_as(@owner)
    post remove_webinar_participant_path(@webinar, "speaker-#{intruder.id}"), as: :json
    assert_response :success

    victim_browser = open_session
    victim_browser.post confirm_registration_path(victim.token)
    assert_equal public_webinar_path(@webinar.slug), URI(victim_browser.response.location).path
    assert victim.reload.confirmed?
    assert_nil victim.room_removed_at, "la victime n'est pas bannie"
    assert_empty victim.speakers, "confirmer son inscription ne lui rattache rien"
    assert_nil intruder.reload.registration
  ensure
    ENV["REGISTRATION_PRIVACY_URL"] = previous_privacy
  end

  # Lien prouvé par le mail qui nomme l'intervention : la cascade s'applique.
  test "lien prouvé par le mail de rattachement, puis retiré : son inscription l'est avec lui" do
    previous_privacy = ENV["REGISTRATION_PRIVACY_URL"]
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/confidentialite"
    share_token = @webinar.generate_share_token!
    speaker_browser = open_session
    speaker_browser.post invitation_create_path(t: share_token),
      params: { invitation: { name: "Basile D.", email: "basile@example.test", participation: "participant" } },
      env: { "REMOTE_ADDR" => "10.72.#{rand(0..255)}.#{rand(1..254)}" }
    speaker = @webinar.speakers.find_by!(name: "Basile D.")
    speaker_browser.post confirm_speaker_link_path(t: speaker.link_token)
    registration = speaker.reload.registration
    assert_equal "basile@example.test", registration.email

    sign_in_as(@owner)
    post remove_webinar_participant_path(@webinar, "speaker-#{speaker.id}"), as: :json
    assert_response :success

    assert registration.reload.room_removed_at, "lien prouvé : son inscription est retirée avec lui"
    assert_not registration.confirmed?
    assert_not registration.retired?, "boîte prouvée : pas de pierre tombale, l'adresse reste retirée"

    # Il ne contourne pas le retrait en se réinscrivant.
    returning = open_session
    returning.post public_webinar_registrations_path(@webinar.slug),
      params: { registration: { name: "Basile", email: "basile@example.test" } },
      env: { "REMOTE_ADDR" => "10.73.#{rand(0..255)}.#{rand(1..254)}" }
    assert_not_equal public_webinar_path(@webinar.slug), URI(returning.response.location.to_s).path, "pas d'accès immédiat"
    assert_equal [ registration ], @webinar.registrations.where(email: "basile@example.test").to_a

    # Course confirmation / retrait : le lien du mail ne confirme plus rien.
    assert_no_enqueued_jobs(only: CrmSyncJob) { returning.post confirm_registration_path(registration.token) }
    assert_equal 403, returning.response.status
    assert_not registration.reload.confirmed?
  ensure
    ENV["REGISTRATION_PRIVACY_URL"] = previous_privacy
  end

  # Lien participants : un intrus qui a saisi l'adresse
  # d'une inscrite n'est pas rattaché à elle ; le retirer ne la bannit pas.
  test "retirer un intervenant entré sous l'adresse d'une autre : elle reste, sa main aussi, rien n'est rattaché à sa fiche" do
    previous_privacy = ENV["REGISTRATION_PRIVACY_URL"]
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/confidentialite"
    hand = @webinar.hand_raises.create!(registration: @viewer, raised_at: Time.current, state: "waiting")
    share_token = @webinar.generate_share_token!
    attacker_browser = open_session
    attacker_browser.post invitation_create_path(t: share_token),
      params: { invitation: { name: "Intrus", email: @viewer.email, participation: "participant" } },
      env: { "REMOTE_ADDR" => "10.70.#{rand(0..255)}.#{rand(1..254)}" }
    intruder = @webinar.speakers.find_by!(name: "Intrus")
    assert_nil intruder.registration, "rien n'est attribué à la fiche de la victime"

    sign_in_as(@owner)
    post remove_webinar_participant_path(@webinar, "speaker-#{intruder.id}"), as: :json
    assert_response :success

    assert intruder.reload.room_removed_at
    assert_nil @viewer.reload.room_removed_at, "la victime n'est pas retirée"
    assert_nil hand.reload.revoked_at, "sa main reste levée"
  ensure
    ENV["REGISTRATION_PRIVACY_URL"] = previous_privacy
  end

  test "personne déjà sortie de la salle : le retrait est acquis" do
    @room.remove_error = RoomServiceClient::RemoteError.new("participant inconnu", code: "not_found")
    sign_in_as(@owner)

    post remove_webinar_participant_path(@webinar, "viewer-#{@viewer.id}"), as: :json

    assert_response :success
    assert @viewer.reload.room_removed_at
  end

  private

  def participant(identity, tracks: [])
    { identity: identity, kind: "STANDARD", name: identity, permission: { can_publish: tracks.any? }, tracks: tracks }
  end

  def track(sid, type, source, muted: false)
    { sid: sid, type: type, source: source, muted: muted }
  end
end
