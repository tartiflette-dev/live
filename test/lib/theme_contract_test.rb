# frozen_string_literal: true

require "test_helper"
load Rails.root.join("script/theme-contract").to_s

class ThemeContractTest < ActiveSupport::TestCase
  test "docs/theme-contract.md est à jour" do
    assert_equal ThemeContract.render(ThemeContract.scan), Rails.root.join("docs/theme-contract.md").read,
                 "lancer script/theme-contract"
  end

  test "chaque pack définit toutes les propriétés obligatoires" do
    neutral = Theme.root.join("neutre_tokens.css")
    [ neutral, *Theme.root.glob("*/tokens.css") ].each do |tokens|
      missing = ThemeContract.required_properties - tokens.read.scan(/(--[\w-]+)\s*:/).flatten
      assert_empty missing, "#{tokens.relative_path_from(Rails.root)} ne définit pas : #{missing.join(", ")}"
    end
  end

  test "le thème undust (gem de charte) satisfait le contrat" do
    require_undust_theme!
    defined = Rails.root.glob("app/assets/tailwind/undust_*.css").flat_map { |css| css.read.scan(/(--[\w-]+)\s*:/).flatten }

    assert_empty ThemeContract.required_properties - defined
  end
end
