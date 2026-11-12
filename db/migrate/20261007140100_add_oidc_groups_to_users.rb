class AddOidcGroupsToUsers < ActiveRecord::Migration[8.1]
  # Groupes OIDC (claim `groups` Pocket ID). Rafraîchis à chaque callback —
  # c'est l'appartenance au groupe `live-animateurs` (ou liste équivalente,
  # ENV `LIVE_PROJECT_HOSTS_GROUPS`) qui donne le rôle `:project_host`
  # (droits étendus sur TOUT live).
  #
  # Stockage SQLite = JSON (array de strings). Fallback cohérent avec le
  # reste du projet (webinars.layout, registrations.reminder_sent_at).
  #
  # Nullable + défaut `[]` : un user existant pré-migration reste utilisable
  # sans réécriture.
  def change
    add_column :users, :oidc_groups, :json, default: [], null: false
  end
end
