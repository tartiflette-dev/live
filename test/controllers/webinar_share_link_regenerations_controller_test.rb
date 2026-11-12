require "test_helper"

# Régénérer le lien participants privé depuis la régie : toute
# l'animation du webinaire ferme la porte qu'une personne retirée garderait
# par le lien partagé ; régénérer SEULEMENT, jamais créer ni désactiver.
class WebinarShareLinkRegenerationsControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  setup do
    @owner = User.create!(email: "luc@example.test", oidc_sub: "sub-luc")
    @guest = User.create!(email: "co@partenaire.test", oidc_sub: "sub-co", email_verified: true, email_verified_for: "co@partenaire.test")
    @project_host = User.create!(email: "projet@example.test", oidc_sub: "sub-projet", admin: true)
    @stranger = User.create!(email: "autre@example.test", oidc_sub: "sub-autre")
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: Time.current, host_sub: @owner.oidc_sub,
                               visibility: "published", state: "live", started_at: Time.current)
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
    @old_token = @webinar.generate_share_token!
    @previous_privacy = ENV["REGISTRATION_PRIVACY_URL"]
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/confidentialite"
  end

  teardown do
    ENV["REGISTRATION_PRIVACY_URL"] = @previous_privacy
    ActionController::Base.allow_forgery_protection = false
  end

  test "propriétaire : nouveau lien en JSON, masqué et complet, l'ancien meurt" do
    sign_in_as(@owner)

    post webinar_share_link_regeneration_path(@webinar), as: :json

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    new_token = @webinar.reload.share_token
    assert_not_equal @old_token, new_token
    assert_equal({ "link" => invitation_url(t: new_token),
                   "masked_link" => "www.example.com/i?t=#{WebinarLinksHelper::TOKEN_MASK}",
                   "fingerprint" => @webinar.share_token_fingerprint },
                 response.parsed_body)
    assert_nil Webinar.find_by_active_share_token(@old_token)
    assert_equal @webinar, Webinar.find_by_active_share_token(new_token)
  end

  test "animateur du projet et co-animateur invité régénèrent, comme le propriétaire" do
    [ @project_host, @guest ].each do |animateur|
      before = @webinar.reload.share_token
      sign_in_as(animateur, email_verified: true)

      post webinar_share_link_regeneration_path(@webinar), as: :json

      assert_response :success, animateur.email
      assert_not_equal before, @webinar.reload.share_token, animateur.email
      assert_nil Webinar.find_by_active_share_token(before)
    end
  end

  # La doc promet « fermer cette porte pendant le
  # direct ». Hors direct, régénérer couperait les intervenants invités qui
  # n'ont pas encore cliqué : le co-animateur invité ne le peut pas, comme
  # pour la modération ; propriétaire et animateur du projet, si.
  test "hors direct, le co-animateur invité ne régénère pas : 403 not_live, l'ancien lien vit" do
    sign_in_as(@guest, email_verified: true)

    %w[draft ended].each do |state|
      @webinar.update!(state: state)
      post webinar_share_link_regeneration_path(@webinar), as: :json

      assert_response :forbidden, state
      assert_equal({ "error" => "not_live" }, response.parsed_body)
      assert_equal @old_token, @webinar.reload.share_token, state
      assert_equal @webinar, Webinar.find_by_active_share_token(@old_token)
    end
  end

  test "hors direct, propriétaire et animateur du projet régénèrent toujours" do
    @webinar.update!(state: "draft", started_at: nil, starts_at: 2.days.from_now)
    [ @owner, @project_host ].each do |animateur|
      before = @webinar.reload.share_token
      sign_in_as(animateur, email_verified: true)

      post webinar_share_link_regeneration_path(@webinar), as: :json

      assert_response :success, animateur.email
      assert_not_equal before, @webinar.reload.share_token, animateur.email
    end
  end

  test "co-animateur invité : il ferme la porte sans recevoir le nouveau lien" do
    sign_in_as(@guest, email_verified: true)

    post webinar_share_link_regeneration_path(@webinar), as: :json

    assert_response :success
    assert_equal({ "fingerprint" => @webinar.reload.share_token_fingerprint }, response.parsed_body)
    assert_nil Webinar.find_by_active_share_token(@old_token)
    assert_no_match(/#{Regexp.escape(@webinar.share_token)}/, response.body)
  end

  test "animateur du projet : reçoit le nouveau lien, comme le propriétaire" do
    sign_in_as(@project_host, email_verified: true)

    post webinar_share_link_regeneration_path(@webinar), as: :json

    assert_response :success
    assert_equal invitation_url(t: @webinar.reload.share_token), response.parsed_body.fetch("link")
  end

  test "ancien lien refusé, nouveau lien ouvert" do
    sign_in_as(@owner)
    post webinar_share_link_regeneration_path(@webinar), as: :json
    new_link = response.parsed_body.fetch("link")

    get invitation_path(t: @old_token)
    assert_response :not_found

    get new_link
    assert_response :success
    assert_select "input[name='invitation[name]']"
  end

  test "les intervenants déjà entrés par l'ancien lien gardent leur accès" do
    entered = open_session
    entered.post invitation_create_path(t: @old_token),
      params: { invitation: { name: "Manon", email: "manon@example.test", participation: "participant" } },
      env: { "REMOTE_ADDR" => "10.81.#{rand(0..255)}.#{rand(1..254)}" }
    speaker = @webinar.speakers.find_by!(name: "Manon")

    sign_in_as(@guest, email_verified: true)
    post webinar_share_link_regeneration_path(@webinar), as: :json
    assert_response :success

    assert_nil speaker.reload.revoked_at
    assert_equal [ @webinar, speaker ], Webinar.find_for_speaker(slug: @webinar.slug, token: speaker.token)
    entered.get invitation_path(t: @old_token)
    assert_equal 404, entered.response.status, "le lien partagé est mort, même pour elle"
  end

  test "sans lien actif : 409, aucun lien créé, même par le propriétaire" do
    @webinar.disable_share_token!

    [ @guest, @owner ].each do |animateur|
      sign_in_as(animateur, email_verified: true)
      post webinar_share_link_regeneration_path(@webinar), as: :json

      assert_response :conflict
      assert_equal({ "error" => "no_share_link" }, response.parsed_body)
      assert_nil @webinar.reload.share_token
    end
  end

  test "le co-animateur ne crée ni ne désactive le lien par la page du webinaire" do
    sign_in_as(@guest, email_verified: true)

    delete webinar_share_link_path(@webinar)
    assert_response :not_found
    assert_equal @old_token, @webinar.reload.share_token

    @webinar.disable_share_token!
    post webinar_share_link_path(@webinar)
    assert_response :not_found
    assert_nil @webinar.reload.share_token
  end

  test "anonyme : 403, le lien ne change pas" do
    post webinar_share_link_regeneration_path(@webinar), as: :json

    assert_response :forbidden
    assert_equal({ "error" => "animateur_session_required" }, response.parsed_body)
    assert_equal @old_token, @webinar.reload.share_token
  end

  test "intervenant (lien personnel, cookie du lien partagé) sans session animateur : 403" do
    speaker_browser = open_session
    speaker_browser.post invitation_create_path(t: @old_token),
      params: { invitation: { name: "Louis", email: "louis@example.test", participation: "participant" } },
      env: { "REMOTE_ADDR" => "10.82.#{rand(0..255)}.#{rand(1..254)}" }
    speaker = @webinar.speakers.find_by!(name: "Louis")

    speaker_browser.post webinar_share_link_regeneration_path(@webinar), params: { t: speaker.token },
      headers: { "X-Speaker-Token" => speaker.token }, as: :json

    assert_equal 403, speaker_browser.response.status
    assert_equal @old_token, @webinar.reload.share_token
  end

  test "spectateur (inscription confirmée en cookie) sans session animateur : 403" do
    viewer = @webinar.registrations.create!(name: "Inès", email: "ines@example.test", confirmed_at: Time.current)
    post confirm_registration_path(viewer.token)

    post webinar_share_link_regeneration_path(@webinar), as: :json

    assert_response :forbidden
    assert_equal @old_token, @webinar.reload.share_token
  end

  test "connecté sans rôle sur ce webinaire : 404, en direct comme hors direct" do
    sign_in_as(@stranger)

    %w[live draft ended].each do |state|
      @webinar.update!(state: state)
      post webinar_share_link_regeneration_path(@webinar), as: :json

      # 404 avant toute lecture de l'état : `not_live` ne renseigne pas un tiers.
      assert_response :not_found, state
      assert_equal @old_token, @webinar.reload.share_token
    end
  end

  test "webinaire d'un autre propriétaire : 404, son lien ne change pas" do
    other_owner = User.create!(email: "eve@example.test", oidc_sub: "sub-eve")
    foreign = Webinar.create!(title: "Ailleurs", starts_at: Time.current, host_sub: other_owner.oidc_sub)
    foreign_token = foreign.generate_share_token!
    sign_in_as(@guest, email_verified: true)

    post webinar_share_link_regeneration_path(foreign), as: :json

    assert_response :not_found
    assert_equal foreign_token, foreign.reload.share_token
  end

  test "CSRF actif : sans jeton, refus JSON 422 et le lien ne change pas" do
    sign_in_as(@owner)
    ActionController::Base.allow_forgery_protection = true

    post webinar_share_link_regeneration_path(@webinar), as: :json

    assert_response :unprocessable_entity
    assert_equal "invalid_authenticity_token", response.parsed_body.fetch("error")
    assert_equal @old_token, @webinar.reload.share_token
  end

  # Requête, contrôleur et SQL (l'UPDATE du jeton, binds compris) : chaque
  # journal a son logger, posé au démarrage.
  test "ni l'ancien ni le nouveau jeton dans les journaux" do
    sign_in_as(@owner)
    log = capture_logs { post webinar_share_link_regeneration_path(@webinar), as: :json }

    assert_response :success
    assert_match(/Processing by WebinarShareLinkRegenerationsController#create/, log, "journal non capturé : test vide")
    assert_match(/UPDATE "webinars"/, log, "SQL non capturé : test vide")
    [ @old_token, @webinar.reload.share_token ].each do |token|
      assert_no_match(/#{Regexp.escape(token)}/, log)
    end
  end

  private

  LOGGED_FRAMEWORKS = [ Rails, ActionController::Base, ActiveRecord::Base ].freeze

  def capture_logs
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io).tap { |l| l.level = :debug }
    originals = LOGGED_FRAMEWORKS.map(&:logger)
    LOGGED_FRAMEWORKS.each { |framework| framework.logger = logger }
    yield
    io.string
  ensure
    LOGGED_FRAMEWORKS.zip(originals).each { |framework, original| framework.logger = original }
  end
end
