# Programme d'un café (Webinar::Program) : sujet, intervenants annoncés,
# animateur du jour. Toute l'animation le saisit (owner, project_host,
# guest_host : `can_edit_program?`), pour que les rôles tournent sans passer
# par le propriétaire, qui trouve aussi ce formulaire dans son écran d'édition
# (même envoi ici : corriger le titre là-bas n'écrase pas le programme).
#
# Même périmètre que la régie : scope `where_animated_by`, 404 sans rôle
# (défense énumération), anonyme renvoyé à la connexion. Même borne que
# l'édition : plus rien ne se modifie une fois le direct commencé
# (Webinar::Edition#editable?). Rien n'est envoyé aux inscrits.
class WebinarProgramsController < ApplicationController
  include AnimateurBrowserPolicy
  before_action :authenticate_animateur!
  before_action :set_webinar
  before_action :require_editable

  def show
  end

  def update
    if @webinar.revise(program_params)
      redirect_to webinar_path(@webinar), notice: "Programme enregistré.", status: :see_other
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  # Le scope fait la défense énumération ; `can_edit_program?` reste l'autorité
  # (la page du webinaire montre le bouton sur la même règle).
  def set_webinar
    @webinar = Webinar.where_animated_by(current_user).find_by!(slug: params[:webinar_id])
    head :not_found unless @webinar.can_edit_program?(current_user)
  end

  def program_params
    params.require(:webinar).permit(:topic, :topic_summary, :lead_host_name, announced_speakers: [])
  end

  def require_editable
    return if @webinar.editable?

    redirect_to webinar_path(@webinar), alert: Webinar::Edition::NOT_EDITABLE_MESSAGE, status: :see_other
  end
end
