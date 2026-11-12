# Horloge du lien de rattachement quand il est repris d'un intervenant
# remplacé. Vide : c'est created_at qui compte (Speaker#link_expired?).
# On ne recule pas created_at du successeur : la liste admin trie dessus.
class AddLinkIssuedAtToSpeakers < ActiveRecord::Migration[8.1]
  def change
    add_column :speakers, :link_issued_at, :datetime
  end
end
