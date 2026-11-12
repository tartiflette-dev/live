require "test_helper"

# Identité PROVISOIRE : une identité ouverte par
# l'accès immédiat, sans boîte prouvée, reste provisoire et n'est jamais
# promue en identité confirmée d'un autre navigateur. Chaque navigateur est
# une session distincte, construite par les vrais parcours (inscription
# pendant le direct, lien du mail, retrait depuis la régie).
class ProvisionalIdentityTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "fake-secret-at-least-32-characters-long-xx"

  setup do
    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "REGISTRATION_PRIVACY_URL", "CRM_SYNC_ENABLED")
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/confidentialite"
    @saved_factory = Rails.configuration.x.room_service_client_factory
    room = LivekitPacketDelivery::RoomRecorder.new
    Rails.configuration.x.room_service_client_factory = -> { room }

    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 10.minutes.ago, host_sub: "sub-marc",
                               visibility: "published", state: "live", started_at: 10.minutes.ago)
  end

  teardown do
    Rails.configuration.x.room_service_client_factory = @saved_factory
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET REGISTRATION_PRIVACY_URL CRM_SYNC_ENABLED].each { |key| ENV[key] = @saved_env[key] }
  end

  # WARN-1 : l'intrus prend l'adresse neuve de la victime pendant le direct
  # et se fait retirer ; la victime s'inscrit ensuite et entre.
  test "intrus retiré sous l'adresse neuve d'une victime : la victime s'inscrit, confirme et entre" do
    intruder = browser
    register(intruder, "Intrus", "victime@example.test")
    provisional = @webinar.registrations.find_by!(email: "victime@example.test")
    ParticipantModeration.new(@webinar, "viewer-#{provisional.id}").remove

    assert provisional.reload.retired?, "retirée sans être confirmée : pierre tombale"
    assert_equal 403, api_token(intruder).status, "le navigateur de l'intrus reste retiré"

    victim = browser
    register(victim, "Victime", "victime@example.test")
    assert_equal public_webinar_path(@webinar.slug), URI(victim.response.location).path, "adresse libérée : accès immédiat"
    mine = @webinar.registrations.find_by!(email: "victime@example.test")
    assert_not_equal provisional, mine

    victim.post confirm_registration_path(mine.token)
    assert_equal 302, victim.response.status
    assert mine.reload.confirmed?
    assert_nil mine.room_removed_at
    assert_equal "viewer-#{mine.id}", api_token(victim).parsed_body.fetch("identity")
  end

  # WARN-2 : la victime confirme depuis son propre navigateur pendant que
  # l'intrus occupe l'identité ouverte sous son adresse.
  test "la victime confirme depuis un autre navigateur : pierre tombale et inscription neuve, rien de l'intrus sur sa fiche" do
    ENV["CRM_SYNC_ENABLED"] = "1"
    intruder = browser
    register(intruder, "Intrus", "victime@example.test", participation: "participant")
    provisional = @webinar.registrations.find_by!(email: "victime@example.test")
    intruder.post public_webinar_messages_path(@webinar.slug), params: { body: "Message de l'intrus" }, as: :json
    assert_equal 201, intruder.response.status

    victim = browser
    victim.get confirm_registration_path(provisional.token)
    assert page_nodes(victim, "[data-role='registration-hand-over'] input[name='name']").any?
    assert_no_match(/registration_id/, victim.response.headers["set-cookie"].to_s, "le GET ne pose rien")

    victim.post confirm_registration_path(provisional.token)
    assert_equal 422, victim.response.status, "il faut un prénom"
    assert_not provisional.reload.retired?

    assert page_nodes(victim, "[data-role='registration-hand-over-participation'] input[value='participant']").any?
    assert page_nodes(victim, "[data-role='registration-hand-over-participation'] label.radio").any?
    assert_enqueued_with(job: CrmSyncJob) do
      assert_enqueued_email_with(RegistrationMailer, :access, args: ->(args) { args.first.email == "victime@example.test" }) do
        victim.post confirm_registration_path(provisional.token), params: { name: "Victime", participation: "participant" }
      end
    end
    assert_equal public_webinar_path(@webinar.slug), URI(victim.response.location).path

    fresh = @webinar.registrations.find_by!(email: "victime@example.test")
    provisional.reload
    assert provisional.retired?
    assert_not provisional.crm_sync_eligible?
    assert_equal [ "Victime", "participant", true ], [ fresh.name, fresh.participation, fresh.confirmed? ]
    assert_empty Message.where(author_identity: "viewer-#{fresh.id}"), "la discussion de l'intrus n'est pas sur sa fiche"
    assert_equal "viewer-#{fresh.id}", api_token(victim).parsed_body.fetch("identity")
    assert_equal "viewer-#{provisional.id}", api_token(intruder).parsed_body.fetch("identity"),
      "l'intrus reste sur la pierre tombale"

    # Lien privé : le cookie de la pierre tombale ne rattache rien.
    intruder.post invitation_create_path(t: @webinar.generate_share_token!),
      params: { invitation: { name: "Intrus", email: "victime@example.test", participation: "participant" } },
      env: { "REMOTE_ADDR" => ip_of(intruder) }
    assert_nil @webinar.speakers.find_by!(name: "Intrus").registration

    # Retrait ultérieur de l'intrus : sans effet sur la victime.
    ParticipantModeration.new(@webinar, "viewer-#{provisional.id}").remove
    assert_nil fresh.reload.room_removed_at
    assert_equal 200, api_token(victim).status
    assert_equal 403, api_token(intruder).status
  end

  test "confirmation depuis le navigateur qui porte l'identité provisoire : confirmation normale" do
    mine = browser
    register(mine, "Inès", "ines@example.test")
    registration = @webinar.registrations.find_by!(email: "ines@example.test")

    mine.get confirm_registration_path(registration.token)
    assert page_nodes(mine, "[data-role='registration-confirm'] form[action='#{confirm_registration_path(registration.token)}']").any?
    assert_empty page_nodes(mine, "[data-role='registration-hand-over']")

    mine.post confirm_registration_path(registration.token)
    assert registration.reload.confirmed?
    assert_not registration.retired?
    assert_equal 1, @webinar.registrations.count
    assert_equal "viewer-#{registration.id}", api_token(mine).parsed_body.fetch("identity")
  end

  test "un cookie d'inscription sans le bon secret ne désigne personne" do
    mine = browser
    register(mine, "Inès", "ines@example.test")
    registration = @webinar.registrations.find_by!(email: "ines@example.test")
    assert_equal 200, api_token(mine).status

    registration.update!(identity_secret: SecureRandom.hex(24))
    assert_equal 403, api_token(mine).status

    legacy = browser
    forge_registration_cookie(legacy, registration.id)
    assert_equal 403, api_token(legacy).status, "format d'avant (id seul) : refusé"

    forged = browser
    forge_registration_cookie(forged, [ registration.id, "pas-le-bon-secret" ])
    assert_equal 403, api_token(forged).status
  end

  test "reprise : un choix inconnu est refusé, rien ne change" do
    register(browser, "Intrus", "victime@example.test")
    provisional = @webinar.registrations.find_by!(email: "victime@example.test")

    victim = browser
    victim.post confirm_registration_path(provisional.token), params: { name: "Victime", participation: "host" }
    assert_equal 422, victim.response.status
    assert_not provisional.reload.retired?
  end

  # Un cookie posé avant le secret (id seul) ne donne
  # plus accès, mais un ancien spectateur RETIRÉ reste détecté.
  test "ancien cookie (id seul) d'une inscription retirée : le navigateur reste retiré, et tracé" do
    removed = @webinar.registrations.create!(name: "Ancien", email: "ancien@example.test", confirmed_at: 1.day.ago)
    removed.remove_from_room!

    legacy = browser
    forge_registration_cookie(legacy, removed.id)
    legacy.get invitation_path(t: @webinar.generate_share_token!)
    assert_equal 403, legacy.response.status
    assert_match(/room_removed_#{@webinar.id}=/, legacy.response.headers["set-cookie"].to_s)
  end

  test "le domaine réservé .invalid est refusé : inscription publique, API, lien privé" do
    squatter = browser
    register(squatter, "Squatteur", "retire-#{"a" * 32}@retire.invalid")
    assert_equal 422, squatter.response.status

    squatter.post invitation_create_path(t: @webinar.generate_share_token!),
      params: { invitation: { name: "Squatteur", email: "x@retire.invalid", participation: "spectator" } },
      env: { "REMOTE_ADDR" => ip_of(squatter) }
    assert_equal 422, squatter.response.status
    assert_empty Registration.where("email LIKE ?", "%.invalid")

    submission = RegistrationSubmission.new(name: "Squatteur", email: "x@retire.invalid", slugs: [ @webinar.slug ])
    assert_not submission.valid?
    assert_includes submission.errors.details[:email], { error: :invalid }
  end

  # Cas limite : l'intervenant de la victime,
  # rattaché par /rattacher sous l'adresse qu'un intrus a ouverte en identité
  # provisoire, ne reste pas accroché à la pierre tombale de l'intrus.
  test "intrus en identité provisoire, la victime rattache son intervenant : il suit l'inscription neuve, le retirer bannit l'adresse" do
    intruder = browser
    register(intruder, "Intrus", "o@example.test")
    provisional = @webinar.registrations.find_by!(email: "o@example.test")

    victim = browser
    victim.post invitation_create_path(t: @webinar.generate_share_token!),
      params: { invitation: { name: "Olga", email: "o@example.test", participation: "participant" } },
      env: { "REMOTE_ADDR" => ip_of(victim) }
    speaker = @webinar.speakers.find_by!(name: "Olga")
    assert_nil speaker.registration
    victim.post confirm_speaker_link_path(t: speaker.link_token)
    fresh = speaker.reload.registration
    assert_not_equal provisional, fresh
    assert_not fresh.confirmed?

    assert provisional.reload.retired?
    assert_equal "viewer-#{provisional.id}", api_token(intruder).parsed_body.fetch("identity"), "l'intrus reste sur la pierre tombale"
    ParticipantModeration.new(@webinar, "viewer-#{provisional.id}").remove
    assert_equal 403, api_token(intruder).status
    assert_equal fresh, speaker.reload.registration, "l'intervenant ne suit pas la pierre tombale"
    assert_nil fresh.reload.room_removed_at

    ParticipantModeration.new(@webinar, "speaker-#{speaker.id}").remove
    assert fresh.reload.room_removed_at, "le retirer bannit bien l'adresse"
    assert_not fresh.retired?
    returning = browser
    register(returning, "Olga", "o@example.test")
    assert_not_equal public_webinar_path(@webinar.slug), URI(returning.response.location.to_s).path
    assert_equal [ fresh ], @webinar.registrations.where(email: "o@example.test").to_a
  end

  # Parcours légitime : inscrite sur l'ordinateur pendant le direct, elle
  # confirme sur son téléphone. Le téléphone reçoit une inscription
  # confirmée ; les échanges de l'ordinateur restent sur l'identité
  # provisoire, hors de sa fiche (docs/public-registration.md).
  test "je m'inscris sur l'ordinateur, je confirme sur le téléphone : inscription confirmée utilisable sur le téléphone" do
    computer = browser
    register(computer, "Inès", "ines@example.test")
    computer.post public_webinar_messages_path(@webinar.slug), params: { body: "Depuis l'ordinateur" }, as: :json
    provisional = @webinar.registrations.find_by!(email: "ines@example.test")

    phone = browser
    phone.post confirm_registration_path(provisional.token), params: { name: "Inès" }

    confirmed = @webinar.registrations.find_by!(email: "ines@example.test")
    assert confirmed.confirmed?
    assert_equal "viewer-#{confirmed.id}", api_token(phone).parsed_body.fetch("identity")
    assert_equal "viewer-#{provisional.id}", api_token(computer).parsed_body.fetch("identity"),
      "l'ordinateur garde sa place, sous l'identité provisoire"
    assert_empty Message.where(author_identity: "viewer-#{confirmed.id}"), "les échanges de l'ordinateur ne suivent pas"
  end

  private

  def browser
    session = open_session
    session.instance_variable_set(:@test_ip, "10.#{rand(0..255)}.#{rand(0..255)}.#{rand(1..254)}")
    session
  end

  def ip_of(session) = session.instance_variable_get(:@test_ip)

  def register(session, name, email, participation: "spectator")
    session.post public_webinar_registrations_path(@webinar.slug),
      params: { registration: { name: name, email: email, participation: participation } },
      env: { "REMOTE_ADDR" => ip_of(session) }
  end

  def api_token(session)
    session.post "/api/token", params: { slug: @webinar.slug }, as: :json
    session.response
  end

  def page_nodes(session, selector)
    Nokogiri::HTML(session.response.body).css(selector)
  end

  # Cookie chiffré tel que le poserait l'application, avec une valeur choisie.
  def forge_registration_cookie(session, value)
    jar = ActionDispatch::Request.new(Rails.application.env_config.deep_dup).cookie_jar
    jar.encrypted[:registration_id] = value
    session.cookies[:registration_id] = jar[:registration_id]
  end
end
