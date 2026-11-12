# Choix « J'observe » / « Je participe » de l'inscrit à l'entrée de la salle
# (webinars/room.html.erb, rooms/participation_choice.js), avant le jeton
# LiveKit. L'inscription est celle de CE navigateur (CurrentRegistration :
# cookie chiffré, accès à la salle de ce webinaire, jamais retirée) ; aucun
# paramètre client ne désigne une inscription. Sans elle → 403.
#
# Le choix ne donne aucun droit de publier : « Je participe » lève la main,
# l'animation l'admet depuis la régie (PublishPermission) ; « J'observe »
# baisse la main encore en attente (HandRaiseControl#follow_participation).
# CSRF actif (X-CSRF-Token, refus en JSON 422) et JSON exigé.
class ParticipationsController < ApplicationController
  include CurrentRegistration
  include JsonOnly
  include JsonCsrfRefusal

  # Entrée : { participation: "spectator" | "participant" }.
  # 200 : { participation } (le choix gardé) ; 422 si la valeur est inconnue.
  def update
    @webinar = Webinar.published.find_by!(slug: params[:slug])
    registration = current_registration
    return render json: { error: "registration_required" }, status: :forbidden unless registration

    participation = params[:participation].to_s
    unless Registration.participations.key?(participation)
      return render json: { error: "invalid_participation" }, status: :unprocessable_entity
    end

    # Déjà choisi (second onglet, double envoi) : rien ne change, la réponse
    # donne le choix gardé.
    HandRaiseControl.new(@webinar).follow_participation(registration) if registration.choose_participation!(participation)
    render json: { participation: registration.participation }
  end
end
