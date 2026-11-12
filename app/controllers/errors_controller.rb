# Pages hors-session : une erreur d'apex est une PAGE Force, rendue par le
# thème (ErrorPageComponent + pages.css de la gem undust-charte pour le thème
# undust).
# Rails y arrive via `config.exceptions_app`. Aucune session, aucun cache.
class ErrorsController < ApplicationController
  layout "force"

  # Surfaces Force de la gem : 403/404/500. Les autres codes (400/422…)
  # retombent sur 500 — un 422 peint en 404 mentirait.
  CODES = %w[403 404 500].freeze

  def show
    @code = code
    # Les pages Force sont HTML EXCLUSIVEMENT (gem undust-charte). Un
    # consommateur qui demandait JSON (aperçu WhatsApp) ne
    # DOIT pas provoquer un second 500 côté ErrorsController :
    # on force la négociation sur HTML avant render.
    request.format = :html
    render :show, status: @code.to_i, formats: [ :html ]
  end

  private

  def code
    demande = params[:code].presence || request.path_info.to_s.delete_prefix("/")
    CODES.include?(demande) ? demande : "500"
  end
end
