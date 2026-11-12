# Deux changements du relais WhatsApp, une seule coupure :
# - le groupe des co-organisateurs reçoit désormais TOUTES les inscriptions
#   Café IA confirmées, plus seulement celles qui portent un message ;
# - nouveau canal : l'annonce (prénom et cafés) dans le groupe de la
#   communauté Tartiflette (`community_announced_at`), le prénom pouvant être
#   retenu à la confirmation s'il n'est pas publiable
#   (`community_announcement_withheld_at`, RegistrationRequest#confirm!).
#
# Sans cette étape, chaque inscription confirmée depuis l'ouverture partirait
# d'un coup aux deux groupes. Coupure = l'instant où la migration tourne
# (chaque instance a le sien) : c'est là que la nouvelle règle prend effet.
# Les demandes existantes reçoivent la coupure comme date (hors file, jamais
# postées) :
# - co-organisateurs : les confirmées SANS message. Celles qui en portent
#   étaient déjà dans la file, le relais les poste ou les a postées ; une
#   demande en attente partira à sa confirmation, comme une inscription neuve.
# - communauté : toutes les demandes créées avant la coupure, CONFIRMÉES OU
#   NON. Soumises sous une politique qui n'annonçait pas ce canal, elles
#   ne sont jamais annoncées, même confirmées plus tard. Les marquer ici
#   plutôt que filtrer la file sur une date garde la file sans date figée.
class AddCommunityAnnouncedAtToRegistrationRequests < ActiveRecord::Migration[8.1]
  class RegistrationRequest < ActiveRecord::Base
    self.table_name = "registration_requests"

    scope :tartiflette, -> { where(source: "tartiflette.dev") }

    def self.exclude_existing!(cutoff = Time.current)
      tartiflette.where.not(confirmed_at: nil).where(whatsapp_relayed_at: nil, message: [ nil, "" ])
                 .update_all(whatsapp_relayed_at: cutoff)
      tartiflette.where(community_announced_at: nil).update_all(community_announced_at: cutoff)
    end
  end

  def up
    add_column :registration_requests, :community_announced_at, :datetime
    add_column :registration_requests, :community_announcement_withheld_at, :datetime
    RegistrationRequest.reset_column_information
    RegistrationRequest.exclude_existing!
  end

  # Les dates posées sur `whatsapp_relayed_at` restent : les effacer renverrait
  # au groupe toutes les anciennes inscriptions.
  def down
    remove_column :registration_requests, :community_announcement_withheld_at
    remove_column :registration_requests, :community_announced_at
  end
end
