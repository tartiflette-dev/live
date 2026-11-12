# File Q&R du direct, extraite du chat. Additive :
# deux tables neuves, aucune colonne existante touchée.
#
# `qa_items` = une question à traiter par l'animation (libellé reformulé par
# le LLM local, ou texte brut d'une mention @animateur si le LLM est coupé).
# `qa_item_messages` relie l'item aux messages qui la posent : plusieurs
# personnes, une seule question. Un message ne nourrit qu'un item
# (unicité), ce qui rend le job rejouable sans doublon.
#
# `label_message_id` = le message dont le libellé est tiré (texte brut ou
# reformulation) : à l'effacement de ce message (crm:erase), le libellé est
# réécrit depuis un autre auteur, ou la question disparaît.
#
# Index partiel : au plus UNE question affichée à l'écran par webinaire.
#
# `webinars.qa_llm_*` = état RÉEL du dernier appel au LLM local pour ce
# webinaire (ok, timeout, unreachable, invalid, error ; horodatage ; durée),
# affiché dans la console de régie : une panne se voit pendant le direct.
class CreateQaItems < ActiveRecord::Migration[8.1]
  def change
    create_table :qa_items do |t|
      t.references :webinar, null: false, foreign_key: true, index: false
      t.string :label, limit: 500, null: false
      t.string :status, null: false, default: "open"
      t.string :source, null: false
      t.string :llm_model, limit: 120
      t.references :label_message, foreign_key: { to_table: :messages }, index: false
      t.datetime :answered_at
      t.datetime :displayed_at
      t.timestamps
    end
    add_index :qa_items, [ :webinar_id, :status ]
    add_index :qa_items, :webinar_id, unique: true, where: "displayed_at IS NOT NULL",
      name: "index_qa_items_one_displayed_per_webinar"

    add_column :webinars, :qa_llm_outcome, :string, limit: 20
    add_column :webinars, :qa_llm_at, :datetime
    add_column :webinars, :qa_llm_duration_ms, :integer

    create_table :qa_item_messages do |t|
      t.references :qa_item, null: false, foreign_key: true
      t.references :message, null: false, foreign_key: true, index: { unique: true }
      t.timestamps
    end
  end
end
