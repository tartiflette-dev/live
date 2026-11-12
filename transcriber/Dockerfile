# Image de l'agent transcriber (LiveKit + Whisper + archive).
#
# Base Debian slim : les wheels de silero-onnx exigent manylinux récent ;
# python:3.12-slim-bookworm les installe sans compilation. Le modèle silero
# est livré dans la wheel livekit-plugins-silero (resources/silero_vad.onnx) :
# rien n'est téléchargé, ni au build ni en salle.

# Épinglée par digest (index multi-architecture du tag 3.12-slim-bookworm) :
# un tag déplacé ne change pas l'image construite. Mettre à jour le digest
# avec le tag (docker buildx imagetools inspect python:3.12-slim-bookworm).
FROM python:3.12-slim-bookworm@sha256:935c3c5b12357a7e10caa9c1e6ca5692344d97cf229832ef584be2cec9fc03df

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

# ffmpeg : livekit-rtc n'en a plus besoin pour le décodage, mais silero
# et openai l'utilisent pour le resampling en interne via torchaudio.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates ffmpeg \
 && rm -rf /var/lib/apt/lists/*

# Correctif eMudhra — recharger ca-certificates
# dans le stage runtime : installe ou upgrade au besoin. 8 intermédiaires eMudhra
# compromis, racines emSign ECC G3 + AAA à retirer (deb13u1 / deb12u2 / ubuntu0.x).
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Correctif eMudhra — Python/requests utilise certifi,
# pas /etc/ssl/certs. On force la version post-eMudhra pour certifi (store httpx)
# ET pour pip (son _vendor/certifi/cacert.pem est figé par l'image Python slim).
RUN pip install --no-cache-dir --upgrade 'pip>=26.2.2' 'certifi>=2026.10.19'

# Correctif eMudhra — scan fail-closed au build. Aucun
# cacert.pem de l'image (certifi, pip vendored) ne doit porter emSign ECC G3
# ou AAA. Empreintes dans scan_emudhra_pem.py.
# Overlay fail-safe : si un cacert.pem subsiste dans un module système
# non géré par pip (dist-packages apt, _vendor non régénéré), on l'écrase
# par le bundle apt déjà corrigé (/etc/ssl/certs/ca-certificates.crt).
RUN cert=/etc/ssl/certs/ca-certificates.crt; \
    find / -name cacert.pem -type f 2>/dev/null | while IFS= read -r p; do \
      cp "$cert" "$p"; echo "overlay $p"; \
    done
COPY scan_emudhra_pem.py /usr/local/bin/scan_emudhra_pem.py
RUN find / -name cacert.pem -type f 2>/dev/null > /tmp/_pems.txt && \
    xargs -r python3 /usr/local/bin/scan_emudhra_pem.py < /tmp/_pems.txt && \
    rm -f /tmp/_pems.txt

COPY agent.py lifecycle.py noise.py whisper_client.py transcript_noise.json ./

# Contrôle de build : le modèle silero de la wheel se charge (aucun
# téléchargement, il est dans le paquet). Un échec n'arrête pas le build.
RUN python -c "from livekit.plugins import silero; silero.VAD.load(min_silence_duration=0.3)" || true

# Révision git : lisible par `docker inspect` via le
# label OCI. Les scripts de déploiement passent --build-arg. Sans
# argument le label vaut "unknown" — les scripts de deploy refusent ce cas.
ARG GIT_REVISION=unknown
LABEL org.opencontainers.image.revision=$GIT_REVISION

# Utilisateur dédié, sans droit d'écriture sur /app : l'agent n'écrit aucun
# fichier (modèle silero lu dans le paquet installé, archive envoyée par
# webhook). En déploiement, retirer aussi toutes les capacités
# (cap_drop: [ALL], no-new-privileges) et isoler le conteneur sur un réseau
# dédié, jamais network_mode: host.
RUN groupadd --system --gid 1000 transcriber && \
    useradd transcriber --uid 1000 --gid 1000 --create-home --shell /usr/sbin/nologin
USER 1000:1000

ENTRYPOINT ["python", "-u", "agent.py"]
CMD ["start"]
