class WebinarPublicationsController < ApplicationController
  # Publication de l'épisode dans Nextcloud,
  # depuis la page du webinaire :
  # - POST  /webinars/:webinar_id/publication lance (ou relance) le dépôt.
  #   Idempotent côté job : une relance ne renvoie que ce qui manque ou a
  #   changé (assemblage refait ou pas encore noté par un dépôt vérifié, cf.
  #   EpisodePublisher) et ne prévient que qui ne l'a pas été.
  # - PATCH /webinars/:webinar_id/publication « Valider et partager » : les
  #   vidéos en relecture que la page montrait (`names[]`) sont validées,
  #   puis le dépôt les déplace dans le dossier partagé et prévient les
  #   intervenants.
  #
  # Réservé à qui gère les enregistrements (owner / project_host) : un
  # co-animateur invité n'a pas accès aux fichiers (404, comme ailleurs).
  include AnimateurBrowserPolicy
  before_action :authenticate_animateur!
  before_action :set_webinar

  def create
    redirect_to webinar_path(@webinar), status: :see_other, **(refusal || launch)
  end

  def update
    redirect_to webinar_path(@webinar), status: :see_other, **(refusal || approve)
  end

  private

  def refusal
    return { alert: "Le direct n'est pas terminé : rien à publier." } unless @webinar.ended?
    return { alert: "Publication Nextcloud non configurée pour cette série." } unless EpisodePublication.configured_for?(@webinar)

    { notice: "Publication déjà en cours." } if @webinar.episode_publication&.busy?
  end

  def launch
    EpisodePublication.enqueue!(@webinar)
    { notice: "Publication dans Nextcloud lancée." }
  end

  def approve
    count = @webinar.episode_publication&.approve!(Array(params[:names]).grep(String), by: current_user.email).to_i
    return { alert: "Aucune vidéo en relecture à valider." } if count.zero?

    EpisodePublication.enqueue!(@webinar)
    { notice: "#{count} vidéo#{'s' if count > 1} validée#{'s' if count > 1} : déplacement vers le dossier partagé lancé." }
  end

  def set_webinar
    @webinar = Webinar.where_managed_by(current_user).find_by!(slug: params[:webinar_id])
  end
end
