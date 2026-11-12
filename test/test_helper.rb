ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "livekit/proto/livekit_webhook_pb"
Dir[File.expand_path("support/**/*.rb", __dir__)].each { |f| require f }

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Compteurs de rate limit propres à chaque processus de test (série ou
    # worker parallèle) : sinon un test qui voyage dans le temps (`travel
    # 61.seconds`) déclenche un nettoyage qui efface les compteurs vivants
    # d'un autre processus → test croisé instable (et les
    # stores nommés : sondages, discussion).
    rate_limit_root = ->(label) { Rails.root.join("tmp", "test-rate-limits", label) }
    isolate_rate_limits = lambda do |label|
      RegistrationRateLimitStore.default_root = rate_limit_root.call(label)
      RegistrationRateLimitStore.storage_root = rate_limit_root.call(label)
    end
    isolate_rate_limits.call("pid-#{Process.pid}")
    parallelize_setup { |worker| isolate_rate_limits.call("worker-#{worker}-#{Process.pid}") }
    Minitest.after_run { FileUtils.rm_rf(Rails.root.join("tmp", "test-rate-limits", "pid-#{Process.pid}")) }
    parallelize_teardown { FileUtils.rm_rf(RegistrationRateLimitStore.default_root) }

    # La limite par destinataire (RecipientMailThrottle) vit sur disque, comme
    # les compteurs ci-dessus : sans remise à zéro, deux tests qui inscrivent
    # la même adresse se limitent l'un l'autre.
    setup { RecipientMailThrottle.reset! }

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
