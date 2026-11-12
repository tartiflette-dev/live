# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  /\At\z/, :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :marketing_consent_token,
  # Lien animateur : jeton posté au clic de /a vers /auth/pocket_id
  # (HostInvitationCookie::PARAM, journalisé si la request phase échoue) et
  # lien d'inscription Pocket ID, qui porte un jeton de création de compte.
  :host_invitation, :signup_url,
  # PII saisies dans les formulaires d'inscription (HTML `registration[name]`,
  # API `name`/`message`/`profile`) : jamais en clair dans « Parameters: ».
  # Ancrées comme `t` : `first_name`, `webinar_name`… restent lisibles.
  # Texte du chat (`body`, POST /w/:slug/messages) et des questions de la
  # file Q&R (`label`) : propos des participants, jamais dans les journaux.
  /\A(name|message|profile|body|label)\z/,
  # Rapport de violation CSP : porte l'adresse de la page, donc ses jetons en
  # query string (CspReportsController journalise un extrait assaini).
  :"csp-report"
]
