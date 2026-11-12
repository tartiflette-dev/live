# Simule une limite par destinataire (RecipientMailThrottle) qui REFUSE les
# claims des budgets donnés (tous, sans argument), pour une adresse dont la
# ligne d'inscription n'existe pas encore : un budget par flux ne peut pas
# s'épuiser d'avance sur un flux qui n'existe pas. Pas de minitest/mock dans
# ce dépôt (minitest 6) : redéfinition ponctuelle sur l'instance partagée,
# retirée à la sortie du bloc.
module MailThrottleHelper
  def with_mail_throttle_refusing(*budgets)
    refused = budgets.empty? ? RecipientMailThrottle::BUDGETS.keys : budgets
    throttle = RecipientMailThrottle.default
    throttle.define_singleton_method(:claim) do |*args, budget: :unproven, **options|
      refused.include?(budget) ? false : super(*args, budget: budget, **options)
    end
    yield
  ensure
    throttle.singleton_class.send(:remove_method, :claim)
  end
end

ActiveSupport::TestCase.include(MailThrottleHelper)
