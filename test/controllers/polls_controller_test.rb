require "test_helper"

# Sondages côté animation (régie) : plan, lancement,
# résultats, détail nominatif. Réservé au propriétaire, aux animateurs du
# projet et aux co-animateurs ; 404 pour les autres. La diffusion LiveKit est
# remplacée par un enregistreur.
class PollsControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  class Broadcaster
    attr_reader :calls

    def initialize
      @calls = []
    end

    def send_data(**arguments)
      @calls << JSON.parse(arguments.fetch(:data))
      {}
    end
  end

  setup do
    @owner = User.create!(email: "marc@example.test", oidc_sub: "sub-marc")
    @guest = User.create!(email: "co@partenaire.test", oidc_sub: "sub-co", email_verified: true,
                          email_verified_for: "co@partenaire.test")
    @webinar = Webinar.create!(title: "Café IA #8", host_sub: @owner.oidc_sub, visibility: "published",
                               state: "live", starts_at: 1.hour.ago, started_at: 14.minutes.ago)
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
    @poll = @webinar.polls.create!(position: 1, kind: "choice", label: "A, B ou C ?", options: %w[A B C],
                                   planned_minute: 10, note: "après la démo")
    @broadcaster = Broadcaster.new
    @previous_factory = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { @broadcaster }
  end

  teardown do
    Rails.configuration.x.room_service_client_factory = @previous_factory
    ActionController::Base.allow_forgery_protection = false
  end

  test "plan : ordre, minute prévue, aide-mémoire, état du direct pour le chrono" do
    sign_in_as(@owner)
    get webinar_polls_path(@webinar), as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal [ "live", @webinar.started_at.utc.iso8601 ], body.fetch("webinar").values_at("state", "started_at")
    poll = body.fetch("polls").sole
    assert_equal [ "A, B ou C ?", 10, "après la démo", "planned", true, 0 ],
                 poll.values_at("label", "planned_minute", "note", "state", "editable", "responses_count")
  end

  test "créer au plan (choix, échelle, réponse courte), position en fin de plan, texte échappé" do
    sign_in_as(@owner)
    post webinar_polls_path(@webinar), params: { poll: { kind: "scale", label: "<b>Confiance</b> ?",
                                                         options: { min: 1, max: 5, min_label: "nulle", max_label: "totale" } } }, as: :json
    assert_response :created
    assert_equal [ 2, "scale", { "min" => 1, "max" => 5, "min_label" => "nulle", "max_label" => "totale" } ],
                 response.parsed_body.fetch("poll").values_at("position", "kind", "options")
    refute_includes response.body, "<b>"

    post webinar_polls_path(@webinar), params: { poll: { kind: "short_text", label: "Un mot ?", position: 1,
                                                         opened_at: Time.current } }, as: :json
    assert_response :created
    created = Poll.find(response.parsed_body.dig("poll", "id"))
    assert_equal [ 3, nil ], [ created.position, created.opened_at ], "position et cycle ne se posent pas par le client"

    post webinar_polls_path(@webinar), params: { poll: { kind: "choice", label: "Seul ?", options: [ "A" ] } }, as: :json
    assert_response :unprocessable_entity
    assert_equal "invalid_poll", response.parsed_body.fetch("error")
    assert_empty @broadcaster.calls
  end

  test "à la volée : créer et lancer d'un geste, diffusé aussitôt ; refusé hors direct sans rien créer" do
    sign_in_as(@guest)
    post webinar_polls_path(@webinar), params: { open: true, poll: { kind: "choice", label: "Vite ?", options: %w[Oui Non] } }, as: :json

    assert_response :created
    assert_equal "sent", response.parsed_body.fetch("broadcast")
    assert_equal "Vite ?", @broadcaster.calls.sole.dig("poll", "label")

    @webinar.update!(state: "ended")
    assert_no_difference "Poll.count" do
      post webinar_polls_path(@webinar), params: { open: true, poll: { kind: "short_text", label: "Trop tard ?" } }, as: :json
    end
    assert_response :conflict
    assert_equal "webinar_not_live", response.parsed_body.fetch("error")
  end

  test "modifier et supprimer tant que jamais lancé ; ensuite 409" do
    sign_in_as(@owner)
    patch webinar_poll_path(@webinar, @poll), params: { poll: { label: "A ou B ?", options: %w[A B], planned_minute: 20 } }, as: :json
    assert_response :success
    assert_equal [ "A ou B ?", %w[A B], 20 ], @poll.reload.values_at(:label, :options, :planned_minute)

    post open_webinar_poll_path(@webinar, @poll), as: :json
    patch webinar_poll_path(@webinar, @poll), params: { poll: { label: "Changée" } }, as: :json
    assert_response :conflict
    assert_equal "A ou B ?", @poll.reload.label
    delete webinar_poll_path(@webinar, @poll), as: :json
    assert_response :conflict
    assert_equal "already_opened", response.parsed_body.fetch("error")

    planned = @webinar.polls.create!(position: 2, kind: "short_text", label: "Un mot ?")
    delete webinar_poll_path(@webinar, planned), as: :json
    assert_response :no_content
    assert_not Poll.exists?(planned.id)
  end

  test "réordonner : la liste complète des sondages du webinaire, sinon refus" do
    second = @webinar.polls.create!(position: 2, kind: "short_text", label: "Second ?")
    sign_in_as(@owner)

    patch reorder_webinar_polls_path(@webinar), params: { ids: [ second.id, @poll.id ] }, as: :json
    assert_response :success
    assert_equal [ second.id, @poll.id ], response.parsed_body.fetch("polls").map { |poll| poll.fetch("id") }

    foreign = Webinar.create!(title: "Autre", host_sub: "autre", starts_at: 1.hour.ago)
                     .polls.create!(position: 1, kind: "short_text", label: "Ailleurs ?")
    patch reorder_webinar_polls_path(@webinar), params: { ids: [ second.id, foreign.id ] }, as: :json
    assert_response :unprocessable_entity
    assert_equal [ second.id, @poll.id ], @webinar.polls.reload.ids
  end

  test "cycle : ouvrir, montrer, masquer, fermer — chaque changement diffusé une fois, double clic sans effet" do
    sign_in_as(@owner)
    post open_webinar_poll_path(@webinar, @poll), as: :json
    assert_response :success
    @poll.respond!(identity: "viewer-1", name: "Alice", value: [ 1 ])

    post show_results_webinar_poll_path(@webinar, @poll), as: :json
    post show_results_webinar_poll_path(@webinar, @poll), as: :json
    assert_equal "unchanged", response.parsed_body.fetch("broadcast")
    post close_webinar_poll_path(@webinar, @poll), as: :json
    post hide_results_webinar_poll_path(@webinar, @poll), as: :json
    assert_response :success

    states = @broadcaster.calls.map { |packet| packet["poll"]&.values_at("open", "results") }
    assert_equal [ [ true, nil ], [ true, { "respondents" => 1, "counts" => [ 0, 1, 0 ] } ],
                   [ false, { "respondents" => 1, "counts" => [ 0, 1, 0 ] } ], nil ], states
    assert(@broadcaster.calls.all? { |packet| packet["topic"] == "poll" && packet["at"].present? })
  end

  test "réponses courtes : « montrer » refusé tant que le sondage est ouvert, la console le sait" do
    text = @webinar.polls.create!(position: 2, kind: "short_text", label: "Un mot ?")
    sign_in_as(@owner)
    post open_webinar_poll_path(@webinar, text), as: :json
    assert_equal false, response.parsed_body.dig("poll", "results_showable")

    post show_results_webinar_poll_path(@webinar, text), as: :json
    assert_response :conflict
    assert_equal "poll_open", response.parsed_body.fetch("error")
    assert_nil text.reload.results_shown_at
  end

  test "ouvrir hors direct : 409, rien diffusé" do
    @webinar.update!(state: "draft")
    sign_in_as(@owner)
    post open_webinar_poll_path(@webinar, @poll), as: :json
    assert_response :conflict
    assert_equal "webinar_not_live", response.parsed_body.fetch("error")
    assert_empty @broadcaster.calls
  end

  test "détail : qui a répondu quoi, par option" do
    @poll.open!
    @poll.respond!(identity: "viewer-1", name: "Alice", value: [ 0 ])
    @poll.respond!(identity: "speaker-2", name: "Basile", value: [ 2 ])
    sign_in_as(@guest)

    get webinar_poll_path(@webinar, @poll), as: :json
    assert_response :success
    detail = response.parsed_body.fetch("poll")
    assert_equal [ [ "Alice" ], [], [ "Basile" ] ], detail.fetch("respondents")
    assert_equal({ "respondents" => 2, "counts" => [ 1, 0, 1 ] }, detail.fetch("results"))
  end

  test "sans session : connexion ; animateur non propriétaire ni invité, ou sondage d'un autre webinaire : 404" do
    get webinar_polls_path(@webinar), as: :json
    assert_redirected_to sign_in_path

    sign_in_as(User.create!(email: "passant@example.test", oidc_sub: "sub-passant"))
    get webinar_polls_path(@webinar), as: :json
    assert_response :not_found
    post open_webinar_poll_path(@webinar, @poll), as: :json
    assert_response :not_found
    assert_nil @poll.reload.opened_at

    other = Webinar.create!(title: "Autre", host_sub: @owner.oidc_sub, state: "live", starts_at: 1.hour.ago)
    foreign = other.polls.create!(position: 1, kind: "short_text", label: "Ailleurs ?")
    sign_in_as(@owner)
    post open_webinar_poll_path(@webinar, foreign), as: :json
    assert_response :not_found
    assert_nil foreign.reload.opened_at
    assert_empty @broadcaster.calls
  end

  test "CSRF actif : sans jeton, refus JSON 422 et rien ne change" do
    sign_in_as(@owner)
    ActionController::Base.allow_forgery_protection = true

    post open_webinar_poll_path(@webinar, @poll), as: :json
    assert_response :unprocessable_entity
    assert_equal "invalid_authenticity_token", response.parsed_body.fetch("error")
    assert_nil @poll.reload.opened_at
  end
end
