# frozen_string_literal: true

require "test_helper"

class OidcProviderTest < ActiveSupport::TestCase
  setup { @previous = ENV.to_h.slice(*OidcProvider::SETTINGS) }
  teardown do
    OidcProvider::SETTINGS.each { |name| @previous.key?(name) ? ENV[name] = @previous[name] : ENV.delete(name) }
  end

  def configure(values)
    OidcProvider::SETTINGS.each { |name| ENV.delete(name) }
    values.each { |name, value| ENV[name] = value }
  end

  test "aucun défaut : sans variables, ni émetteur ni client" do
    configure({})

    assert_nil OidcProvider.issuer
    assert_nil OidcProvider.client_id
    assert_nil OidcProvider.client_secret
    refute_predicate OidcProvider, :configured?
  end

  test "une variable vide ou blanche compte comme absente" do
    configure("OIDC_ISSUER" => "   ", "OIDC_CLIENT_ID" => "", "OIDC_CLIENT_SECRET" => "s")

    assert_nil OidcProvider.issuer
    assert_equal %w[OIDC_ISSUER OIDC_CLIENT_ID], OidcProvider.missing_settings
  end

  test "les trois variables posées : configuré, valeurs lues telles quelles" do
    configure("OIDC_ISSUER" => "https://auth.example.test", "OIDC_CLIENT_ID" => "id", "OIDC_CLIENT_SECRET" => "s")

    assert_predicate OidcProvider, :configured?
    assert_equal "https://auth.example.test", OidcProvider.issuer
    assert_equal "id", OidcProvider.client_id
  end

  test "un client sans émetteur est refusé, en nommant ce qui manque" do
    configure("OIDC_CLIENT_ID" => "id", "OIDC_CLIENT_SECRET" => "s")

    error = assert_raises(OidcProvider::IncompleteConfiguration) { OidcProvider.assert_complete! }
    assert_includes error.message, "OIDC_ISSUER"
  end

  test "un secret seul est refusé aussi" do
    configure("OIDC_ISSUER" => "https://auth.example.test", "OIDC_CLIENT_SECRET" => "s")

    assert_raises(OidcProvider::IncompleteConfiguration) { OidcProvider.assert_complete! }
  end

  test "rien, ou un émetteur seul, n'est pas une configuration partielle" do
    configure({})
    assert_nothing_raised { OidcProvider.assert_complete! }

    configure("OIDC_ISSUER" => "https://auth.example.test")
    assert_nothing_raised { OidcProvider.assert_complete! }
  end
end
