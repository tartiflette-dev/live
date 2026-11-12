# Shared by Puma workers on the persistent local volume. The stable lock
# also covers the first increment, before FileStore creates a counter file.
#
# The default directory is resolved at first use, not at class load: the
# controllers build their store when they load, and the test suite gives
# each test process its own directory (`default_root=`) so that one
# process's cleanup under a travelled clock never wipes another's live
# counters.
#
# Other uses get their own directory and lock with `name:` (a subdirectory
# of `storage_root`, resolved at use the same way): in production
# storage/<name>, in tests under each test process's own root.
class RegistrationRateLimitStore
  class << self
    attr_writer :default_root, :storage_root

    def default_root
      @default_root || Rails.root.join("storage", "registration_rate_limits")
    end

    def storage_root
      @storage_root || Rails.root.join("storage")
    end
  end

  def initialize(path = nil, name: nil)
    @explicit_path = path
    @name = name
  end

  def increment(name, amount, **options)
    synchronize { |cache| cache.increment(name, amount, **options) }
  end

  # Section critique partagée par tous les workers (verrou de fichier
  # exclusif) : permet une lecture puis écriture atomique, ce que
  # `increment` seul ne permet pas (RecipientMailThrottle).
  # @yieldparam cache [ActiveSupport::Cache::FileStore]
  def synchronize
    path = Pathname.new(@explicit_path || (@name ? Pathname.new(self.class.storage_root).join(@name) : self.class.default_root))
    cache = cache_for(path)
    FileUtils.mkdir_p(path)
    File.open(path.join("lock"), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      if lock.stat.mtime <= 1.minute.ago
        cache.cleanup
        File.utime(Time.now, Time.now, lock.path)
      end
      yield cache
    end
  end

  private

  def cache_for(path)
    @caches ||= {}
    @caches[path] ||= ActiveSupport::Cache::FileStore.new(path.join("counters"))
  end
end
