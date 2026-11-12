class CreatePacks < ActiveRecord::Migration[8.1]
  # Packs : formules payantes modélisées.
  #
  # Modélisation Pack (paiement NON encaissé). Un pack
  # regroupe N webinaires (`webinars.pack_id` posée nue par la migration
  # additive précédente). AUCUNE FK SQL ici — l'association est côté modèle
  # (`Pack has_many :webinars, dependent: :nullify` + `Webinar belongs_to
  # :pack, optional: true`) : la nullification s'exécute en Ruby et évite
  # d'introduire un `foreign_key` a posteriori sur une colonne qui existe
  # déjà (migration additive, SQLite prod, doctrine spec §Invariants).
  #
  # `host_sub` (écart justifié dans la PR) : la spec mère §Hors scope
  # impose l'isolation par host_sub sur `webinars` ; répliquer sur
  # `packs` évite qu'un animateur voie/rattache les packs d'un autre.
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
