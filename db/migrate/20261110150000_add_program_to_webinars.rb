# Programme annoncé d'un café (Webinar::Program) : sujet, une ou deux phrases
# qui le présentent, intervenants annoncés (noms affichés, 3 au plus) et
# animateur du jour, celui qui mène, distinct du propriétaire. Vides par
# défaut : un café sans programme s'affiche comme avant.
class AddProgramToWebinars < ActiveRecord::Migration[8.1]
  def change
    change_table :webinars, bulk: true do |t|
      t.string :topic
      t.text :topic_summary
      t.json :announced_speakers, null: false, default: []
      t.string :lead_host_name
    end
  end
end
