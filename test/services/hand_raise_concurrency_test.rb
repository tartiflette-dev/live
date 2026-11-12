require "test_helper"
require "tmpdir"

class HandRaiseConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  # `land_late` : la permission n'est notée qu'au retour de l'appel, comme
  # un appel LiveKit lent qui aboutit après un geste concurrent.
  class PermissionRecorder
    def initialize(path, started: nil, land_late: false)
      @path = path
      @started = started
      @land_late = land_late
    end

    def update_participant(can_publish:, **)
      note(can_publish) unless @land_late
      if can_publish && @started
        @started.write("1")
        @started.close
        sleep 0.15
      end
      note(can_publish) if @land_late
      {}
    end

    private

    def note(can_publish)
      File.open(@path, "a") { |file| file.puts can_publish }
    end
  end

  setup do
    @directory = Dir.mktmpdir("hand-raise-rpc")
    @path = File.join(@directory, "permissions")
    @webinar = Webinar.create!(title: "Race", starts_at: Time.current, host_sub: "host", visibility: "published", state: "live")
    @registration = @webinar.registrations.create!(name: "Alice", email: "alice@example.test", confirmed_at: Time.current)
    # Accord à l'image donné : la parole accordée ouvre la publication LiveKit.
    ParticipantConsent.grant!(@registration, recording: true, excerpts: false, adult: true)
    @hand = HandRaiseControl.new(@webinar).raise_hand(@registration)
    @config = ActiveRecord::Base.connection_db_config
  end

  teardown do
    ActiveRecord::Base.establish_connection(@config)
    HandRaise.where(webinar_id: @webinar.id).delete_all
    ParticipantConsent.where(webinar_id: @webinar.id).delete_all
    @registration.delete
    @webinar.delete
    FileUtils.remove_entry(@directory)
  end

  test "a revoke waits for an in-flight opening after consent, then closes: the floor is never left open" do
    @hand.update!(state: "granted", granted_at: Time.current)
    reader, writer = IO.pipe
    ActiveRecord::Base.connection_handler.clear_all_connections!
    open_worker = fork do
      reader.close
      ActiveRecord::Base.establish_connection(@config)
      HandRaiseControl.new(@webinar, client: PermissionRecorder.new(@path, started: writer, land_late: true)).open_publication(@registration)
      exit! 0
    end
    writer.close
    assert_equal "1", reader.read(1)
    reader.close
    revoke_worker = fork do
      ActiveRecord::Base.establish_connection(@config)
      HandRaiseControl.new(@webinar, client: PermissionRecorder.new(@path)).revoke(@hand.id)
      exit! 0
    end
    [ open_worker, revoke_worker ].each do |pid|
      _, status = Process.wait2(pid)
      assert status.success?
    end
    ActiveRecord::Base.establish_connection(@config)

    assert_equal %w[true false], File.readlines(@path, chomp: true), "le retrait de parole passe après l'ouverture en vol"
    assert_equal "revoked", @hand.reload.state
  end

  # Le retrait différé relit la règle SOUS le verrou. Hors
  # du verrou, il lirait la main encore « en vol » et fermerait la parole
  # que l'animation vient de donner.
  test "a deferred revocation waits for an in-flight grant, re-reads the rule and leaves the floor open" do
    reader, writer = IO.pipe
    ActiveRecord::Base.connection_handler.clear_all_connections!
    grant_worker = fork do
      reader.close
      ActiveRecord::Base.establish_connection(@config)
      HandRaiseControl.new(@webinar, client: PermissionRecorder.new(@path, started: writer, land_late: true)).grant(@hand.id)
      exit! 0
    end
    writer.close
    assert_equal "1", reader.read(1)
    reader.close
    revocation_worker = fork do
      ActiveRecord::Base.establish_connection(@config)
      Rails.configuration.x.room_service_client_factory = -> { PermissionRecorder.new(@path) }
      PublishingRevocationJob.perform_now(@webinar, @registration)
      exit! 0
    end
    [ grant_worker, revocation_worker ].each do |pid|
      _, status = Process.wait2(pid)
      assert status.success?
    end
    ActiveRecord::Base.establish_connection(@config)

    assert_equal %w[true], File.readlines(@path, chomp: true), "la parole donnée n'est pas refermée par un retrait périmé"
    assert_equal "granted", @hand.reload.state
  end

  test "end waits for an in-flight grant then revokes it across processes" do
    reader, writer = IO.pipe
    ActiveRecord::Base.connection_handler.clear_all_connections!
    grant_worker = fork do
      reader.close
      ActiveRecord::Base.establish_connection(@config)
      HandRaiseControl.new(@webinar, client: PermissionRecorder.new(@path, started: writer)).grant(@hand.id)
      exit! 0
    end
    writer.close
    assert_equal "1", reader.read(1)
    reader.close
    end_worker = fork do
      ActiveRecord::Base.establish_connection(@config)
      HandRaiseControl.new(@webinar, client: PermissionRecorder.new(@path)).end_webinar
      exit! 0
    end
    [ grant_worker, end_worker ].each do |pid|
      _, status = Process.wait2(pid)
      assert status.success?
    end
    ActiveRecord::Base.establish_connection(@config)
    assert_equal %w[true false], File.readlines(@path, chomp: true)
    assert_equal "revoked", @hand.reload.state
    assert @webinar.reload.ended?
    assert_raises(HandRaiseControl::Conflict) { HandRaiseControl.new(@webinar).grant(@hand.id) }
  end
end
