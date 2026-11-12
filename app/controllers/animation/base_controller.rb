# Vues transverses de l'animation du projet (/animation/…) : elles portent sur
# tous les cafés et nomment des personnes, d'où la garde la plus étroite —
# animateur du projet (authorize_project_host!). Tout autre compte, spectateur
# ou co-animateur d'un seul café, reçoit 404.
module Animation
  class BaseController < ApplicationController
    include AnimateurBrowserPolicy

    before_action :authorize_project_host!
  end
end
