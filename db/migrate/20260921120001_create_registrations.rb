class CreateRegistrations < ActiveRecord::Migration[8.1]
  # Inscription à un webinaire (la confirmation par mail ouvre l'accès).
  #
  # Fondation Registration : email normalisé + name + token opaque + double
  # opt-in (`confirmed_at`) + confirmation payante manuelle (`paid_confirmed_at`).
  # `reminder_sent_at` json vide par défaut, portera `{"j1": iso, "h1": iso}`
  # posé par les jobs solid_queue (hors périmètre ici).
  #
  # SQLite de production (volume persistant de l'instance) — migration
  # additive uniquement.
  def change
    create_table :registrations do |t|
      t.references :webinar, null: false, foreign_key: true
      t.string     :email,   null: false
      t.string     :name,    null: false
      t.string     :token,   null: false
      t.datetime   :confirmed_at
      t.datetime   :paid_confirmed_at
      # Rappels J-1 / H-1 : dictionnaire des envois effectués. Default `{}`
      # évite les `NULL.dig("j1")` côté job.
      t.json       :reminder_sent_at, null: false, default: {}
      t.timestamps
    end

    # Token opaque = seul discriminant du lien nominatif `/r/:token`.
    # L'unicité DB verrouille l'invariant même si une collision
    # SecureRandom.urlsafe_base64(24) survenait (≈ 2^-144).
    add_index :registrations, :token, unique: true

    # Une adresse ne s'inscrit qu'une fois par webinaire. L'email est
    # normalisé (strip + downcase) AVANT validation par le modèle, donc
    # un index simple couvre l'invariant sans dépendre de `LOWER()`
    # SQLite (fragile côté collation).
    add_index :registrations, [ :webinar_id, :email ], unique: true
  end
end
