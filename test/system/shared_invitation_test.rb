require "application_system_test_case"

class SharedInvitationTest < ApplicationSystemTestCase
  # Parcours Capybara (rack_test) du lien d'invitation INTERVENANT PARTAGÉ :
  # ouvrir le lien partagé → saisir
  # son nom → arriver sur la page intervenant /join avec le nom pré-rempli
  # (data-slug prêt, speaker_token présent dans l'URL).

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  setup do
    @host = User.create!(email: "sh-host@example.com", oidc_sub: "sh-sub-host")
    @webinar = Webinar.create!(
      title: "Café IA invitation",
      starts_at: 1.day.from_now,
      host_sub: @host.oidc_sub,
      visibility: "published"
    )
    @token = @webinar.generate_share_token!
    @prev_key    = ENV["LIVEKIT_API_KEY"]
    @prev_secret = ENV["LIVEKIT_API_SECRET"]
    @prev_privacy = ENV["REGISTRATION_PRIVACY_URL"]
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/confidentialite"
    # Stubs egress/room : WebinarsController#join appelle RecordingSession.
    # On ne teste PAS le recording ici — on stub pour éviter des appels
    # réseau réels à des hôtes LiveKit absents en CI.
    @prev_egress = Rails.configuration.x.egress_client_factory
    @prev_room   = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.egress_client_factory       = -> { noop_egress_stub }
    Rails.configuration.x.room_service_client_factory = -> { noop_room_stub }
  end

  teardown do
    ENV["LIVEKIT_API_KEY"]    = @prev_key
    ENV["LIVEKIT_API_SECRET"] = @prev_secret
    ENV["REGISTRATION_PRIVACY_URL"] = @prev_privacy
    Rails.configuration.x.egress_client_factory       = @prev_egress
    Rails.configuration.x.room_service_client_factory = @prev_room
  end

  test "shared_invitation_turns_a_guest_into_a_named_speaker" do
    visit invitation_path(t: @token)
    assert_text @webinar.title
    assert_selector "form[action='#{invitation_create_path(t: @token)}']"

    fill_in "Ton prénom", with: "Lucie Dupont"
    fill_in "Ton mail", with: "lucie@example.test"
    click_on "J'entre"

    created = @webinar.speakers.find_by!(name: "Lucie Dupont")
    assert_current_path join_webinar_path(slug: @webinar.slug, t: created.token)
    assert_equal "lucie@example.test", created.declared_email, "adresse déclarée, rattachée au clic du mail"

    # Page /join : container LiveKit prêt (data-slug + data-speaker-token
    # consommés par rooms/room.jsx). Le composant React n'est pas monté
    # sous rack_test — on vérifie le CONTRAT HTML, cohérent avec les
    # autres system tests du repo.
    assert_selector "#livekit-room[data-slug='#{@webinar.slug}']"
    assert_selector "#livekit-room[data-speaker-token='#{created.token}']"

    # L'animateur voit l'intervenant dans sa liste (section Intervenants).
    sign_in_as(@host)
    visit webinar_path(@webinar)
    assert_selector "[data-speaker-id='#{created.id}']"
    assert_text "Lucie Dupont"
  end

  # Retiré depuis la régie, l'intervenant qui rouvre le lien
  # partagé depuis le même navigateur lit pourquoi, sans formulaire.
  test "shared_invitation_refuses_a_removed_speaker_from_the_same_browser" do
    visit invitation_path(t: @token)
    fill_in "Ton prénom", with: "Lucie Dupont"
    fill_in "Ton mail", with: "lucie@example.test"
    click_on "J'entre"
    @webinar.speakers.find_by!(name: "Lucie Dupont").remove_from_room!

    visit invitation_path(t: @token)

    assert_selector "[data-role='room-removed'] h1", text: "Accès retiré"
    assert_text "L’animation vous a retiré de #{@webinar.title}."
    assert_no_field "Ton prénom"
    assert_equal 1, @webinar.speakers.count
  end

  # Retirer ≠ révoquer : révoqué par le propriétaire, il
  # revoit le formulaire et obtient un nouveau lien.
  test "shared_invitation_gives_a_new_link_to_a_speaker_revoked_by_the_owner" do
    visit invitation_path(t: @token)
    fill_in "Ton prénom", with: "Lucie Dupont"
    fill_in "Ton mail", with: "lucie@example.test"
    click_on "J'entre"
    @webinar.speakers.find_by!(name: "Lucie Dupont").revoke!

    visit invitation_path(t: @token)
    fill_in "Ton prénom", with: "Lucie Dupont"
    fill_in "Ton mail", with: "lucie@example.test"
    click_on "J'entre"

    fresh = @webinar.speakers.active.find_by!(name: "Lucie Dupont")
    assert_current_path join_webinar_path(slug: @webinar.slug, t: fresh.token)
  end

  # Un spectateur retiré depuis la régie qui ouvre le
  # lien partagé intervenant dans le même navigateur lit « Accès retiré ».
  test "shared_invitation_refuses_a_removed_viewer_from_the_same_browser" do
    @webinar.update!(state: "live", started_at: Time.current)
    confirm_viewer_registration(@webinar)
    @webinar.registrations.find_by!(email: "viewer@example.test").remove_from_room!

    visit invitation_path(t: @token)

    assert_selector "[data-role='room-removed'] h1", text: "Accès retiré"
    assert_no_field "Ton prénom"
    assert_empty @webinar.speakers
  end

  # Spectateur par le lien privé pendant le direct, la salle
  # s'ouvre tout de suite, avant la confirmation du mail.
  test "shared_invitation_lets_a_spectator_in_during_the_live" do
    @webinar.update!(state: "live", started_at: Time.current)
    visit invitation_path(t: @token)
    fill_in "Ton prénom", with: "Inès"
    fill_in "Ton mail", with: "ines@example.test"
    choose "J'observe — j'ai le chat"
    click_on "J'entre"

    assert_current_path public_webinar_path(slug: @webinar.slug)
    assert_selector "#livekit-room[data-viewer-hand-raises-url]"
    assert_empty @webinar.speakers
    assert_not @webinar.registrations.find_by!(email: "ines@example.test").confirmed?
  end

  private

  def noop_egress_stub
    stub = Object.new
    def stub.start_room_composite(room_name:, filepath:)
      { egress_id: "EG_test_#{SecureRandom.hex(3)}", status: :starting, raw: nil }
    end
    def stub.stop(egress_id:)
      { egress_id: egress_id, status: :ending, raw: nil }
    end
    def stub.list_egress(egress_id:)
      { egress_id: egress_id, status: :active, ended_at: 0, error: nil, raw: nil }
    end
    def stub.list_room_composite_egress(room_name:)
      []
    end
    stub
  end

  def noop_room_stub
    stub = Object.new
    def stub.create_room(name:)
      { name: name }
    end
    stub
  end

  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: user.oidc_sub, info: { email: user.email }
    )
    visit "/auth/pocket_id/callback"
  ensure
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end
end
