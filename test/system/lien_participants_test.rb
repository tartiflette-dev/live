require "application_system_test_case"

# Lien participants, bout en bout dans un vrai
# navigateur. La CI n'a pas de LiveKit : la salle est la salle simulée
# partagée (LivekitPacketDelivery::RoomRecorder), qui reçoit la permission
# de publier comme le ferait livekit-server. Sans serveur WebRTC, la preuve
# qu'une personne peut publier est son jeton LiveKit, relu depuis son
# navigateur : c'est lui que LiveKit appliquera. Publier passe par l'accord à
# l'image (PublishPermission) : rien ne s'ouvre avant son POST.
class LienParticipantsTest < JsSystemTestCase
  include OidcSignIn

  PREJOIN_TOGGLES = [ "[data-testid='prejoin'] .lk-button-group.audio [data-lk-source='microphone']",
                      "[data-testid='prejoin'] .lk-button-group.video [data-lk-source='camera']" ].freeze
  BAR_CAM = "[data-testid='room-controls'] button[data-lk-source='camera']"

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  setup do
    @host = User.create!(email: "marc@example.test", oidc_sub: "sub-marc-#{SecureRandom.hex(4)}")
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 5.minutes.ago, host_sub: @host.oidc_sub,
                               visibility: "published", state: "live", started_at: Time.current)
    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL", "REGISTRATION_PRIVACY_URL")
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/confidentialite"
    @room = LivekitPacketDelivery::RoomRecorder.new
    @previous_factory = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { @room }
  end

  teardown do
    Rails.configuration.x.room_service_client_factory = @previous_factory
    @saved_env.each_key { |key| ENV[key] = @saved_env[key] }
  end

  test "inscrit en direct comme participant : salle tout de suite, main levée en régie, admis, la fenêtre d'accord, puis il publie" do
    using_session(:participant) do
      visit public_webinar_path(@webinar.slug)
      fill_in "Ton prénom", with: "Inès"
      fill_in "Ton mail", with: "ines@example.test"
      choose "Je participe — caméra et micro"
      click_on "Je viens"

      # Pas de détour par la boîte mail : la salle, main déjà levée (message
      # neutre côté participant : ni « main levée » ni admission).
      assert_selector "[data-testid='hand-raise-status']", text: "On t'ouvre la caméra et le micro dans un instant.", wait: 10
      assert_equal false, publish_grant(@webinar), "l'entrée ne publie pas : la publication attend l'animation"
    end
    registration = @webinar.registrations.find_by!(email: "ines@example.test")
    assert registration.participant?
    assert_not registration.confirmed?, "le mail de confirmation reste à cliquer"
    assert_nil registration.crm_enrolled_at

    using_session(:host) do
      sign_in_as(@host)
      visit webinar_regie_path(@webinar)
      within("[data-testid='hand-raise-item']", text: "Inès", wait: 10) do
        assert_selector "[data-testid='hand-raise-wants-video']", text: "veut intervenir en vidéo"
        click_on "Donner la parole"
      end
      assert_selector "[data-testid='hand-raise-revoke']", text: "Retirer la parole", wait: 10
    end
    assert_empty @room.permissions, "admis sans accord à l'image : rien d'ouvert côté salle"

    using_session(:participant) do
      # Venu pour intervenir : la fenêtre d'accord s'ouvre d'elle-même.
      within("[data-testid='consent-dialog']", wait: 10) do
        check ParticipantConsent::LABELS[:recording]
        check ParticipantConsent::LABELS[:adult]
        click_on "Allumer"
      end
      assert_no_selector "[data-testid='consent-dialog']", wait: 10
      assert_equal [ [ "viewer-#{registration.id}", true ] ], @room.permissions, "le POST de l'accord fait ouvrir la publication"
      assert_equal true, publish_grant(@webinar), "admis : son jeton publie, même après un rechargement"
    end
  end

  test "lien participants privé, avec son mail, comme participant : sur scène tout de suite, il publie dès son accord" do
    share_token = @webinar.generate_share_token!

    visit invitation_path(t: share_token)
    fill_in "Ton prénom", with: "Basile"
    fill_in "Ton mail", with: "basile@example.test"
    assert_checked_field "Je participe — caméra et micro, tout de suite"
    click_on "J'entre"

    # La salle d'abord : le Speaker existe une fois la requête du clic finie.
    assert_selector "[data-testid='prejoin']", wait: 10
    speaker = @webinar.speakers.find_by!(name: "Basile")
    assert_current_path join_webinar_path(slug: @webinar.slug, t: speaker.token)
    assert_equal false, publish_grant(@webinar, speaker_token: speaker.token), "pas de publication sans accord à l'image"
    assert_equal "basile@example.test", speaker.declared_email, "adresse déclarée, rattachée au clic du mail"
    assert @webinar.registrations.find_by!(email: "basile@example.test").participant?

    # Choix du PreJoin gardés par le navigateur d'un test à l'autre : on ne
    # coupe que ce qui est allumé, puis la caméra de la barre ouvre la fenêtre.
    PREJOIN_TOGGLES.each do |toggle|
      button = find(toggle, wait: 10)
      button.click if button["aria-pressed"] == "true"
    end
    find("[data-testid='prejoin'] .lk-join-button:not([disabled])", wait: 10).click
    find(BAR_CAM, wait: 10).click
    within("[data-testid='consent-dialog']", wait: 10) do
      check ParticipantConsent::LABELS[:recording]
      check ParticipantConsent::LABELS[:adult]
      click_on "Allumer"
    end
    assert_no_selector "[data-testid='consent-dialog']", wait: 10
    assert_equal [ [ "speaker-#{speaker.id}", true ] ], @room.permissions
    assert_equal true, publish_grant(@webinar, speaker_token: speaker.token)
  end

  private

  # Jeton LiveKit tel que la salle le demande depuis ce navigateur (cookie,
  # jeton intervenant) : peut-il publier ?
  def publish_grant(webinar, speaker_token: nil)
    result = page.driver.browser.execute_async_script(<<~JS)
      const done = arguments[0];
      fetch('/api/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '' },
        body: JSON.stringify({ slug: #{JSON.generate(webinar.slug)}, speaker_token: #{JSON.generate(speaker_token)} })
      }).then(async response => done({ status: response.status, body: await response.json() }));
    JS
    assert_equal 200, result.fetch("status"), result.inspect
    claims, = JWT.decode(result.fetch("body").fetch("token"), FAKE_SECRET, true, algorithm: "HS256")
    claims.fetch("video").fetch("canPublish")
  end
end
