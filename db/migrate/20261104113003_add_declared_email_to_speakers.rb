# Rattachement PROUVÉ d'un intervenant à une inscription :
# une adresse saisie au lien participants privé sans preuve de
# la boîte (seul le cookie d'une inscription confirmée en tient lieu), neuve
# ou déjà inscrite, reste DÉCLARÉE sur l'intervenant ; le rattachement attend
# le clic de la personne dans sa boîte (`link_token`, usage unique, 14 jours).
# Additive et nullable.
class AddDeclaredEmailToSpeakers < ActiveRecord::Migration[8.1]
  def change
    add_column :speakers, :declared_email, :string, limit: 254
    add_column :speakers, :link_token, :string
    add_index :speakers, :link_token, unique: true, where: "link_token IS NOT NULL"
  end
end
