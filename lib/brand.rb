# frozen_string_literal: true

# Marque de la distribution : identité du thème (Theme.current.brand), puis
# config/brand.yml, puis la variable d'environnement BRAND_<CHEMIN>
# (BRAND_HOST, BRAND_CREDIT_URL…).
# Point d'accès unique visé pour les valeurs de marque.
#
# `organization` : l'organisation qui opère l'instance, celle envers qui les
# spectateurs consentent (BRAND_ORGANIZATION), pas l'auteur du thème.
module Brand
  ENV_PREFIX = "BRAND"
  # Initiale devant laquelle « que », « de » s'élident (« qu'Acme »). Le h,
  # muet ou aspiré selon le mot, ne s'élide pas : « que Hexa ».
  ELIDING_INITIAL = /\A[aeiouyàâäéèêëîïôöùûüœæAEIOUYÀÂÄÉÈÊËÎÏÔÖÙÛÜŒÆ]/

  class << self
    def organization = values.fetch(:organization)
    def product_name = values.fetch(:product_name)
    def host = values.fetch(:host)
    def support_email = values.fetch(:support_email)
    def legal_identity = values.fetch(:legal_identity)
    def mailer_from = values.fetch(:mailer_from)
    def favicon = values.fetch(:favicon)
    def credit = values.fetch(:credit)
    def links = values.fetch(:links, {})
    def series = values.fetch(:series)

    # « qu' » ou « que » devant le nom de l'organisation (`word` = "que", "de").
    def elision(word, name = organization)
      name.match?(ELIDING_INITIAL) ? "#{word.delete_suffix("e")}'" : "#{word} "
    end

    # Variables des libellés qui nomment l'organisation : %{organization},
    # %{que_organization} (« qu'Acme »), %{de_organization} (« d'Acme »).
    def interpolations
      { organization: organization, que_organization: elision("que") + organization,
        de_organization: elision("de") + organization }
    end

    # Lu une fois : l'environnement ne change pas après le boot.
    def values
      @values ||= resolve(Theme.current.brand.deep_merge(Rails.application.config_for(:brand)), env: ENV)
    end

    # Valeurs + surcharges. Seules les clés présentes (thème ou fichier) se
    # surchargent : une variable BRAND_* inconnue est ignorée, une variable
    # vide aussi.
    def resolve(config, env:, path: [ ENV_PREFIX ])
      config.each_with_object(ActiveSupport::OrderedOptions.new) do |(key, value), resolved|
        key_path = path + [ key.to_s.upcase ]
        resolved[key] =
          if value.is_a?(Hash)
            resolve(value, env: env, path: key_path)
          else
            env[key_path.join("_")].presence || value
          end
      end.freeze
    end
  end
end
