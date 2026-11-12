# frozen_string_literal: true

require "test_helper"

# db/schema.rb déclare la version de la dernière migration. Une version trop
# haute (renumérotation, fusion de deux branches) passerait sans bruit : la
# base de test se charge depuis le schéma et ne voit aucune migration en
# attente, alors que `db:migrate` au déploiement en jouerait une.
class MigrationVersionsTest < ActiveSupport::TestCase
  test "db/schema.rb porte le numéro de la dernière migration" do
    latest = ActiveRecord::Base.connection_pool.migration_context.migrations.map(&:version).max
    declared = File.read(Rails.root.join("db/schema.rb"))[/define\(version: ([\d_]+)\)/, 1].delete("_").to_i

    assert_equal latest, declared
  end
end
