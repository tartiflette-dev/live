# Politique de sécurité du contenu, EN MODE BLOQUANT, après une période
# d'observation en Report-Only sans `[csp-report]` inattendu. Les
# violations continuent d'être rapportées à
# /csp-reports (CspReportsController, journal `[csp-report]`) — une
# violation en mode bloquant apparaît donc DEUX fois : rapport + blocage.
# Revenir en observation : repasser la ligne
# `config.content_security_policy_report_only = true`.
#
# Ce qui la rend nécessaire : une XSS future volerait le jeton intervenant
# présent dans le DOM de la salle, le jeton LiveKit et les actions de régie.
#
# Ce qui casse en mode bloquant, connu à l'écriture (inventaire mesuré
# dans Chrome headless sur le catalogue, la connexion, la
# page spectateur, la scène, la liste et la création de webinaires). L'anti-FOUC
# n'est plus une violation : `undust_anti_fouc_tag` (gem undust-charte) et le
# chrome par défaut posent le nonce (app/views/theme/_anti_fouc.html.erb).
# Reste :
#   • les attributs `style="…"` des partiels de la gem (marque, pied et haut
#     de page) et des layouts : couverts ici par `style-src-attr
#     'unsafe-inline'`, à retirer quand la gem passera aux classes ;
#   • la redirection du POST /auth/pocket_id vers l'émetteur OIDC : couverte
#     par `form-action`, qui porte l'émetteur effectif (OidcProvider, même
#     source qu'OmniAuth : `OIDC_ISSUER`, absent sans fournisseur) ;
#     Chrome applique la directive aux redirections ;
#   • une URL réseau en clair (`ws://`, quickstart local) : `connect-src`
#     garde son schéma (`ws:`/`http:`) via CspNetworkOrigins — la réécrire
#     en `wss:` casserait le signal ;
#   • tout ajout futur de script inline, d'`eval`, de CDN ou d'iframe externe.
# Ne casse pas : React et LiveKit posent leurs styles par le CSSOM
# (`element.style.x = …`), que `style-src` n'interdit pas ; ni le flux média
# (`srcObject`, hors CSP) ; ni les connexions ICE/TURN (hors CSP).
Rails.application.configure do
  livekit = ENV["LIVEKIT_URL"].presence
  app_host = ENV["APP_HOST"].presence

  # Un hôte réseau donne ses deux schémas : le signal LiveKit (/rtc) et son
  # repli HTTP (/rtc/validate) ; une valeur en clair (`ws://`) garde ses
  # schémas `ws:`/`http:` (CspNetworkOrigins).
  network_origins = CspNetworkOrigins.for(livekit, app_host)

  oidc_issuer = OidcProvider.issuer

  config.content_security_policy do |policy|
    policy.default_src     :self
    policy.base_uri        :self
    policy.object_src      :none
    policy.frame_ancestors :none
    policy.script_src      :self
    # Feuilles de style servies par l'application (Propshaft). Les attributs
    # `style` en ligne ont leur propre directive, plus bas.
    policy.style_src       :self
    policy.style_src_attr  :unsafe_inline
    policy.font_src        :self
    policy.img_src         :self, :data
    # Lecture média : flux WebRTC (`srcObject`, hors CSP) ; `blob:` couvre les
    # médias construits côté navigateur (enregistrement local, aperçu caméra).
    policy.media_src       :self, :blob
    policy.worker_src      :self, :blob
    # `:self` couvre l'API, les sondages, la discussion ; les hôtes réseau
    # couvrent le signal LiveKit pour les navigateurs qui ne rapprochent pas
    # `'self'` de `wss:` (Safari ancien).
    policy.connect_src     :self, *network_origins
    policy.form_action     *[ :self, oidc_issuer ].compact
    policy.report_uri      "/csp-reports"
  end

  # Un nonce différent par réponse (jamais l'id de session, stable pendant
  # toute la session) : les scripts en ligne légitimes le portent, ceux
  # injectés ne le connaissent pas.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
  config.content_security_policy_nonce_auto = true
end
