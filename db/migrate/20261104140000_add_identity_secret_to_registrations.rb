# Identité PROVISOIRE : une inscription ouverte par
# l'accès immédiat, sans boîte prouvée, n'est jamais promue en identité
# confirmée d'un autre navigateur.
#
# - `identity_secret` : secret aléatoire propre à l'inscription, porté par le
#   cookie d'identité avec l'id (RoomRemoval#registration_in_browser). Les
#   inscriptions existantes en reçoivent un ; leurs anciens cookies (id seul)
#   ne désignent plus personne : un clic sur le lien du mail les repose.
# - `retired_email_digest` : empreinte (CrmErasure.digest) de l'adresse d'une
#   inscription passée en pierre tombale (Registration#retire_attributes),
#   dont l'adresse est libérée : `crm:erase` la retrouve ainsi.
# Additive ; le retour en arrière supprime deux colonnes dérivées.
class AddIdentitySecretToRegistrations < ActiveRecord::Migration[8.1]
  def up
    add_column :registrations, :identity_secret, :string
    add_column :registrations, :retired_email_digest, :string
    add_index :registrations, :retired_email_digest, where: "retired_email_digest IS NOT NULL"
    execute "UPDATE registrations SET identity_secret = lower(hex(randomblob(24))) WHERE identity_secret IS NULL"
  end

  def down
    remove_index :registrations, :retired_email_digest
    remove_column :registrations, :retired_email_digest
    remove_column :registrations, :identity_secret
  end
end
