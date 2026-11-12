class AddShareTokenToWebinars < ActiveRecord::Migration[8.1]
  # Lien d'invitation intervenant PARTAGÉ (un jeton opaque par webinaire,
  # distinct des Webinar#speaker_token legacy signé et des Speaker#token
  # nominatifs). NULL = pas de lien partagé actif. Un seul jeton actif
  # par webinaire ; régénérer = overwrite ; désactiver = NULL.
  #
  # Index unique partiel : on indexe uniquement les valeurs non-NULL
  # (plusieurs webinaires sans lien partagé = plusieurs NULL autorisés).
  def change
    add_column :webinars, :share_token, :string
    add_index  :webinars, :share_token, unique: true, where: "share_token IS NOT NULL"
  end
end
