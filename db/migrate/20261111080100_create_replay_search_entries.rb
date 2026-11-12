# Index plein texte des replays : transcription, titres
# des chapitres validés et leurs thèmes, une ligne par passage. FTS5 (compilé
# dans la gem sqlite3 de l'image), accents et casse ignorés
# (« securite » trouve « Sécurité »). Reconstruit par webinaire
# (ReplaySearchIndex), jamais écrit ailleurs : il ne porte rien qui ne soit
# déjà dans la transcription ou les chapitres.
class CreateReplaySearchEntries < ActiveRecord::Migration[8.1]
  def change
    create_virtual_table :replay_search_entries, :fts5,
                         [ "body", "webinar_id UNINDEXED", "kind UNINDEXED", "at UNINDEXED",
                           "tokenize='unicode61 remove_diacritics 2'" ]
  end
end
