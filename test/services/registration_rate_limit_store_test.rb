require "test_helper"
require "tmpdir"

class RegistrationRateLimitStoreTest < ActiveSupport::TestCase
  test "independent workers share atomic counters" do
    Dir.mktmpdir("registration-limits") do |path|
      workers = 4.times.map do
        fork do
          store = RegistrationRateLimitStore.new(path)
          10.times { store.increment("same-ip", 1, expires_in: 60) }
          exit! 0
        end
      end
      workers.each do |pid|
        _, status = Process.wait2(pid)
        assert status.success?
      end
      assert_equal 41, RegistrationRateLimitStore.new(path).increment("same-ip", 1, expires_in: 60)
    end
  end

  test "expired counters reset and cleanup removes inactive identities" do
    Dir.mktmpdir("registration-limits") do |path|
      store = RegistrationRateLimitStore.new(path)
      assert_equal 1, store.increment("old-ip", 1, expires_in: 60)
      travel 61.seconds do
        assert_equal 1, store.increment("new-ip", 1, expires_in: 60)
        assert_equal 1, Dir.glob(File.join(path, "counters", "**", "*")).count { |file| File.file?(file) }
        assert_equal 1, store.increment("old-ip", 1, expires_in: 60)
      end
    end
  end

  test "répertoire par défaut résolu à l'usage : un store construit avant suit default_root" do
    store = RegistrationRateLimitStore.new
    original = RegistrationRateLimitStore.default_root
    Dir.mktmpdir("registration-limits") do |path|
      RegistrationRateLimitStore.default_root = path
      assert_equal 1, store.increment("ip", 1, expires_in: 60)
      assert File.exist?(File.join(path, "lock"))
    ensure
      RegistrationRateLimitStore.default_root = original
    end
  end

  test "hors surcharge, le répertoire par défaut est le volume persistant storage/" do
    original = RegistrationRateLimitStore.default_root
    RegistrationRateLimitStore.default_root = nil
    assert_equal Rails.root.join("storage", "registration_rate_limits"), RegistrationRateLimitStore.default_root
  ensure
    RegistrationRateLimitStore.default_root = original
  end

  test "store nommé : son propre répertoire et son propre verrou sous storage_root, résolus à l'usage" do
    store = RegistrationRateLimitStore.new(name: "poll_rate_limits")
    original = RegistrationRateLimitStore.storage_root
    Dir.mktmpdir("named-limits") do |path|
      RegistrationRateLimitStore.storage_root = path
      assert_equal 1, store.increment("k", 1, expires_in: 60)
      assert File.exist?(File.join(path, "poll_rate_limits", "lock"))
    ensure
      RegistrationRateLimitStore.storage_root = original
    end
  end

  test "hors surcharge, un store nommé vit sous storage/" do
    original = RegistrationRateLimitStore.storage_root
    RegistrationRateLimitStore.storage_root = nil
    assert_equal Rails.root.join("storage"), RegistrationRateLimitStore.storage_root
  ensure
    RegistrationRateLimitStore.storage_root = original
  end
end
