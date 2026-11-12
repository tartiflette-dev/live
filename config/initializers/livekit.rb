# frozen_string_literal: true

# LiveKit — configuration serveur.
#
# Le SDK `livekit-server-sdk` lit lui-même `ENV["LIVEKIT_API_KEY"]` et
# `ENV["LIVEKIT_API_SECRET"]` quand LivekitTokenService les délègue (cf.
# app/services/livekit_token_service.rb).  Cet initializer ne fait
# volontairement RIEN à part charger la lib : (a) éviter un couplage
# duplique entre initializer et service, (b) laisser le test injecter
# librement les clés via ENV factices sans réinitialiser une constante.
#
# Absence de clés = erreur au moment de l'émission d'un token, PAS au boot :
# l'app doit démarrer sans clés (dev, test, déploiement dont les secrets
# LiveKit ne sont pas encore posés).

require "livekit"
