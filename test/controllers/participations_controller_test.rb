require "test_helper"

# Choix « J'observe » / « Je participe » à l'entrée de la salle : seule
# l'inscription de ce navigateur change, jamais une autre ; le choix lève ou
# baisse la main, il n'ouvre aucune publication.
class ParticipationsControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  setup do
    @host = User.create!(email: "host@example.test", oidc_sub: "host", admin: true)
    @webinar = Webinar.create!(title: "Bootcamp", kind: "bootcamp", starts_at: Time.current, host_sub: @host.oidc_sub,
                               visibility: "published", state: "live", started_at: Time.current)
    @registration = @webinar.registrations.create!(name: "Alice", email: "alice@example.test", confirmed_at: Time.current)
  end

  test "anonyme : refusé, rien ne change" do
    choose "participant"

    assert_response :forbidden
    assert_equal "registration_required", response.parsed_body.fetch("error")
    assert_not @registration.reload.participation_chosen?
    assert_empty HandRaise.all
  end

  test "« Je participe » change l'inscription de ce navigateur et la fait entrer main levée, sans publication" do
    enter_room

    choose "participant"

    assert_response :success
    assert_equal({ "participation" => "participant" }, response.parsed_body)
    assert @registration.reload.participant?
    assert @registration.participation_chosen?
    hand = @webinar.hand_raises.active.sole
    assert_equal [ @registration, "waiting" ], [ hand.registration, hand.state ]
  end

  test "impossible de changer la participation d'une autre inscription" do
    other = @webinar.registrations.create!(name: "Bob", email: "bob@example.test", confirmed_at: Time.current)
    enter_room

    choose "participant", registration_id: other.id, token: other.token

    assert_response :success
    assert @registration.reload.participant?
    other.reload
    assert other.spectator?
    assert_not other.participation_chosen?
    assert_empty @webinar.hand_raises.where(registration: other)
  end

  test "l'inscription d'un autre webinaire ne vaut pas ici" do
    other_webinar = Webinar.create!(title: "Autre café", starts_at: Time.current, host_sub: @host.oidc_sub,
                                    visibility: "published", state: "live", started_at: Time.current)
    other_webinar.registrations.create!(name: "Alice", email: "alice@example.test", confirmed_at: Time.current)
    enter_room

    choose "participant", slug: other_webinar.slug

    assert_response :forbidden
    assert_empty HandRaise.all
  end

  test "un navigateur retiré de la salle ne choisit plus" do
    enter_room
    @registration.remove_from_room!

    choose "participant"

    assert_response :forbidden
    assert_not @registration.reload.participation_chosen?
  end

  test "valeur inconnue : 422, rien ne change" do
    enter_room

    choose "host"

    assert_response :unprocessable_entity
    assert_equal "invalid_participation", response.parsed_body.fetch("error")
    assert_not @registration.reload.participation_chosen?
  end

  test "« J'observe » baisse la main encore en attente" do
    @registration.update!(participation: "participant")
    HandRaiseControl.new(@webinar).raise_declared_hand(@registration)
    enter_room

    choose "spectator"

    assert_response :success
    assert @registration.reload.spectator?
    assert @registration.participation_chosen?
    assert_empty @webinar.hand_raises.active
  end

  # Sans accord à l'image, donner la parole n'appelle pas LiveKit.
  test "« J'observe » garde une parole déjà accordée : seule l'animation la retire" do
    @registration.update!(participation: "participant")
    control = HandRaiseControl.new(@webinar)
    hand = control.raise_declared_hand(@registration)
    control.grant(hand.id)
    enter_room

    choose "spectator"

    assert_response :success
    assert_equal "granted", hand.reload.state
  end

  test "le premier choix gagne : un second envoi ne change rien et renvoie le choix gardé" do
    enter_room
    choose "spectator"

    choose "participant"

    assert_response :success
    assert_equal({ "participation" => "spectator" }, response.parsed_body)
    assert @registration.reload.spectator?
    assert_empty @webinar.hand_raises
  end

  test "« J'observe » puis le jeton de la salle : pas de main levée, même pour un inscrit participant" do
    @registration.update!(participation: "participant")
    enter_room
    choose "spectator"

    with_livekit_keys { post api_token_path, params: { slug: @webinar.slug }, as: :json }

    assert_response :success
    assert_equal "viewer", response.parsed_body.fetch("role")
    assert_empty @webinar.hand_raises
  end

  test "JSON exigé, jeton CSRF exigé" do
    enter_room

    patch public_webinar_participation_path(slug: @webinar.slug), params: { participation: "participant" }
    assert_response :unsupported_media_type

    forgery = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    begin
      choose "participant"
      assert_response :unprocessable_entity
      assert_equal "invalid_authenticity_token", response.parsed_body.fetch("error")
    ensure
      ActionController::Base.allow_forgery_protection = forgery
    end
    assert_not @registration.reload.participation_chosen?
  end

  # Page de la salle : le choix n'est demandé qu'à qui ne l'a jamais fait,
  # pré-sélectionné sur la valeur de l'inscription.
  test "la salle demande le choix une fois, pré-sélectionné, puis s'ouvre directement" do
    @registration.update!(participation: "participant")
    enter_room

    get public_webinar_path(slug: @webinar.slug)
    assert_select "[data-role=participation-choice] form[data-participation-url=?]",
                  public_webinar_participation_path(slug: @webinar.slug)
    assert_select "input[name=participation][value=participant][checked]"
    assert_select "input[name=participation][value=spectator]:not([checked])"
    assert_select "#livekit-room[data-viewer-hand-raises-url]"
    # Libellés simples, sans main levée ni admission (choix produit).
    assert_select "label.radio", text: "J'observe — j'ai le chat"
    assert_select "label.radio", text: "Je participe — caméra et micro"
    assert_select "#livekit-room[data-participant-waiting-message=?]", "On vous ouvre la caméra et le micro dans un instant."
    assert_select "#livekit-room[data-participant-cancel-label=?]", "Je préfère observer"
    assert_select "#livekit-room[data-recording-notice=?]",
                  "Si la parole vous est donnée, votre image et votre voix sont enregistrées et votre voix est transcrite"
    assert_no_match(/main levée|admet/i, css_select("[data-role=participation-choice]").text)

    choose "participant"
    get public_webinar_path(slug: @webinar.slug)
    assert_select "[data-role=participation-choice]", count: 0
    assert_select "#livekit-room"
  end

  test "l'animation n'a jamais l'écran de choix" do
    enter_room
    sign_in_as(@host)

    get public_webinar_path(slug: @webinar.slug)

    assert_select "#livekit-room"
    assert_select "[data-role=participation-choice]", count: 0
  end

  test "un intervenant (/join) n'a jamais l'écran de choix, même avec une inscription sans choix" do
    speaker = @webinar.speakers.create!(name: "Basile")
    enter_room

    get join_webinar_path(slug: @webinar.slug, t: speaker.token)

    assert_response :success
    assert_select "#livekit-room[data-speaker-token]"
    assert_select "[data-role=participation-choice]", count: 0
  end

  private

  def enter_room
    post confirm_registration_path(@registration.token)
  end

  def with_livekit_keys
    previous = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET")
    ENV["LIVEKIT_API_KEY"] = "APIfake"
    ENV["LIVEKIT_API_SECRET"] = "sekret-32bytes-long-enough-abcdef"
    yield
  ensure
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET].each { |key| ENV[key] = previous[key] }
  end

  def choose(participation, slug: @webinar.slug, **forged)
    patch public_webinar_participation_path(slug: slug), params: { participation: participation, **forged }, as: :json
  end
end
