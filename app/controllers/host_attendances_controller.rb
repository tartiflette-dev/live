# Réponse de présence d'un animateur depuis son mail (HostAttendanceMailer).
#
# Même schéma que /rattacher et /confirmer :
# - GET  /presence?t=<jeton>[&reponse=oui|non] = page SANS effet (scanners de
#   liens) : elle rappelle le café et propose le bouton de la réponse choisie ;
# - POST /presence (t, reponse) = enregistre la réponse (CSRF via button_to)
#   et rend la page directement : une redirection écrirait le jeton en clair
#   dans « Redirected to » du journal Rails ;
# - jeton en QUERY STRING `t` (filter_parameters), jamais en chemin.
# Jeton inconnu (co-animateur retiré compris) → 404 ; café dépublié, commencé
# ou passé → 410. Aucun cookie d'identité ni d'accès : la session Rails ne
# porte que le jeton CSRF du bouton, aucune connexion n'est ouverte.
class HostAttendancesController < ApplicationController
  include TokenLinkPage

  ANSWER_PARAMS = { "oui" => "present", "non" => "absent" }.freeze

  before_action :require_html_format, only: :show
  before_action :set_attendance

  def show
    @proposed = ANSWER_PARAMS[params[:reponse]]
  end

  def create
    answer = ANSWER_PARAMS[params[:reponse]]
    return render :show, status: :unprocessable_entity unless answer

    @attendance.answer!(answer)
    render :answered
  end

  private

  def set_attendance
    @attendance = HostAttendance.find_by_token(params[:t])
    return render :unavailable, status: :not_found if @attendance.nil?

    @webinar = @attendance.webinar
    render :unavailable, status: :gone unless @webinar.host_attendance_open?
  end

  # Aperçu de lien en Accept non HTML : 406 plutôt qu'un MissingTemplate
  # (cf. WebinarsController).
  def require_html_format
    head :not_acceptable unless request.format.html? || request.format.all?
  end
end
