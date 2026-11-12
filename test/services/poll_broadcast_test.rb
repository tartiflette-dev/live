require "test_helper"

# Diffusion des sondages : l'état complet à l'écran, jamais
# levé en cas de panne LiveKit — les clients rattrapent par le poll HTTP.
class PollBroadcastTest < ActiveSupport::TestCase
  class FailingClient
    def send_data(**) = raise(RoomServiceClient::RemoteError, "livekit hors ligne")
  end

  class RecordingClient
    attr_reader :calls

    def initialize = @calls = []

    def send_data(**arguments)
      @calls << arguments
      {}
    end
  end

  setup do
    @webinar = Webinar.create!(title: "Café IA #8", starts_at: 1.hour.ago, host_sub: "sub-marc", state: "live")
    @poll = @webinar.polls.create!(position: 1, kind: "choice", label: "A ou B ?", options: %w[A B])
  end

  test "paquet fiable vers la salle du webinaire : topic, horodatage µs, sondage à l'écran sans nom" do
    @poll.open!
    @poll.respond!(identity: "viewer-1", name: "Alice", value: [ 0 ])
    client = RecordingClient.new

    assert_equal :sent, PollBroadcast.new(client: client).deliver(@webinar)

    call = client.calls.sole
    assert_equal [ @webinar.room_name, :reliable ], call.values_at(:room, :kind)
    packet = JSON.parse(call.fetch(:data))
    assert_equal "poll", packet.fetch("topic")
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/, packet.fetch("at"))
    assert_equal [ @poll.id, 1, nil ], packet.fetch("poll").values_at("id", "responses_count", "results")
    assert_not_includes call.fetch(:data), "Alice"
  end

  test "paquet borné sous 16 KiB au pire cas : texte multi-octets et échappé, réponses récentes gardées" do
    text = @webinar.polls.create!(position: 2, kind: "short_text", label: "<" * Poll::LABEL_LIMIT)
    text.open!
    80.times { |i| text.respond!(identity: "viewer-#{i}", name: "Personne #{i}", value: "#{i}:" + ("😀<" * 98)) }
    text.close!
    text.show_results!
    client = RecordingClient.new

    PollBroadcast.new(client: client).deliver(@webinar)

    data = client.calls.sole.fetch(:data)
    assert_operator data.bytesize, :<, 16 * 1024
    answers = JSON.parse(data).dig("poll", "results", "answers")
    assert_operator answers.size, :<, 80, "liste tronquée"
    assert answers.last.start_with?("79:"), "la plus récente est gardée"
    assert_equal 80, JSON.parse(data).dig("poll", "results", "respondents"), "le compte reste complet"
  end

  test "rien à l'écran : poll nul" do
    assert_nil PollBroadcast.snapshot(@webinar)[:poll]
  end

  test "LiveKit en panne : rendu :unavailable, jamais levé" do
    assert_equal :unavailable, PollBroadcast.new(client: FailingClient.new).deliver(@webinar)
  end
end
