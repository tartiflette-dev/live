# frozen_string_literal: true

require "test_helper"
require "open3"

# Factory du client Nextcloud : posée par
# config/application.rb, remplacée en test par une factory sans client.
# Deux défauts à tenir : un vrai client construit pendant les tests (il
# écrirait dans le Nextcloud réel), et une factory qui ne construit rien
# hors des tests (publication muette en production).
class NextcloudClientFactoryTest < ActiveSupport::TestCase
  NEXTCLOUD_VARIABLES = { "NEXTCLOUD_URL" => "https://files.example.invalid",
                          "NEXTCLOUD_USERNAME" => "compte-live",
                          "NEXTCLOUD_APP_PASSWORD" => "app-password" }.freeze

  test "production : client construit quand les trois variables sont posées, aucun sinon" do
    output, status = production_probe(NEXTCLOUD_VARIABLES)
    assert status.success?, output
    assert_equal "NextcloudClient https://files.example.invalid", output.lines.last.strip

    output, status = production_probe(NEXTCLOUD_VARIABLES.merge("NEXTCLOUD_APP_PASSWORD" => nil))
    assert status.success?, output
    assert_equal "NilClass", output.lines.last.strip
  end

  test "test : aucun vrai client, même avec les variables posées" do
    with_variables(NEXTCLOUD_VARIABLES) do
      assert_nil Rails.configuration.x.nextcloud_client_factory.call
      assert_kind_of NextcloudClient, NextcloudClient.from_env, "le client lui-même lit bien les variables"
    end
  end

  private

  def with_variables(values)
    previous = values.keys.index_with { |key| ENV.fetch(key, nil) }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # Même sonde que MailDeliveryConfigurationTest : l'application démarrée
  # en production dans un processus à part.
  def production_probe(variables)
    Open3.capture2e(
      { "RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => "1", "APP_HOST" => "live.example.invalid",
        "SOLID_QUEUE_IN_PUMA" => nil }.merge(variables),
      RbConfig.ruby, "-r", Rails.root.join("config/environment").to_s, "-e",
      "client = Rails.configuration.x.nextcloud_client_factory.call; puts [ client.class, client&.base_url ].compact.join(' ')",
      chdir: Rails.root.to_s
    )
  end
end
