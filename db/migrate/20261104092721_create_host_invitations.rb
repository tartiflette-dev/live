# Lien animateur : invitation propre à un
# webinaire, qui crée un WebinarHost après connexion Pocket ID avec email
# vérifié. Additive : une table neuve, aucune colonne existante touchée.
#
# `uses_count` est incrémenté sous verrou (HostInvitation#accept) ; la
# contrainte CHECK est le dernier rempart contre un dépassement écrit hors
# de ce verrou.
class CreateHostInvitations < ActiveRecord::Migration[8.1]
  def change
    create_table :host_invitations do |t|
      t.references :webinar, null: false, foreign_key: true
      t.string :token, null: false
      t.integer :max_uses, null: false, default: 3
      t.integer :uses_count, null: false, default: 0
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.string :created_by_sub, null: false
      t.string :signup_url, limit: 2048
      t.timestamps
      t.check_constraint "max_uses >= 1 AND uses_count >= 0 AND uses_count <= max_uses",
        name: "host_invitations_uses_within_limit"
    end
    add_index :host_invitations, :token, unique: true
  end
end
