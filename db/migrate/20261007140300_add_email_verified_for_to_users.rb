class AddEmailVerifiedForToUsers < ActiveRecord::Migration[8.1]
  # Durcissement sécurité — « email utilisé pour matcher
  # une invitation est celui de la session courante issu du claim
  # vérifié, pas une valeur en base modifiable par un autre chemin ».
  #
  # `email_verified_for` = l'email tel qu'il était au moment où Pocket ID
  # a présenté le claim `email_verified: true`. La résolution :guest_host
  # exige `email_verified && email_verified_for == email` : si un autre
  # flux applicatif modifie `email` sans rafraîchir la paire, le droit
  # d'invité tombe mécaniquement (fail-closed).
  def change
    add_column :users, :email_verified_for, :string
  end
end
