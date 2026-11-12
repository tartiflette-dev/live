class CreatePacks < ActiveRecord::Migration[8.1]
  # Packs : formules payantes modélisées.
  #
  # Modélisation Pack (paiement NON encaissé). Un pack
  # regroupe N webinaires (`webinars.pack_id` posée nue par la migration
  # additive précédente). AUCUNE FK SQL ici — l'association est côté modèle
  # (`Pack has_many :webinars, dependent: :nullify` + `Webinar belongs_to
  # :pack, optional: true`) : la nullification s'exécute en Ruby et évite
  # d'introduire un `foreign_key` a posteriori sur une colonne qui existe
  # déjà (les migrations restent additives : la base de production est un
  # SQLite, où ajouter une contrainte réécrit la table).
  #
  # `host_sub` sur `packs` : les webinaires sont déjà isolés par
  # `host_sub` (chaque animateur ne voit que les siens) ; la même colonne
  # ici évite qu'un animateur voie ou rattache les packs d'un autre.
  def change
    create_table :packs do |t|
      t.string  :name,        null: false
      t.integer :price_cents, null: false, default: 0
      t.string  :host_sub,    null: false
      t.timestamps
    end
    add_index :packs, :host_sub
  end
end
