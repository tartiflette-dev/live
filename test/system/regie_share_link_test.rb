require "application_system_test_case"

# Régénérer le lien intervenants depuis la régie. Un co-animateur invité,
# seul en régie, retire un intrus entré
# par le lien partagé ; la confirmation du retrait propose de régénérer ce
# lien. L'ancien est refusé à un autre navigateur, le nouveau, copié depuis la
# régie, ouvre l'entrée. La CI n'a pas de LiveKit : salle simulée
# (LivekitPacketDelivery::RoomRecorder), qui fait sortir la personne comme le
# ferait livekit-server.
class RegieShareLinkTest < JsSystemTestCase
  include OidcSignIn
  include LivekitPacketDelivery

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  setup do
    @owner = User.create!(email: "luc@example.test", oidc_sub: "sub-luc-#{SecureRandom.hex(4)}")
    @guest = User.create!(email: "co@partenaire.test", oidc_sub: "sub-co-#{SecureRandom.hex(4)}")
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.ago, host_sub: @owner.oidc_sub,
                               visibility: "published", state: "live", started_at: Time.current)
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
    @old_token = @webinar.generate_share_token!
    # Entré par le lien partagé : adresse déclarée, non prouvée (InvitationEntry).
    @intruder = @webinar.speakers.create!(name: "Intrus", declared_email: "intrus@example.test")
    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL", "REGISTRATION_PRIVACY_URL")
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/confidentialite"
    @room = RoomRecorder.new
    @room.participants = [ person("speaker-#{@intruder.id}", "Intrus") ]
    @previous_factories = Rails.configuration.x.room_service_client_factory, Rails.configuration.x.egress_client_factory
    egress = egress_stub
    Rails.configuration.x.room_service_client_factory = -> { @room }
    Rails.configuration.x.egress_client_factory = -> { egress }
  end

  teardown do
    Rails.configuration.x.room_service_client_factory, Rails.configuration.x.egress_client_factory = @previous_factories
    @saved_env.each_key { |key| ENV[key] = @saved_env[key] }
  end

  test "le co-animateur retire l'intrus et régénère le lien : l'ancien est refusé, le nouveau ouvre l'entrée" do
    new_token = nil
    using_session(:co_animateur) do
      sign_in_as(@guest)
      visit webinar_regie_path(@webinar)

      within("[data-testid='regie-participant'][data-identity='speaker-#{@intruder.id}']", wait: 10) do
        click_on "Retirer"
        sleep 0.6 # au-delà de la garde anti double-clic (500 ms)
        click_on "Confirmer le retrait ?"
      end

      within("[data-testid='regie-participants']") do
        assert_selector "[data-testid='regie-removal-notice']", wait: 10,
          text: "Retrait de Intrus confirmé. La personne pourrait revenir par le lien partagé : le régénérer ?"
        assert_equal @old_token, @webinar.reload.share_token, "jamais de régénération d'office"

        click_on "Régénérer le lien intervenants"
        assert_selector "[data-testid='regie-share-link-regenerate'][data-armed='true']"
        sleep 0.6
        click_on "Confirmer la régénération ?"

        assert_selector "[data-testid='regie-share-link-fresh']", wait: 10,
          text: "Le propriétaire du webinaire le transmettra"
        assert_no_selector "[data-testid='regie-removal-notice']"
        assert_no_selector "[data-testid='regie-share-link-url']"
        assert_no_selector "[data-testid='regie-share-link-copy']"
      end
      new_token = @webinar.reload.share_token
      assert_not_equal @old_token, new_token
      assert_no_text new_token
    end
    assert_equal [ "speaker-#{@intruder.id}" ], @room.removed

    using_session(:ancien_lien) do
      visit invitation_path(t: @old_token)
      assert_no_text @webinar.title
      assert_no_field "Ton prénom"
    end

    using_session(:nouveau_lien) do
      visit invitation_path(t: new_token)
      assert_text @webinar.title
      fill_in "Ton prénom", with: "Lise Dupont"
      fill_in "Ton mail", with: "manon@example.test"
      click_on "J'entre"
      assert_selector "#livekit-room", wait: 10
    end
    assert @webinar.speakers.active.exists?(name: "Lise Dupont"), "le nouveau lien fait entrer un intervenant"
  end

  test "le propriétaire régénère après un retrait : nouveau lien masqué, copié complet, gardé à la fin et à la reprise" do
    new_token = nil
    using_session(:proprietaire) do
      sign_in_as(@owner)
      visit webinar_regie_path(@webinar)
      remove_intruder
      within("[data-testid='regie-participants']") do
        click_on "Régénérer le lien intervenants", wait: 10
        sleep 0.6 # au-delà de la garde anti double-clic (500 ms)
        click_on "Confirmer la régénération ?"

        assert_selector "[data-testid='regie-share-link-fresh']", wait: 10
        assert_match %r{/i\?t=#{WebinarLinksHelper::TOKEN_MASK}\z}, find("[data-testid='regie-share-link-url']").value
        new_token = @webinar.reload.share_token
        assert_not_equal @old_token, new_token
        assert_equal "t=#{new_token}", URI(find("[data-testid='regie-share-link-copy']")["data-copy-link"]).query
        assert_no_text new_token
      end

      # Fin puis reprise du direct : le bloc Participants passe replié puis
      # déplié ; le nouveau lien, qui ne revient par aucun GET, reste affiché.
      @webinar.update!(state: "ended", ended_at: Time.current)
      assert_selector "[data-testid='regie-state'][data-state='ended']", wait: 12
      find("[data-testid='regie-participants-section'] > summary").click
      within("[data-testid='regie-participants']") do
        assert_selector "[data-testid='regie-share-link-fresh']"
        assert_equal "t=#{new_token}", URI(find("[data-testid='regie-share-link-copy']")["data-copy-link"]).query
      end
      @webinar.update!(state: "live", ended_at: nil)
      assert_selector "[data-testid='regie-state'][data-state='live']", wait: 12
      within("[data-testid='regie-participants']") { assert_selector "[data-testid='regie-share-link-fresh']" }
    end
  end

  # « Régénérer le lien intervenants » n'est plus un bouton
  # permanent : il est proposé après un retrait.
  test "pas de bouton permanent ; proposé après un retrait ; lien désactivé, la proposition disparaît" do
    @room.participants = [ person("speaker-#{@intruder.id}", "Intrus"), person("viewer-1", "Spectatrice") ]
    using_session(:proprietaire) do
      sign_in_as(@owner)
      visit webinar_regie_path(@webinar)
      within("[data-testid='regie-participants']") do
        assert_selector "[data-testid='regie-participant']", count: 2, wait: 10
        assert_no_selector "[data-testid='regie-share-link-regenerate']"
      end
      remove_intruder
      within("[data-testid='regie-participants']") do
        assert_selector "[data-testid='regie-share-link-regenerate']", text: "Régénérer le lien intervenants", wait: 10
      end

      @webinar.disable_share_token!
      within("[data-testid='regie-participants']") do
        assert_no_selector "[data-testid='regie-share-link-regenerate']", wait: 12
        assert_selector "[data-testid='regie-participant']"
      end
    end
    assert_nil @webinar.reload.share_token, "la régie ne recrée jamais le lien"
  end

  private

  def remove_intruder
    within("[data-testid='regie-participant'][data-identity='speaker-#{@intruder.id}']", wait: 10) do
      click_on "Retirer"
      sleep 0.6 # au-delà de la garde anti double-clic (500 ms)
      click_on "Confirmer le retrait\u00a0?"
    end
    assert_selector "[data-testid='regie-removal-notice']", wait: 10
  end

  def person(identity, name)
    { identity: identity, kind: "STANDARD", name: name, permission: { can_publish: false }, tracks: [] }
  end

  def egress_stub
    stub = Object.new
    def stub.start_room_composite(room_name:, filepath:)
      { egress_id: "EG_#{SecureRandom.hex(3)}", status: :active, raw: nil }
    end
    def stub.list_egress(egress_id:)
      { egress_id: egress_id, status: :active, ended_at: 0, error: nil, raw: nil }
    end
    stub
  end
end
