class AddSecurityHardeningToWebinarHostsAndUsers < ActiveRecord::Migration[8.1]
  # Durcissement sécurité :
  #
  # • broken-authentication : l'invitation par EMAIL est liée au `sub`
  #   OIDC à la première revendication réussie (`webinar_hosts.claimed_sub`)
  #   et refusée ensuite pour tout autre sub. Exige aussi un email VÉRIFIÉ
  #   côté Pocket ID (`users.email_verified`) — sans quoi un compte dont
  #   l'email égale celui d'un invité pourrait hériter des droits.
  #
  # • fail-open-state-drift : les groupes OIDC `users.oidc_groups` sont
  #   stockés avec un horodatage `oidc_groups_fetched_at` ; le prédicat
  #   `User#project_host?` ignore les groupes « périmés » (fenêtre courte,
  #   réévaluée à CHAQUE requête — pas de cache Ruby). Un retrait du
  #   groupe `live-animateurs` côté Pocket ID expire les droits sans
  #   attendre un redémarrage ni une purge manuelle.
  def change
    add_column :webinar_hosts, :claimed_sub, :string
    add_index  :webinar_hosts, :claimed_sub

    add_column :users, :email_verified, :boolean, null: false, default: false
    add_column :users, :oidc_groups_fetched_at, :datetime
  end
end
