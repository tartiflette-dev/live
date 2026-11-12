# Lance des opérations dans de vrais threads, chacun sur sa propre connexion,
# et les libère ensemble pour provoquer la course. Rend le résultat de chaque
# opération, ou l'exception qu'elle a levée. À utiliser sans transaction de
# test (`self.use_transactional_tests = false`).
module ConcurrentOperations
  private

  def concurrently(*operations)
    ready = Queue.new
    start = Queue.new
    threads = operations.map do |operation|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          begin
            operation.call
          rescue StandardError => error
            error
          end
        end
      end
    end
    operations.size.times { ready.pop }
    operations.size.times { start << true }
    threads.map(&:value)
  end
end
