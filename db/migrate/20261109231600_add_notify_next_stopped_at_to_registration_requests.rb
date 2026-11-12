# Arrêt du « préviens-moi du prochain Café IA » par le lien des envois
# groupés (NotifyNextStopsController) : la date de l'arrêt, posée sur toutes
# les demandes confirmées de la personne. `notify_next` reste tel que la
# personne l'a demandé (historique, synchro CRM inchangée) ; l'envoi groupé
# « préviens-moi » écarte les demandes arrêtées. Additive : une colonne
# nullable, aucune donnée existante touchée.
class AddNotifyNextStoppedAtToRegistrationRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :registration_requests, :notify_next_stopped_at, :datetime
  end
end
