# Transport du jeton de lien animateur à travers l'aller-retour Pocket ID.
#
# Le clic « Se connecter avec mon compte » de /a envoie le jeton dans
# le POST /auth/pocket_id ; la request phase OmniAuth le pose ici, dans un
# cookie CHIFFRÉ de courte durée, avant de rediriger vers Pocket ID.
# SessionsController#oidc_callback le relit au retour. Pas dans la session :
# le callback fait `reset_session` (défense fixation de session).
#
# SameSite=Lax : le retour de Pocket ID est une navigation de premier niveau
# depuis un autre site, le cookie doit l'accompagner. L'expiration est aussi
# portée par le message chiffré (métadonnées Rails) : un cookie rejoué au-delà
# de TTL ne vaut rien.
module HostInvitationCookie
  NAME = "host_invitation"
  PARAM = "host_invitation"
  TTL = 30.minutes

  module_function

  # Branché sur OmniAuth.config.before_request_phase (après la vérification
  # CSRF). Une connexion lancée sans jeton efface un jeton laissé par une
  # tentative précédente : seule la connexion partie de /a accepte le lien.
  def remember_from_request_phase(env)
    request = ActionDispatch::Request.new(env)
    token = request.POST[PARAM]
    if token.is_a?(String) && token.present?
      request.cookie_jar.encrypted[NAME] = {
        value: token, expires: TTL, httponly: true, secure: request.ssl?, same_site: :lax
      }
    else
      request.cookie_jar.delete(NAME)
    end
  end

  def read(cookies)
    token = cookies.encrypted[NAME]
    token if token.is_a?(String) && token.present?
  end

  def forget(cookies)
    cookies.delete(NAME)
  end
end
