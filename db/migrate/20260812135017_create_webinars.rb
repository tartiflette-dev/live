class CreateWebinars < ActiveRecord::Migration[8.1]
  # Modèle Webinar.
  #
  # Colonnes minimales, PAS de champ additionnel spéculatif (ni
  # multi-tenancy ni quotas).
  #
  # `slug`      : segment d'URL (base des 3 liens scène/intervenant/
  #               spectateur). Unicité stricte, collision gérée model-
  #               side (before_validation).
  # `room_name` : nom de room LiveKit — dérivé du slug par défaut,
  #               DÉCOUPLÉ pour permettre de re-slugger sans casser une
  #               room live côté SFU. Unicité stricte aussi (un webinaire
  #               = une room).
  # `state`     : machine à trois états `draft` → `live` → `ended`. String
  #               pour lisibilité en BDD (SQLite) ; validation côté enum
  #               Rails (invariants tests).
  # `host_sub`  : OIDC sub de l'animateur créateur — clé d'isolation
  #               stable (User#oidc_sub est immuable côté Pocket ID).
  #               Un user_id serait plus fragile
  #               (renommage compte, reprovisioning). Index pour la
  #               scope host côté controller.
  # `starts_at` : datetime, requis. Le rendu (fuseau) est un problème
  #               vue, pas modèle.
  def change
    create_table :webinars do |t|
      t.string   :slug,      null: false
      t.string   :title,     null: false
      t.datetime :starts_at, null: false
      t.string   :state,     null: false, default: "draft"
      t.string   :room_name, null: false
      t.string   :host_sub,  null: false

      t.timestamps
    end

    add_index :webinars, :slug,      unique: true
    add_index :webinars, :room_name, unique: true
    add_index :webinars, :host_sub
  end
end
