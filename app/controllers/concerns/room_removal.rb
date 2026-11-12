# Règle unique du retrait de la salle :
# un navigateur qui porte, pour CE webinaire, une identité RETIRÉE depuis la
# régie (`room_removed_at`) est retiré de ce webinaire, quel que soit le rôle
# qu'il demande. Modèle de menace : docs/moderation.md.
#
# Retirer ≠ révoquer : un intervenant seulement révoqué par le propriétaire
# (`revoked_at`) n'est pas retiré ; son navigateur revoit le formulaire du lien
# partagé et peut recevoir un nouveau lien.
#
# Identités lues dans le navigateur :
#   • cookie d'intervenant du webinaire (`share_speaker_<id>`) ;
#   • cookie d'inscription (`registration_id`), id ET secret d'identité de
#     l'inscription (`registration_in_browser`) ;
#   • trace `room_removed_<id>`, posée dès qu'une identité retirée est vue dans
#     ces cookies, ou quand le cookie d'inscription (unique pour tous les
#     webinaires) en remplace un qui désignait une inscription retirée.
# Ces cookies ne naissent que d'un POST protégé CSRF (formulaire du lien
# participants privé, inscription à accès immédiat, confirmation
# d'inscription) : aucune entrée GET n'en pose, sans quoi un lien envoyé par un
# tiers pourrait imposer son identité retirée.
#
# Un jeton d'intervenant retiré PRÉSENTÉ (corps, en-tête X-Speaker-Token) ferme
# la requête, sans repli spectateur, mais ne laisse aucune trace : un jeton se
# transmet par simple lien.
#
# Appelée partout où une salle s'ouvre : RoomParticipant (jeton LiveKit et
# main pré-déclarée qu'il lève, préférences de périphériques, question
# affichée), CurrentRegistration (main levée, indicateur d'enregistrement,
# page publique), RoomAuthor (discussion, sondages), InvitationsController
# (lien participants privé, participant ou spectateur),
# RegistrationsController (inscription et son accès immédiat, confirmation,
# accès), WebinarsController#join. Les animateurs authentifiés (owner,
# project_host, guest_host) ne sont jamais retirés par cette voie.
module RoomRemoval
  extend ActiveSupport::Concern

  SPEAKER_COOKIE_PREFIX = "share_speaker_"
  REMOVAL_COOKIE_PREFIX = "room_removed_"
  MAX_COOKIE_LIFETIME = 30.days

  private

  def room_removed?(webinar, speaker_token: nil)
    return false if webinar.nil? || webinar.animated_by?(current_user)

    # Une page appelle la règle plusieurs fois (inscription courante, vue) :
    # une seule lecture par requête.
    @room_removed ||= {}
    @room_removed.fetch([ webinar.id, speaker_token ]) do |key|
      @room_removed[key] = removed_identity_in_browser?(webinar) || removed_speaker_token?(webinar, speaker_token)
    end
  end

  # À appeler avant de remplacer le cookie d'inscription : s'il désigne une
  # inscription retirée (d'un webinaire quelconque), le retrait reste tracé pour
  # ce webinaire-là.
  def keep_room_removal_trace
    removed = removed_registration_in_browser(Registration.removed_from_room)
    mark_room_removed(removed.webinar_id) if removed
  end

  # Inscription que porte ce navigateur, parmi `scope` : le cookie
  # `registration_id` (posé par un POST, CurrentRegistration
  # #remember_registration) porte son id ET son secret d'identité. Un
  # cookie sans le bon secret ne désigne personne :
  # format d'avant (id seul), inscription d'un autre navigateur.
  def registration_in_browser(scope)
    id, secret = cookies.encrypted[:registration_id]
    return nil unless secret.is_a?(String) && secret.present?

    registration = scope.find_by(id: id)
    registration if registration && ActiveSupport::SecurityUtils.secure_compare(registration.identity_secret.to_s, secret)
  end

  # Vérifications de RETRAIT seulement : le format d'avant le secret (id
  # seul, posé par un POST avant ce changement, cookie chiffré donc jamais
  # forgé) désigne encore une inscription retirée, pour qu'un ancien
  # spectateur retiré reste détecté. Il ne donne jamais accès
  # (`registration_in_browser`).
  def removed_registration_in_browser(scope)
    legacy_id = cookies.encrypted[:registration_id]
    return scope.find_by(id: legacy_id) if legacy_id.is_a?(Integer)

    registration_in_browser(scope)
  end

  def registration_cookie_value(registration)
    [ registration.id, registration.identity_secret ]
  end

  # Ce navigateur est l'intervenant `speaker` de ce webinaire (POST du lien
  # partagé seulement).
  def remember_room_speaker(webinar, speaker)
    cookies.encrypted[room_speaker_cookie(webinar)] = identity_cookie(speaker.id, webinar)
  end

  def room_speaker_id(webinar)
    cookies.encrypted[room_speaker_cookie(webinar)]
  end

  # Cookie d'identité d'un participant : il survit à la fermeture du navigateur
  # jusqu'au lendemain de la fin prévue du webinaire (ou de maintenant, pour
  # un direct lancé ou repris après la date prévue), au plus 30 jours.
  # SameSite=Lax pour qu'un lien reçu par mail fonctionne, HttpOnly.
  def identity_cookie(value, webinar)
    expires = [ [ webinar.planned_ends_at, Time.current ].max + 1.day, MAX_COOKIE_LIFETIME.from_now ].min
    browser_cookie(value, expires: expires)
  end

  # Page « Accès retiré » (403) ; `@webinar` = le webinaire retiré.
  def render_room_removed
    render "application/room_removed", status: :forbidden, layout: "application"
  end

  def removed_identity_in_browser?(webinar)
    return true if cookies.encrypted[removal_cookie(webinar.id)].present?

    removed = webinar.speakers.removed_from_room.exists?(id: room_speaker_id(webinar)) ||
              removed_registration_in_browser(webinar.registrations.removed_from_room).present?
    mark_room_removed(webinar.id) if removed
    removed
  end

  def removed_speaker_token?(webinar, speaker_token)
    speaker_token.is_a?(String) && speaker_token.present? && webinar.speakers.removed_from_room.exists?(token: speaker_token)
  end

  def mark_room_removed(webinar_id)
    cookies.encrypted[removal_cookie(webinar_id)] = browser_cookie(true, expires: MAX_COOKIE_LIFETIME.from_now)
  end

  def room_speaker_cookie(webinar)
    "#{SPEAKER_COOKIE_PREFIX}#{webinar.id}"
  end

  def removal_cookie(webinar_id)
    "#{REMOVAL_COOKIE_PREFIX}#{webinar_id}"
  end

  def browser_cookie(value, expires:)
    { value: value, httponly: true, secure: request.ssl?, same_site: :lax, expires: expires }
  end
end
