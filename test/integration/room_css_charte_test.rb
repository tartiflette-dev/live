require "test_helper"

# Garde-fous de la charte sur room.css :
# le rouge ne s'emploie JAMAIS en aplat, et aucune
# règle de tuile ne doit atteindre autre chose que des tuiles.
class RoomCssCharteTest < ActiveSupport::TestCase
  CSS = Rails.root.join("app/assets/stylesheets/room.css").read.gsub(%r{/\*.*?\*/}m, "")

  test "aucun aplat critique : un fond status-critical n'existe que teinté (color-mix) ou transparent" do
    flat = CSS.scan(/background(?:-color)?\s*:\s*var\(--status-critical[^;]*;/)
    assert_empty flat, "aplat rouge dans room.css (le rouge dit l'écart sans aplat) : #{flat.inspect}"
  end

  test "les règles de tuile visent `div[data-lk-source]`, jamais `[data-lk-source]` nu" do
    # Exception : `[data-lk-source]:has(> .lk-spotlight-toggle)` (mise en avant)
    # ne vise que les tuiles, par construction (elles seules portent le
    # bouton de mise en avant).
    bare = CSS.scan(/body\.room\s+\[data-lk-source\][^{,]*/).reject { |s| s.include?(":has(> .lk-spotlight-toggle)") }
    assert_empty bare, "sélecteur `[data-lk-source]` non borné : vendor pose l'attribut aussi sur les boutons Micro/Caméra et <video> : #{bare.inspect}"
  end
end
