class AddCatalogueFieldsToWebinars < ActiveRecord::Migration[8.1]
  # Catalogue public. Additive SQLite uniquement.
  #
  # visibility : draft|published — distinct de `state` (cycle du direct
  #              draft→live→ended). Un draft n'apparaît pas au catalogue.
  # kind       : cafe_ia|bootcamp
  # price_cents: 0 = gratuit
  # pack_id    : entier nullable SANS FK — le modèle Pack arrive plus tard
  # layout     : JSON nullable, consommé par la scène
  def change
    add_column :webinars, :description, :text
    add_column :webinars, :visibility, :string, null: false, default: "draft"
    add_column :webinars, :kind, :string, null: false, default: "cafe_ia"
    add_column :webinars, :price_cents, :integer, null: false, default: 0
    add_column :webinars, :pack_id, :integer
    add_column :webinars, :layout, :json
  end
end
