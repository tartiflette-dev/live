# Qui écrit dans la salle (discussion, réponses aux sondages) — décidé
# SERVEUR à chaque appel, même ordre que Api::TokensController#resolve_role :
#   1. animateur du webinaire (session Pocket ID, Webinar#animated_by?) ;
#   2. intervenant nominatif ACTIF (jeton en en-tête X-Speaker-Token —
#      jamais dans l'URL, qui finit dans les journaux du proxy) ;
#   3. inscription confirmée (cookie chiffré, CurrentRegistration) à un
#      webinaire publié, payée s'il est payant, une fois le direct ouvert.
# Hors animation, un navigateur retiré de ce webinaire (RoomRemoval) n'écrit
# ni ne lit, quel que soit le rôle qu'il présente.
# Aucun champ d'identité ni de nom n'est lu du client. Sans rôle : 403
# `participant_required`. Le contrôleur pose `@webinar` avant `set_author`.
# Distinct de RoomParticipant (qui émet le jeton LiveKit, rôle de salle) :
# écrire exige en plus, pour un spectateur, un direct ouvert et le paiement.
module RoomAuthor
  extend ActiveSupport::Concern
  include CurrentRegistration

  # `credential` : base de la clé de débit (hachée), propre à l'auteur — deux
  # spectateurs derrière le même NAT d'entreprise ne partagent pas leur
  # quota. Jeton d'inscription ou d'intervenant plutôt que l'identité : un
  # id se réutilise quand une base est remise à zéro (tests, store fichier
  # partagé entre processus), un jeton aléatoire jamais.
  # `registration` : l'inscription du spectateur (nil pour les autres rôles).
  Author = Data.define(:identity, :name, :credential, :registration)

  private

  def set_author
    @author = animator_author || participant_author
    render json: { error: "participant_required" }, status: :forbidden unless @author
  end

  def animator_author
    return unless @webinar.animated_by?(current_user)

    identity = "host-#{current_user.oidc_sub}"
    Author.new(identity: identity, name: current_user.chat_alias, credential: identity, registration: nil)
  end

  def participant_author
    return if room_removed?(@webinar, speaker_token: request.headers["X-Speaker-Token"])

    speaker_author || viewer_author
  end

  def speaker_author
    _webinar, speaker = Webinar.find_for_speaker(slug: @webinar.slug, token: request.headers["X-Speaker-Token"])
    return unless speaker

    Author.new(identity: "speaker-#{speaker.id}", name: speaker.name, credential: speaker.token, registration: nil)
  end

  def viewer_author
    return unless @webinar.visibility_published? && !@webinar.draft?

    registration = current_registration
    return unless registration && (@webinar.free? || registration.paid_confirmed?)

    Author.new(identity: "viewer-#{registration.id}", name: registration.name, credential: registration.token,
               registration: registration)
  end

  def rate_limit_key
    Digest::SHA256.hexdigest(@author.credential)
  end
end
