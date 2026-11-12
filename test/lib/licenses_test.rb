# frozen_string_literal: true

require "test_helper"

# LICENSES/ porte le texte de chaque licence citée par REUSE.toml (`reuse lint`) ;
# les conditions additionnelles y sont une copie de ADDITIONAL_TERMS.md.
class LicensesTest < Minitest::Test
  ROOT = Pathname(File.expand_path("../..", __dir__))

  def test_chaque_licence_de_reuse_toml_a_son_texte
    identifiers = ROOT.join("REUSE.toml").read.scan(/^SPDX-License-Identifier = "([^"]+)"/).flatten
                      .flat_map { |expression| expression.split(/\s+(?:AND|OR|WITH)\s+/) }.uniq

    refute_empty identifiers
    identifiers.each do |id|
      assert ROOT.join("LICENSES/#{id}.txt").file?, "LICENSES/#{id}.txt manque (reuse download #{id})"
    end
  end

  def test_les_conditions_additionnelles_sont_celles_de_additional_terms
    assert_equal ROOT.join("ADDITIONAL_TERMS.md").read, ROOT.join("LICENSES/LicenseRef-Live-AGPL-3.0-Terms.txt").read,
                 "copier ADDITIONAL_TERMS.md dans LICENSES/LicenseRef-Live-AGPL-3.0-Terms.txt"
  end
end
