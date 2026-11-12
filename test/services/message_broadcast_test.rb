require "test_helper"

# La diffusion temps réel ne doit jamais faire échouer ni bloquer l'écriture
# d'un message : panne et lenteur de LiveKit deviennent `:unavailable`.
class MessageBroadcastTest < ActiveSupport::TestCase
  class Client
    attr_reader :calls

    def initialize(&behaviour)
      @calls = []
      @behaviour = behaviour
    end

    def send_data(**arguments)
      @calls << arguments
      @behaviour&.call
      {}
    end
  end

  setup do
    webinar = Webinar.create!(title: "Café IA #7", host_sub: "sub-marc", starts_at: 1.hour.ago)
    @message = webinar.messages.create!(author_identity: "viewer-1", name: "Alice", body: "Bonjour")
  end

  test "publie l'enveloppe chat, fiable, dans la salle du webinaire" do
    client = Client.new

    assert_equal :sent, MessageBroadcast.new(client: client).deliver(@message)

    call = client.calls.sole
    assert_equal [ @message.webinar.room_name, :reliable ], call.values_at(:room, :kind)
    assert_equal({ "topic" => "chat", "message" => JSON.parse(@message.public_attributes.to_json) }, JSON.parse(call.fetch(:data)))
  end

  test "panne LiveKit : rapportée, jamais levée" do
    client = Client.new { raise RoomServiceClient::RemoteError, "refusé" }

    assert_equal :unavailable, MessageBroadcast.new(client: client).deliver(@message)
  end

  test "LiveKit trop lente : abandon au délai, rapporté" do
    client = Client.new { sleep 1 }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal :unavailable, MessageBroadcast.new(client: client, timeout: 0.05).deliver(@message)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.5
  end
end
