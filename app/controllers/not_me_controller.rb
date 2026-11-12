# « Ce n'est pas moi » — POST /w/:slug/not_me (CSRF, button_to) : ce
# navigateur oublie l'inscription qu'il porte pour ce webinaire. Suite de la
# Le cookie d'inscription est persistant et un navigateur garde
# sa première inscription valide (409 sur une autre) ; sur un ordinateur
# partagé, la personne suivante entrait sous le nom de la précédente, et une
# deuxième adresse dans le même navigateur recevait 409.
#
# Proposé là où ce navigateur porte une inscription valide : page « Ce
# navigateur est déjà inscrit » (409), salle spectateur, page du webinaire
# avant le direct.
#
# Garanties (docs/moderation.md) :
#   - n'efface QUE le cookie d'inscription, et seulement s'il désigne une
#     inscription de CE webinaire (il est unique pour tous les webinaires) ;
#   - ne lève JAMAIS un retrait : navigateur retiré (RoomRemoval) → « Accès
#     retiré » (403), rien n'est effacé ; la trace `room_removed_<id>` n'est
#     jamais touchée, et le retrait que désignerait le cookie reste tracé ;
#   - ne touche ni l'inscription en base, ni le cookie d'intervenant.
class NotMeController < ApplicationController
  include CurrentRegistration

  def create
    @webinar = Webinar.published.find_by!(slug: params[:slug])
    @voice = @webinar.voice
    return render_room_removed if room_removed?(@webinar)

    notice = Voice.t("registrations.not_me.forgotten", voice: @voice) if forget_registration(@webinar)
    redirect_to public_webinar_path(@webinar.slug), status: :see_other, notice: notice
  end
end
