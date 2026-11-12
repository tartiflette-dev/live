require "test_helper"

class PackTest < ActiveSupport::TestCase
  # Invariants du modèle Pack et de Webinar#price_label.

  def valid_attrs(**overrides)
    { name: "Bootcamp IA", price_cents: 49000, host_sub: "sub-marc" }.merge(overrides)
  end

  # ---- Validations ----

  test "requires name, host_sub, non-negative price_cents" do
    p = Pack.new
    assert_not p.valid?
    assert p.errors.of_kind?(:name, :blank)
    assert p.errors.of_kind?(:host_sub, :blank)

    p.price_cents = -1
    assert_not p.valid?
    assert p.errors.of_kind?(:price_cents, :greater_than_or_equal_to)
  end

  test "name length ≤ 100" do
    p = Pack.new(valid_attrs(name: "x" * 101))
    assert_not p.valid?
    assert p.errors.of_kind?(:name, :too_long)
  end

  test "création valide avec attributs minimaux" do
    assert Pack.new(valid_attrs).valid?
  end

  # ---- has_many :webinars, dependent: :nullify ----

  test "destroy sur pack nullifie pack_id sur les webinaires rattachés" do
    pack = Pack.create!(valid_attrs)
    w = Webinar.create!(
      title: "Session 1", starts_at: 1.day.from_now, host_sub: "sub-marc", pack: pack
    )
    assert_equal pack.id, w.pack_id

    pack.destroy!
    assert_nil w.reload.pack_id
  end

  # ---- Webinar#free? et #price_label — 3 cas ----

  test "price_label — gratuit (price_cents=0, sans pack)" do
    w = Webinar.new(price_cents: 0)
    assert_predicate w, :free?
    assert_equal "Gratuit", w.price_label
  end

  test "price_label — prix propre formaté fr" do
    w = Webinar.new(price_cents: 9900)
    assert_not_predicate w, :free?
    # Locale :fr : « 99,00 € » - le séparateur valeur/unité peut être ASCII
    # space ou NBSP selon la config i18n de l'env (regex couvre les deux).
    assert_match(/\A99,00[ \u00A0]€\z/, w.price_label)
  end

  test "price_label — rattaché à un pack (le prix du pack prime, name affiché)" do
    pack = Pack.create!(valid_attrs(name: "Bootcamp IA"))
    w = Webinar.new(price_cents: 0, pack: pack)
    assert_not_predicate w, :free?
    assert_equal "Inclus dans le pack Bootcamp IA", w.price_label
  end
end
