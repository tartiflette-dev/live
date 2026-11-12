require "test_helper"

# Le marqueur d'état info est un glyphe, jamais la lettre « i »
# (lue comme une initiale une fois passée en capitales).
class EtatInfoPictogramTest < ActiveSupport::TestCase
  setup { require_undust_theme! }

  test "l'hôte remplace la lettre i par le glyphe d'aide" do
    css = Rails.root.join("app/assets/tailwind/theme_undust.css").read

    assert_match(/\.etat--info::before/, css)
    assert_match(%r{icons/aide\.svg}, css)
    assert_match(/content:\s*""/, css)
  end
end
