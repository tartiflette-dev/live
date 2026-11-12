# syntax=docker/dockerfile:1
# check=error=true

# Production — Kamal, SQLite locale, jsbundling-rails (esbuild + React/LiveKit).
# node_modules purgés après npm run build (pas dans l'image finale).
#
# docker build -t live .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<config/master.key> --name live live

ARG RUBY_VERSION=3.4.9
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

# Packages runtime (SQLite seul — pas de PostgreSQL, pas de libvips).
# ffmpeg : requis par MuxParticipantJob (montage image + son d'un participant).
# Debian trixie-slim fournit ffmpeg 7.x avec libx264/libaac/libopus intégrés.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 sqlite3 ffmpeg && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Thème (themes/<pack>/, docs/theme-contract.md) : figé au build ET au runtime par la même
# valeur, la compilation des assets (theme:sync) et le boot lisent BRAND_THEME.
# `--build-arg BRAND_THEME=<pack>` pour une autre distribution ; vide = défaut de lib/theme.rb.
ARG BRAND_THEME=
# Gemfile d'une distribution qui ajoute ses gems (config/boot.rb) :
# `--build-arg BUNDLE_GEMFILE=Gemfile.distribution`. Défaut : Gemfile, sources publiques.
ARG BUNDLE_GEMFILE=Gemfile

ENV RAILS_ENV="production" \
    BRAND_THEME="${BRAND_THEME}" \
    BUNDLE_GEMFILE="/rails/${BUNDLE_GEMFILE}" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# ── Build stage ─────────────────────────────────────────────────────────────
FROM base AS build

# Packages build (libsqlite3-dev, nodejs+npm pour esbuild).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential git libsqlite3-dev libyaml-dev pkg-config \
      nodejs npm && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Gems Ruby (couche cachée indépendamment de l'application). Gemfile* : le
# Gemfile d'une distribution et son verrou, s'il y en a un.
COPY Gemfile* ./

# Gems tirées d'une forge git privée (Gemfile d'une distribution seulement) :
#   --build-arg GIT_SSH_PREFIX=ssh://git@forge.example:222/
#   --build-arg GIT_HTTPS_PREFIX=https://forge.example/
#   --secret id=FORGEJO_TOKEN (« utilisateur:jeton »)
# Les adresses SSH du Gemfile passent en HTTPS, le jeton est lu le temps du
# `bundle install` et ne reste pas dans l'image. Sans préfixe, rien n'est configuré ;
# un préfixe sans le secret est refusé.
ARG GIT_SSH_PREFIX=
ARG GIT_HTTPS_PREFIX=
RUN --mount=type=secret,id=FORGEJO_TOKEN \
    if [ -n "${GIT_SSH_PREFIX}" ] && [ ! -s /run/secrets/FORGEJO_TOKEN ]; then \
      echo "GIT_SSH_PREFIX posé : secret de build FORGEJO_TOKEN requis (--secret id=FORGEJO_TOKEN)" >&2; exit 1; \
    fi && \
    if [ -n "${GIT_SSH_PREFIX}" ]; then \
      git config --global url."${GIT_HTTPS_PREFIX}".insteadOf "${GIT_SSH_PREFIX}" && \
      git config --global credential.helper '!f() { sed "s/:/\npassword=/" /run/secrets/FORGEJO_TOKEN | sed "1s/^/username=/"; }; f'; \
    fi && \
    bundle install && \
    rm -f ~/.gitconfig && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile -j 1 --gemfile

# Application complète (nécessaire pour le glob esbuild app/javascript/*.*)
COPY . .

# JS — install + build + PURGE node_modules.
# node_modules pèsent ~200 MB ; inutiles au runtime (esbuild produit un bundle).
COPY package.json package-lock.json ./
RUN npm ci && \
    npm run build && \
    rm -rf node_modules

RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Assets Rails (propshaft — JS déjà compilé dans app/assets/builds/)
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# ── Image finale ────────────────────────────────────────────────────────────
FROM base

# ca-certificates rechargé dans le stage runtime (installé ou mis à jour) : l'image
# de base peut porter des autorités retirées depuis (intermédiaires eMudhra
# compromis, racines emSign ECC G3 + AAA : deb13u1 / deb12u2 / ubuntu0.x).
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
