# frozen_string_literal: true

require "test_helper"

class BrandTest < ActiveSupport::TestCase
  test "thème undust : identité du thème, valeurs d'instance neutres de l'environnement de test" do
    require_undust_theme!
    assert_equal [ "Studio Exemple", "Live", "live.example.test", "contact@example.test", "noreply@live.example.test", "/icon.svg" ],
                 [ Brand.organization, Brand.product_name, Brand.host, Brand.support_email, Brand.mailer_from, Brand.favicon ]
    assert_equal [ "undust", "https://undust.co" ], [ Brand.credit.label, Brand.credit.url ]
  end

  test "distribution undust : le nom du produit vient du seul registre de la charte, jamais d'une valeur en dur" do
    require_undust_theme!
    # Sans l'apport de l'adaptateur (registre), ni themes/undust/theme.yml ni
    # config/brand.yml ne fournissent de nom : le registre est la seule source.
    sans_registre = Theme::Pack.instance_method(:brand).bind_call(Theme.current)
    assert_not sans_registre.deep_merge(Rails.application.config_for(:brand)).key?(:product_name)

    assert_equal Undust::Charte::AppIdentity.current.display_name, Brand.product_name
    assert_equal "Studio", resolve("BRAND_PRODUCT_NAME" => "Studio").product_name
  end

  test "l'organisation vient de BRAND_ORGANIZATION, jamais du thème ; l'élision suit son initiale" do
    assert_not Theme.current.brand.key?(:organization)
    acme = resolve("BRAND_ORGANIZATION" => "Acme")

    assert_equal "Acme", acme.organization
    assert_equal [ "qu'", "d'", "que ", "de " ], [ Brand.elision("que", "Acme"), Brand.elision("de", "Écoles"),
                                                   Brand.elision("que", "Studio"), Brand.elision("de", "Hexa") ]
    assert_equal [ "qu'", "d'" ], [ Brand.elision("que", "Yvelines"), Brand.elision("de", "Œuvres") ]
    assert_equal({ organization: "Studio Exemple", que_organization: "que Studio Exemple", de_organization: "de Studio Exemple" },
                 Brand.interpolations)
  end

  test "l'identité vient du thème, config/brand.yml prime sur elle" do
    assert_equal Theme.current.brand.dig(:credit, :url), Brand.credit.url
    assert_equal "Distribution", resolve({}, organization: "Distribution").organization
  end

  test "une variable BRAND_<CHEMIN> surcharge sa clé, imbriquée comprise" do
    brand = resolve("BRAND_PRODUCT_NAME" => "Studio", "BRAND_CREDIT_URL" => "https://example.invalid")

    assert_equal [ "Studio", "https://example.invalid" ], [ brand.product_name, brand.credit.url ]
    assert_equal [ Brand.host, Brand.credit.label ], [ brand.host, brand.credit.label ]
  end

  test "une variable BRAND_* sans clé dans le fichier est ignorée" do
    brand = resolve("BRAND_CREDIT_LOGO" => "/x.svg", "BRAND_INCONNUE" => "x")

    assert_equal Brand.credit.to_h, brand.credit.to_h
    assert_not brand.key?(:inconnue)
  end

  test "une variable BRAND_* vide garde la valeur du fichier" do
    assert_equal [ Brand.host, Brand.credit.url ],
                 resolve("BRAND_HOST" => "", "BRAND_CREDIT_URL" => "  ").then { |brand| [ brand.host, brand.credit.url ] }
  end

  test "config/brand.yml ne porte aucune valeur d'instance : hôte et expéditeur dérivés d'APP_HOST, sans contact ni organisation" do
    with_env("APP_HOST" => "live.example.org", "MAIL_FROM" => nil) do
      shared = Rails.application.config_for(:brand, env: "production")

      assert_equal [ "live.example.org", "noreply@live.example.org", nil, nil, nil ],
                   shared.values_at(:host, :mailer_from, :support_email, :legal_identity, :organization)
    end
  end

  test "MAIL_FROM du déploiement reste lu, BRAND_MAILER_FROM prime" do
    with_env("MAIL_FROM" => "deploy@example.invalid") do
      assert_equal "deploy@example.invalid", resolve.mailer_from
      assert_equal "brand@example.invalid", resolve("BRAND_MAILER_FROM" => "brand@example.invalid").mailer_from
    end
  end

  private

  def resolve(variables = {}, distribution = {})
    config = Theme.current.brand.deep_merge(Rails.application.config_for(:brand)).deep_merge(distribution)
    Brand.resolve(config, env: variables)
  end

  def with_env(overrides)
    previous = overrides.keys.index_with { |key| ENV[key] }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
