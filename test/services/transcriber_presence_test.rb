# frozen_string_literal: true

require "test_helper"

# Le transcripteur dans la salle d'une captation ouverte, jamais après la fin.
class TranscriberPresenceTest < ActiveSupport::TestCase
  # Salle LiveKit en mémoire : participants et dispatches d'agents.
  class FakeRoom
    attr_accessor :participants, :dispatches, :on_create
    attr_reader :created, :deleted, :removed

    def initialize
      @participants = []
      @dispatches = []
      @created = []
      @deleted = []
      @removed = []
    end

    def list_participants(room:) = participants.dup
    def list_agent_dispatches(room:) = dispatches.dup

    def create_agent_dispatch(room:, agent_name:)
      @created << [ room, agent_name ]
      on_create&.call
      {}
    end

    def delete_agent_dispatch(room:, dispatch_id:)
      @deleted << dispatch_id
      @dispatches.reject! { |dispatch| dispatch[:id] == dispatch_id }
      {}
    end

    def remove_participant(room:, identity:)
      @removed << identity
      {}
    end
  end

  HUMAN = { identity: "host-sub-marc", kind: "STANDARD" }.freeze
  AGENT = { identity: "agent-AJ_1", kind: "AGENT" }.freeze

  setup do
    @flag = ENV["TRANSCRIPT_ENABLED"]
    ENV["TRANSCRIPT_ENABLED"] = "true"
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.ago, host_sub: "sub-marc",
                               state: "live", started_at: 30.minutes.ago)
    @room = FakeRoom.new
    @room.participants = [ HUMAN ]
  end

  teardown { ENV["TRANSCRIPT_ENABLED"] = @flag }

  def presence = TranscriberPresence.new(@webinar, room_client: @room, agent_name: "transcriber")

  def dispatch(id, created: Time.current, jobs: [], agent_name: "transcriber")
    { id: id, agent_name: agent_name, state: { created_at: (created.to_r * 1_000_000_000).to_i.to_s, jobs: jobs } }
  end

  def job(status, at: Time.current)
    nanos = (at.to_r * 1_000_000_000).to_i.to_s
    { id: "AJ_x", state: { status: status, started_at: nanos, updated_at: nanos } }
  end

  test "direct en cours, personne pour transcrire : le transcripteur est dispatché" do
    assert_equal :dispatched, presence.ensure_present
    assert_equal [ [ @webinar.room_name, "transcriber" ] ], @room.created
  end

  test "agent déjà dans la salle : rien de plus (un seul transcripteur)" do
    @room.participants << AGENT
    assert_equal :present, presence.ensure_present
    assert_empty @room.created
  end

  test "job en route depuis quelques secondes : pas de second dispatch" do
    @room.dispatches = [ dispatch("AD_1", created: 10.minutes.ago, jobs: [ job("JS_PENDING", at: 5.seconds.ago) ]) ]
    assert_equal :pending, presence.ensure_present
    assert_empty @room.created
  end

  test "dispatch tout juste créé, encore sans job : pas de second dispatch" do
    @room.dispatches = [ dispatch("AD_2", created: 3.seconds.ago) ]
    assert_equal :pending, presence.ensure_present
    assert_empty @room.created
  end

  test "dispatch perdu (job terminé, ou en route depuis trop longtemps) : remplacé" do
    @room.dispatches = [
      dispatch("AD_fini", created: 30.minutes.ago, jobs: [ job("JS_SUCCESS", at: 2.minutes.ago) ]),
      dispatch("AD_bloque", created: 10.minutes.ago, jobs: [ job("JS_RUNNING", at: 5.minutes.ago) ]),
      dispatch("AD_autre", agent_name: "autre-agent")
    ]

    assert_equal :dispatched, presence.ensure_present
    assert_equal %w[AD_fini AD_bloque], @room.deleted
    assert_equal 1, @room.created.size
  end

  test "salle sans personne : aucun dispatch (LiveKit créerait la salle pour l'agent seul)" do
    @room.participants = [ { identity: "EG_composite", kind: "EGRESS" } ]
    assert_equal :empty_room, presence.ensure_present
    assert_empty @room.created
  end

  test "direct terminé : jamais de dispatch" do
    @webinar.update!(state: "ended", ended_at: Time.current)
    assert_equal :closed, presence.ensure_present
    assert_empty @room.created
  end

  test "transcript non activé : jamais de dispatch" do
    ENV["TRANSCRIPT_ENABLED"] = nil
    assert_equal :closed, presence.ensure_present
    assert_empty @room.created
  end

  test "avant le go_live, la captation ouverte (composite actif) est transcrite ; sans captation, rien" do
    @webinar.update!(state: "draft", started_at: nil)
    assert_equal :closed, presence.ensure_present

    @webinar.recordings.create!(status: "recording", egress_id: "EG_scene", started_at: 1.minute.ago)
    assert_equal :dispatched, presence.ensure_present
  end

  test "fin du direct pendant le dispatch : le transcripteur est aussitôt congédié" do
    webinar = @webinar
    @room.on_create = lambda do
      Webinar.where(id: webinar.id).update_all(state: "ended", ended_at: Time.current)
      @room.dispatches << dispatch("AD_tardif")
    end

    assert_equal :dispatched, presence.ensure_present
    assert_equal [ "AD_tardif" ], @room.deleted
  end

  test "dismiss : dispatches supprimés puis agents retirés, les humains restent" do
    @room.participants = [ HUMAN, AGENT, { identity: "EG_composite", kind: "EGRESS" } ]
    @room.dispatches = [ dispatch("AD_1") ]

    presence.dismiss

    assert_equal [ "AD_1" ], @room.deleted
    assert_equal [ "agent-AJ_1" ], @room.removed
  end

  test "dismiss : un dispatch déjà terminé côté LiveKit (not_found) n'empêche pas le retrait de l'agent" do
    @room.participants = [ AGENT ]
    @room.dispatches = [ dispatch("AD_1") ]
    @room.define_singleton_method(:delete_agent_dispatch) do |room:, dispatch_id:|
      raise RoomServiceClient::RemoteError.new("dispatch absent", code: "not_found")
    end

    presence.dismiss

    assert_equal [ "agent-AJ_1" ], @room.removed
  end

  test "dismiss : un refus LiveKit sur un dispatch n'empêche pas la suppression des suivants" do
    @room.dispatches = [ dispatch("AD_1"), dispatch("AD_2") ]
    room = @room
    @room.define_singleton_method(:delete_agent_dispatch) do |room:, dispatch_id:|
      raise RoomServiceClient::RemoteError.new("unavailable", code: "unavailable") if dispatch_id == "AD_1"

      deleted << dispatch_id
      {}
    end

    presence.dismiss

    assert_equal [ "AD_2" ], room.deleted
  end

  test "dismiss : LiveKit injoignable sur les dispatches, l'agent est quand même retiré" do
    @room.participants = [ AGENT ]
    @room.define_singleton_method(:list_agent_dispatches) do |room:|
      raise RoomServiceClient::RemoteError.new("unavailable", code: "unavailable")
    end

    presence.dismiss

    assert_equal [ "agent-AJ_1" ], @room.removed
  end
end
