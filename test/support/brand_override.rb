# Brand relu le temps du bloc, avec des variables BRAND_* en plus de
# l'environnement. Les constantes qui figent Brand au chargement
# (ParticipantConsent::LABELS) sont chargées avant, avec la valeur du test.
module BrandOverride
  def with_brand(env)
    ParticipantConsent::LABELS
    values = Brand.instance_variable_get(:@values)
    Brand.instance_variable_set(:@values, Brand.resolve(Theme.current.brand.deep_merge(Rails.application.config_for(:brand)),
                                                        env: ENV.to_h.merge(env)))
    yield
  ensure
    Brand.instance_variable_set(:@values, values)
  end
end

ActiveSupport::TestCase.include(BrandOverride)
