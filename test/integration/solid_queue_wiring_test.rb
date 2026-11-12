require "test_helper"
require "yaml"

# Solid_queue activé en production
# avec worker in-puma. Ce test lit les fichiers de configuration en source :
# il n'instancie ni conteneur ni supervisor. Une régression cross-cutting
# (un fichier réverté, une variable perdue, l'adapter décommenté) rougit ici
# sans dépendre du bus staging.
#
# Style repris de test/integration/mic_fail_loud_source_test.rb : garde-fou
# mécanique sur les sources.
class SolidQueueWiringTest < ActiveSupport::TestCase
  ROOT = Rails.root

  test "production_declares_solid_queue (adapter + connects_to writing: queue)" do
    src = ROOT.join("config/environments/production.rb").read
    assert_match(/^\s*config\.active_job\.queue_adapter\s*=\s*:solid_queue\b/, src,
      "production.rb doit déclarer :solid_queue comme adapter ActiveJob (ligne dé-commentée)")
    refute_match(/^\s*config\.active_job\.queue_adapter\s*=\s*:resque\b/, src,
      "aucune ligne active ne doit référencer l'adapter :resque")
    assert_match(/config\.solid_queue\.connects_to\s*=\s*\{\s*database:\s*\{\s*writing:\s*:queue\s*\}\s*\}/, src,
      "production.rb doit brancher SolidQueue sur la base `queue` (database.yml multi-db)")
  end

  test "queue_schema_loads (les 3 fichiers générés par solid_queue:install existent)" do
    assert ROOT.join("db/queue_schema.rb").exist?,
      "db/queue_schema.rb doit être commité (schema chargé par db:prepare via multi-db)"
    assert ROOT.join("config/queue.yml").exist?,
      "config/queue.yml doit être commité (dispatchers + workers)"
    assert ROOT.join("config/recurring.yml").exist?,
      "config/recurring.yml doit être commité (tâche retention_purge en production)"

    schema = ROOT.join("db/queue_schema.rb").read
    assert_match(/create_table\s+"solid_queue_jobs"/, schema,
      "queue_schema.rb doit créer la table solid_queue_jobs (invariant SolidQueue)")
  end

  # La variable elle-même est posée par la configuration de déploiement de l'instance.
  test "puma_plugin_follows_env (plugin :solid_queue branché sur SOLID_QUEUE_IN_PUMA)" do
    puma = ROOT.join("config/puma.rb").read
    assert_match(/plugin\s+:solid_queue\s+if\s+ENV\["SOLID_QUEUE_IN_PUMA"\]/, puma,
      "config/puma.rb doit brancher le plugin solid_queue sur la variable d'env (invariant existant, ne pas dupliquer)")
  end

  test "retention_purge est cron 03:17 Europe/Paris, pas UTC" do
    assert_equal "Europe/Paris", Rails.application.config.time_zone
    src = ROOT.join("config/recurring.yml").read
    yaml = YAML.safe_load(src, aliases: true)
    assert_equal "17 3 * * *", yaml.dig("production", "retention_purge", "schedule")
    refute_match(/03:17 UTC/, src)
    assert_match(/03:17 Europe\/Paris/, src)
    assert_match(/01:17 UTC en été/, src)
    assert_match(/02:17 UTC en hiver/, src)

    summer = Time.find_zone("Europe/Paris").parse("2026-07-15 03:17")
    winter = Time.find_zone("Europe/Paris").parse("2026-01-15 03:17")
    assert_equal 1, summer.utc.hour
    assert_equal 17, summer.utc.min
    assert_equal 2, winter.utc.hour
    assert_equal 17, winter.utc.min
  end
end
