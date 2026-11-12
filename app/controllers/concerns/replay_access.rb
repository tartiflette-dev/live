# Qui peut regarder le replay d'un webinaire — décision SERVEUR, partagée
# par la page, la vidéo, les sous-titres et les battements du lecteur :
#
#   1. compte connecté (Pocket ID), quel qu'il soit → tous les
#      replays publiés ; l'animation du webinaire voit aussi le sien avant
#      publication ;
#   2. inscription confirmée à CE webinaire, que ce navigateur a ouverte par
#      le lien personnel du replay (/w/:slug/replay?t=<jeton d'inscription>,
#      puis le bouton de la page) → ce replay seulement, publié ;
#   3. sinon personne.
#
# L'inscription est mémorisée par un cookie chiffré PROPRE AU WEBINAIRE (id +
# secret d'identité, comme le cookie de la salle), posé par un POST : un GET
# ne donne jamais d'identité, et le lien d'un tiers ne remplace pas
# l'inscription qu'un navigateur porte déjà. Elle cesse d'ouvrir le replay
# si elle est retirée de la salle par l'animation, effacée ou remplacée par
# une pierre tombale.
module ReplayAccess
  extend ActiveSupport::Concern

  COOKIE_PREFIX = "replay_access_"
  COOKIE_LIFETIME = 30.days

  included do
    helper_method :spectator_signup_url
  end

  private

  # @return [User, Registration, nil]
  def replay_viewer(webinar)
    current_user || replay_registration(webinar)
  end

  def replay_open_to?(replay, viewer)
    return false if replay.nil? || viewer.nil?

    replay.published? || (viewer.is_a?(User) && replay.webinar.animated_by?(viewer))
  end

  def replay_registration(webinar)
    id, secret = cookies.encrypted[replay_cookie_name(webinar)]
    return nil unless secret.is_a?(String) && secret.present?

    registration = replay_registrations(webinar).find_by(id: id)
    registration if registration && ActiveSupport::SecurityUtils.secure_compare(registration.identity_secret.to_s, secret)
  end

  # Inscription désignée par le jeton du lien personnel, si elle ouvre le replay.
  def replay_registration_for_token(webinar, token)
    return nil unless token.is_a?(String) && token.present?

    registration = replay_registrations(webinar).find_by(token: token)
    registration if registration && ActiveSupport::SecurityUtils.secure_compare(registration.token, token)
  end

  # @return [Boolean] false, sans rien changer, si ce navigateur porte déjà
  #   une AUTRE inscription valable à ce webinaire
  def remember_replay_registration(registration)
    kept = replay_registration(registration.webinar)
    return false if kept && kept != registration

    cookies.encrypted[replay_cookie_name(registration.webinar)] = {
      value: [ registration.id, registration.identity_secret ],
      httponly: true, secure: request.ssl?, same_site: :lax, expires: COOKIE_LIFETIME.from_now
    }
    true
  end

  # Webinaires dont ce navigateur porte un cookie de replay (à vérifier un
  # par un : le cookie seul ne prouve rien).
  def replay_cookie_webinar_ids
    cookies.to_h.keys.filter_map { |name| name[/\A#{COOKIE_PREFIX}(\d+)\z/o, 1]&.to_i }
  end

  def replay_registrations(webinar)
    webinar.registrations.confirmed.where(room_removed_at: nil, retired_email_digest: nil)
  end

  def replay_cookie_name(webinar)
    "#{COOKIE_PREFIX}#{webinar.id}"
  end

  # Lien de création d'un compte spectateur (jeton d'inscription créé chez le
  # fournisseur OIDC et posé dans l'environnement), proposé aux inscrits pour
  # débloquer tous les replays. nil s'il n'est pas posé ou ne pointe pas vers
  # l'émetteur OIDC de l'instance.
  def spectator_signup_url
    url = ENV["LIVE_SPECTATOR_SIGNUP_URL"].presence
    url if url && OidcProvider.link?(url)
  end
end
