# Message laissé à l'inscription : l'équipe du Café IA le reçoit par mail
# (`team_notified_at`) et sur WhatsApp par le relais
# (`whatsapp_relayed_at`, GET /internal/registration_messages/pending).
# Nul = pas encore transmis.
#
# Reprise de l'existant :
# - WhatsApp : les messages confirmés avant MANUAL_WHATSAPP_RELAY_AT avaient
#   déjà été transmis hors de l'application : ils sont marqués relayés à
#   cette date, pour que le relais ne les renvoie pas. Sélection par la date
#   de confirmation, sans identifiant : la même migration tourne sur chaque
#   instance.
# - Mail : rien n'est marqué ; les messages jamais lus partent par
#   `registrations:notify_team_backlog`.
# - Les inscriptions de test de bout en bout de la mise en service (scope
#   `end_to_end_tests`) sont marquées transmises sur les deux canaux, une fois
#   pour toutes, plutôt qu'un filtre permanent dans le code — un futur test de
#   bout en bout doit, lui, traverser les deux canaux.
class AddTeamNotificationsToRegistrationRequests < ActiveRecord::Migration[8.1]
  class RegistrationRequest < ActiveRecord::Base
    self.table_name = "registration_requests"

    MANUAL_WHATSAPP_RELAY_AT = Time.utc(2026, 11, 6, 21, 12)

    scope :end_to_end_tests, -> {
      where("email LIKE '%+cafe-test-%'").where("message LIKE 'Inscription de test de bout en bout%'")
    }
    scope :manually_relayed, -> {
      where(source: "tartiflette.dev", confirmed_at: ...MANUAL_WHATSAPP_RELAY_AT, whatsapp_relayed_at: nil)
        .where.not(message: [ nil, "" ])
    }

    def self.mark_end_to_end_tests_transmitted!(now = Time.current)
      end_to_end_tests.update_all(team_notified_at: now, whatsapp_relayed_at: now)
    end

    def self.mark_manually_relayed!
      manually_relayed.update_all(whatsapp_relayed_at: MANUAL_WHATSAPP_RELAY_AT)
    end
  end

  def up
    add_column :registration_requests, :team_notified_at, :datetime
    add_column :registration_requests, :whatsapp_relayed_at, :datetime
    RegistrationRequest.reset_column_information
    RegistrationRequest.mark_end_to_end_tests_transmitted!
    RegistrationRequest.mark_manually_relayed!
  end

  def down
    remove_column :registration_requests, :whatsapp_relayed_at
    remove_column :registration_requests, :team_notified_at
  end
end
