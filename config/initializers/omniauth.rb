# frozen_string_literal: true

# Connexion animateur par OpenID Connect, auprès de n'importe quel
# fournisseur conforme (Pocket ID, Keycloak, Authentik, Dex…). Le spectateur
# et l'intervenant utilisent un lien signé et n'entrent JAMAIS dans ce flow
# (aucun require_login sur les pages publiques — cf. routes.rb).
#
# Configuration de l'instance, sans défaut dans le code (lib/oidc_provider.rb) :
# OIDC_ISSUER, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, et APP_HOST pour le retour.
# Sans elle, la connexion OIDC n'est pas montée ; en local, la connexion de
# développement prend le relais (lib/dev_login.rb, docs/quickstart.md). Des
# identifiants de client sans émetteur refusent le démarrage en production.
#
# Le fournisseur garde le nom `pocket_id` : il fixe les chemins
# /auth/pocket_id et /auth/pocket_id/callback, déjà enregistrés comme
# callbacks chez les fournisseurs des instances existantes.
#
# Deux invariants :
#
#   1. redirect_uri EXPLICITE dérivé de `APP_HOST`.
#      omniauth_openid_connect ne déduit PAS le callback de la requête ;
#      sans redirect_uri, l'authorize part sans le paramètre et un
#      fournisseur comme Pocket ID retombe sur le PREMIER callback
#      enregistré du client (celui d'une autre instance).
#
#   2. PKCE ACTIF — S256 challenge auto par omniauth_openid_connect quand
#      `pkce: true`. Le client OIDC doit autoriser PKCE.
#
# En test : `OmniAuth.config.test_mode = true` (setup du test) — ce provider
# est monté avec des valeurs factices pour que la request phase et le mock
# `omniauth.auth` fonctionnent sans réseau (discovery désactivée).

OidcProvider.assert_complete! if Rails.env.production?

# Lu par l'écran de connexion (sessions/new) : le bouton OIDC n'apparaît que
# si le provider est monté. Posé dans les deux cas : une clé `config.x` jamais
# posée vaut un OrderedOptions vide, donc vrai.
Rails.application.config.x.oidc_login = OidcProvider.configured? || Rails.env.test?

if Rails.application.config.x.oidc_login
  Rails.application.config.middleware.use OmniAuth::Builder do
    provider :openid_connect,
      name: :pocket_id,
      issuer: OidcProvider.issuer || "https://oidc.example.test",
      discovery: !Rails.env.test?,
      response_type: :code,
      # `groups` : claim des groupes du fournisseur (ADD_GROUPS_CLAIM côté
      # client Pocket ID). Il atterrit dans `auth.extra.raw_info["groups"]`
      # et sert à `User#project_host?`. Son absence est tolérée —
      # SessionsController conserve l'ancienne valeur et le repli ENV
      # `LIVE_PROJECT_HOSTS` prend la relève.
      scope: %i[openid email profile groups],
      pkce: true,
      client_auth_method: :secret_post,
      client_options: {
        identifier: OidcProvider.client_id || "test-client-id",
        secret: OidcProvider.client_secret || "test-client-secret",
        # OBLIGATOIRE — cf. invariant 1 en tête.
        redirect_uri: "https://#{ENV.fetch('APP_HOST', 'localhost')}/auth/pocket_id/callback"
      }
  end

  OmniAuth.config.on_failure = ->(env) {
    SessionsController.action(:oidc_failure).call(env)
  }

  # Lien animateur (/a) : le jeton part avec le POST /auth/pocket_id et
  # attend le retour du fournisseur dans un cookie chiffré (HostInvitationCookie).
  OmniAuth.config.before_request_phase = ->(env) {
    HostInvitationCookie.remember_from_request_phase(env)
  }
end

# Bouton POST via button_to + omniauth-rails_csrf_protection : la request
# phase GET est refusée. On silence le warning associé (informatif, non
# actionnable ici).
OmniAuth.config.allowed_request_methods = %i[post]
OmniAuth.config.silence_get_warning = true
