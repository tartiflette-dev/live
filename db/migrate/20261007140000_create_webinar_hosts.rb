class CreateWebinarHosts < ActiveRecord::Migration[8.1]
  # Co-animateurs INVITÉS par webinaire.
  #
  # • Désignés par EMAIL par un animateur du projet ou le propriétaire.
  # • À la connexion Pocket ID, un user dont l'email figure ici reçoit
  #   le rôle `:guest_host` SUR CE webinaire — scène, go_live/end_live,
  #   mains levées. PAS d'accès aux inscrits, enregistrements,
  #   transcripts, intervenants, co-animateurs (voir Webinar#role_for).
  #
  # `invited_by_sub` = oidc_sub de l'invitant (traçabilité ; le modèle
  # garde SIMPLE : tout animateur peut gérer la liste, aucun check
  # « only remover == invitant » (garde simple).
  # Reste NON optionnel pour éviter un historique anonyme.
  #
  # Email case-insensitive : la clé d'autorisation est LOWER(email) ;
  # l'index unique porte dessus.
  def change
    create_table :webinar_hosts do |t|
      t.references :webinar, null: false, foreign_key: true
      t.string :email, null: false
      t.string :invited_by_sub, null: false
      t.timestamps
    end

    # LOWER(email) : la comparaison OIDC passe toujours en downcase
    # (SessionsController + User#normalize_email). On garde la cohérence
    # avec `index_users_on_lower_email`.
    add_index :webinar_hosts, "webinar_id, LOWER(email)",
              unique: true, name: "index_webinar_hosts_on_webinar_id_and_lower_email"
  end
end
