# frozen_string_literal: true

# Race / consent propagation :
# `crm_withdrawal_pushed_at` est l'ancrage d'idempotence pour la
# propagation du retrait au CRM. Le job `CrmMarketingWithdrawalJob`
# le pose atomiquement (avec `with_lock`) et retourne tôt si déjà posé —
# un double clic / un retry ne pousse jamais deux Interactions de retrait.
class AddCrmWithdrawalPushedAtToRegistrations < ActiveRecord::Migration[8.1]
  def change
    add_column :registrations, :crm_withdrawal_pushed_at, :datetime
  end
end
