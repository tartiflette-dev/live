# Garde-fou navigateur des pages ANIMATEUR uniquement (cf. commentaire
# ApplicationController). Les pages publiques spectateur/intervenant et
# l'API token n'incluent PAS ce concern — elles doivent rester servies à
# tout navigateur que LiveKit sait faire tourner.
module AnimateurBrowserPolicy
  extend ActiveSupport::Concern

  included do
    # Only allow modern browsers supporting webp images, web push, badges,
    # import maps, CSS nesting, and CSS :has (défaut Rails 8, restreint
    # aux actions animateur par l'appelant via `only:`/`except:`).
    allow_browser versions: :modern, **animateur_browser_policy_options
  end

  class_methods do
    # Surchargeable par le controller pour exclure ses actions publiques
    # (WebinarsController : viewer + join).
    def animateur_browser_policy_options
      {}
    end
  end
end
