# Tournée du rappel de la veille (RegistrationReminder), lancée toutes les
# heures de la plage d'envoi par config/recurring.yml. Sans effet tant que
# REMINDERS_ENABLED != 1 (posée par le déploiement, en prod seulement). Les erreurs d'envoi
# sont traitées par inscription (RegistrationReminder#deliver) : le job ne
# lève pas, donc Solid Queue ne le rejoue pas. Chaque tournée laisse une
# ligne de journal et une ligne RegistrationReminderRun (compteurs, sans
# donnée personnelle), lue par la sonde /internal/crm_status.
class RegistrationReminderJob < ApplicationJob
  queue_as :default

  def perform
    return unless RegistrationReminder.enabled?

    run = RegistrationReminderRun.record!(**RegistrationReminder.deliver_due)
    Rails.logger.info(run.to_log_line)
  end
end
