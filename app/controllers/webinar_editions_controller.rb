class WebinarEditionsController < ApplicationController
  # Édition d'un webinaire par son PROPRIÉTAIRE seulement : date et heure
  # (saisies Europe/Paris, comme à la création), titre, description ; et
  # dépublication, qui l'annule. Ni co-animateur ni animateur du projet :
  # scope `hosted_by`, 404 pour les autres (défense énumération, comme
  # WebinarHostsController). Un webinaire commencé, en direct ou passé ne se
  # modifie plus (Webinar::Edition#editable?). L'écran porte aussi le
  # formulaire du programme, qui a son propre envoi (WebinarProgramsController) :
  # corriger le titre n'écrase pas un programme saisi entre-temps par un
  # co-animateur.
  #
  # Prévenir les inscrits ne se fait pas ici : l'annonce suit le commit du
  # modèle (WebinarChangeNotice).
  include AnimateurBrowserPolicy
  before_action :authenticate_animateur!
  before_action :set_webinar
  before_action :require_editable

  def show
  end

  def update
    if @webinar.revise(edition_params)
      redirect_to webinar_path(@webinar), notice: "Webinaire modifié.", status: :see_other
    else
      render :show, status: :unprocessable_entity
    end
  end

  # La case cochée est la confirmation explicite : elle annonce, sur la page,
  # combien d'inscrits seront prévenus. Vérifiée serveur, sans JavaScript.
  def unpublish
    if params[:confirmation] != "1"
      flash.now[:alert] = "Coche la case de confirmation pour annuler ce webinaire."
      render :show, status: :unprocessable_entity
    elsif @webinar.unpublish
      redirect_to webinar_path(@webinar), notice: "Webinaire annulé : il a quitté le catalogue et l’agenda.",
                                          status: :see_other
    else
      flash.now[:alert] = @webinar.errors.full_messages.to_sentence
      render :show, status: :unprocessable_entity
    end
  end

  private

  def set_webinar
    @webinar = Webinar.hosted_by(current_user.oidc_sub).find_by!(slug: params[:webinar_id])
  end

  def require_editable
    return if @webinar.editable?

    redirect_to webinar_path(@webinar), alert: Webinar::Edition::NOT_EDITABLE_MESSAGE, status: :see_other
  end

  def edition_params
    params.require(:webinar).permit(:title, :starts_at, :description)
  end
end
