class LegalController < ApplicationController
  # Page publique, sans session : elle conditionne l'ouverture des
  # inscriptions (REGISTRATION_PRIVACY_URL pointe ici). La politique de
  # l'instance si elle en fournit une, sinon la page générique
  # (PrivacyPolicy).
  def confidentialite
    render PrivacyPolicy::TEMPLATE
  end
end
