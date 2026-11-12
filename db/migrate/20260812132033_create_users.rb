class CreateUsers < ActiveRecord::Migration[8.1]
  # Auth animateur Pocket ID OIDC. Rapprochement par
  # `oidc_sub` EXCLUSIVEMENT (jamais par email).
  #
  # `email`     : présent et normalisé (downcase, unicité case-insensitive
  #               via unique index Rails standard) — sert d'affichage et
  #               d'export, JAMAIS de clé de rapprochement OIDC.
  # `oidc_sub`  : claim `sub` retourné par Pocket ID, immuable. Unique
  #               strict.
  # `admin`     : réservé (V1 : tout animateur authentifié a les droits
  #               animateur ; le drapeau ouvrira le back-office futur).
  def change
    create_table :users do |t|
      t.string :email, null: false
      t.string :oidc_sub, null: false
      t.boolean :admin, null: false, default: false

      t.timestamps
    end

    add_index :users, "LOWER(email)", unique: true, name: "index_users_on_lower_email"
    add_index :users, :oidc_sub, unique: true
  end
end
