# Rattachement PROUVÉ d'un intervenant à une inscription : la personne qui a reçu, à l'adresse déclarée au lien
# participants privé, le mail RegistrationMailer#speaker_link confirme
# qu'elle est bien intervenue sous ce nom.
#
# Même schéma que /confirmer et /mc :
# - GET /rattacher?t=<link_token>  = page SANS effet (scanners de liens) ;
# - POST /rattacher?t=<link_token> = rattache (CSRF via button_to), usage
#   unique, 14 jours (Speaker#link_to_declared_registration!) ;
# - jeton en QUERY STRING `t` (filter_parameters), jamais en chemin ;
# - POST rend la page directement : une redirection écrirait l'URL et son
#   jeton en clair dans « Redirected to » du journal Rails.
# Aucune donnée personnelle dans ces pages (ni nom, ni adresse) : le nom de
# l'intervention est dans le mail. Aucun cookie posé.
class SpeakerLinksController < ApplicationController
  include TokenLinkPage
  before_action :set_speaker

  def show
  end

  # Inscription neuve (l'adresse n'avait qu'une identité provisoire ou une
  # pierre tombale) : mail de confirmation, le double opt-in reste entier.
  def create
    outcome = @speaker.link_to_declared_registration!
    return render :invalid, status: :gone unless outcome

    PendingRegistrationMail.confirmation(@speaker.registration, first: true) if outcome == :created
    render :linked
  end

  private

  def set_speaker
    @speaker = Speaker.find_by_link_token(params[:t])
    return render :invalid, status: :not_found unless @speaker

    @webinar = @speaker.webinar
    @voice = @webinar.voice
    render :invalid, status: :gone if @speaker.link_expired?
  end
end
