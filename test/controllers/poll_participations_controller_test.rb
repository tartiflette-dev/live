require "test_helper"

# Sondages côté participants : mêmes participants que la
# discussion (RoomAuthor), identité et nom décidés serveur, réponse
# remplaçable tant que le sondage est ouvert, compteur regroupé à la seconde.
class PollParticipationsControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn
  include ActiveJob::TestHelper

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
    @host = User.create!(email: "marc@example.test", oidc_sub: "host-#{SecureRandom.hex(4)}")
    @webinar = Webinar.create!(title: "Café IA #8", host_sub: @host.oidc_sub, visibility: "published",
                               state: "live", starts_at: 1.hour.ago)
    @registration = @webinar.registrations.create!(name: "Alice", email: "alice@example.test")
    @poll = @webinar.polls.create!(position: 1, kind: "choice", label: "A, B ou C ?", options: %w[A B C])
    @poll.open!
    @broadcaster = Broadcaster.new
    @previous_factory = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.room_service_client_factory = -> { @broadcaster }
    @tally_dir = Dir.mktmpdir("poll-tally")
    PollBroadcast.tally_counter = RegistrationRateLimitStore.new(@tally_dir)
  end

  teardown do
    PollBroadcast.tally_counter = nil
    FileUtils.remove_entry(@tally_dir)
    Rails.configuration.x.room_service_client_factory = @previous_factory
    ActionController::Base.allow_forgery_protection = false
  end

  test "spectateur confirmé : voit le sondage ouvert sans résultat, répond, change d'avis" do
    confirm_viewer
    get current_public_webinar_poll_path(@webinar.slug), as: :json
    assert_response :success
    body = response.parsed_body
    assert_equal [ @poll.id, true, nil, 0 ], body.fetch("poll").values_at("id", "open", "results", "responses_count")
    assert_nil body.fetch("my_response")
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/, body.fetch("at"))

    respond_with([ 2 ], name: "Mallory", respondent_identity: "host-#{@host.oidc_sub}")
    assert_response :created
    assert_equal [ [ 2 ], 1 ], [ response.parsed_body.fetch("my_response"), response.parsed_body.dig("poll", "responses_count") ]
    respond_with([ 0 ])
    response_row = @poll.responses.sole
    assert_equal [ "viewer-#{@registration.id}", "Alice", @registration.id, [ 0 ] ],
                 response_row.values_at(:respondent_identity, :name, :registration_id, :value)
  end

  test "intervenant (en-tête X-Speaker-Token) et animation répondent aussi, sous leur nom" do
    speaker = @webinar.speakers.create!(name: "Basile")
    respond_with([ 1 ], speaker_token: speaker.token)
    assert_response :created

    sign_in_as(@host)
    respond_with([ 2 ])
    assert_response :created
    assert_equal [ [ "speaker-#{speaker.id}", "Basile" ], [ "host-#{@host.oidc_sub}", @host.chat_alias ] ],
                 @poll.responses.order(:id).pluck(:respondent_identity, :name)
  end

  test "co-animateur : voit et répond comme l'animation" do
    guest = User.create!(email: "co@partenaire.test", oidc_sub: "sub-co-#{SecureRandom.hex(4)}", email_verified: true,
                         email_verified_for: "co@partenaire.test")
    @webinar.webinar_hosts.create!(email: guest.email, invited_by_sub: @host.oidc_sub)
    sign_in_as(guest, email_verified: true)

    respond_with([ 0 ])
    assert_response :created
    assert_equal "host-#{guest.oidc_sub}", @poll.responses.sole.respondent_identity
  end

  test "refusés : sans inscription, inscription non confirmée, inscription à un autre webinaire, payant non payé" do
    get current_public_webinar_poll_path(@webinar.slug), as: :json
    assert_response :forbidden
    assert_equal "participant_required", response.parsed_body.fetch("error")

    unconfirmed = @webinar.registrations.create!(name: "Bob", email: "bob@example.test")
    get confirm_registration_path(unconfirmed.token)
    respond_with([ 0 ])
    assert_response :forbidden

    other = Webinar.create!(title: "Autre", host_sub: "autre", visibility: "published", state: "live", starts_at: 1.hour.ago)
    foreign = other.registrations.create!(name: "Eve", email: "eve@example.test")
    post confirm_registration_path(foreign.token)
    respond_with([ 0 ])
    assert_response :forbidden

    confirm_viewer
    @webinar.update!(price_cents: 9900)
    respond_with([ 0 ])
    assert_response :forbidden
    assert_equal 0, @poll.responses.count
  end

  test "sondage fermé ou direct terminé : 409 ; valeur hors format : 422 ; sondage d'un autre webinaire : 404" do
    confirm_viewer
    respond_with([ 0, 1 ])
    assert_response :unprocessable_entity
    assert_equal "invalid_response", response.parsed_body.fetch("error")

    foreign = Webinar.create!(title: "Autre", host_sub: "autre", state: "live", starts_at: 1.hour.ago)
                     .polls.create!(position: 1, kind: "short_text", label: "Ailleurs ?")
    foreign.open!
    post public_webinar_poll_responses_path(@webinar.slug, foreign), params: { value: "Bonjour" }, as: :json
    assert_response :not_found

    @poll.close!
    respond_with([ 0 ])
    assert_response :conflict
    assert_equal "poll_closed", response.parsed_body.fetch("error")
    assert_equal 0, PollResponse.count
  end

  test "résultat montré : visible de tous, sondage fermé compris, avec la réponse de chacun" do
    confirm_viewer
    respond_with([ 1 ])
    @poll.close!
    @poll.show_results!

    get current_public_webinar_poll_path(@webinar.slug), as: :json
    body = response.parsed_body
    assert_equal [ false, { "respondents" => 1, "counts" => [ 0, 1, 0 ] } ], body.fetch("poll").values_at("open", "results")
    assert_equal [ 1 ], body.fetch("my_response")
  end

  test "compteur : une diffusion programmée par seconde, à la fin de la seconde, quel que soit le nombre de réponses" do
    confirm_viewer
    # Début de seconde + 0,2 s ; proche de maintenant : le cookie d'inscription
    # expire au lendemain de la fin prévue du webinaire.
    travel_to Time.current.change(usec: 200_000) + 1.minute do
      assert_enqueued_jobs 1, only: PollTallyJob do
        respond_with([ 0 ])
        respond_with([ 1 ])
      end
      assert_equal Time.current.to_i + 1, enqueued_jobs.last.fetch("scheduled_at").then { |at| Time.iso8601(at).to_i }
    end
    perform_enqueued_jobs
    packet = @broadcaster.calls.sole
    assert_equal [ "poll", 1, nil ], [ packet["topic"], packet.dig("poll", "responses_count"), packet.dig("poll", "results") ]
  end

  # Horloge figée : toute la rafale tombe dans une même fenêtre de débit
  # (compteurs isolés par processus de test, cf. test_helper).
  test "anti-rafale : au-delà de 10 réponses en 10 s, 429" do
    confirm_viewer
    freeze_time do
      10.times { respond_with([ 0 ]) }
      assert_response :created
      respond_with([ 1 ])
      assert_response :too_many_requests
    end
    assert_equal [ 0 ], @poll.responses.sole.value
  end

  test "lecture bornée : au-delà de 30 relectures en 30 s, 429" do
    confirm_viewer
    freeze_time do
      30.times { get current_public_webinar_poll_path(@webinar.slug), as: :json }
      assert_response :success
      get current_public_webinar_poll_path(@webinar.slug), as: :json
      assert_response :too_many_requests
    end
  end

  test "direct repris : une réponse donnée depuis le replay n'est pas montrée comme réponse du direct" do
    confirm_viewer
    @poll.responses.create!(respondent_identity: "viewer-#{@registration.id}", name: "Inès", value: [ 1 ],
                            registration: @registration, origin: "replay")

    get current_public_webinar_poll_path(@webinar.slug), as: :json

    assert_response :success
    assert_nil response.parsed_body["my_response"]
  end

  test "CSRF actif : sans jeton, refus JSON 422" do
    confirm_viewer
    ActionController::Base.allow_forgery_protection = true
    respond_with([ 0 ])
    assert_response :unprocessable_entity
    assert_equal "invalid_authenticity_token", response.parsed_body.fetch("error")
  end

  private

  def confirm_viewer
    post confirm_registration_path(@registration.token)
    assert_response :redirect
  end

  def respond_with(value, speaker_token: nil, **extra)
    headers = speaker_token ? { "X-Speaker-Token" => speaker_token } : {}
    post public_webinar_poll_responses_path(@webinar.slug, @poll), params: { value: value, **extra }, headers: headers, as: :json
  end
end
