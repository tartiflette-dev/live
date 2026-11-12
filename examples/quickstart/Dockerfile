# syntax=docker/dockerfile:1

# Quickstart image, built by compose.yaml (docs/quickstart.md): the app in the
# development environment, with the tartiflette theme and without the private
# undust theme gem. Development sign-in, no identity provider: never expose it.
# The production image is the root Dockerfile.

ARG RUBY_VERSION=3.4.9
FROM docker.io/library/ruby:${RUBY_VERSION}-slim

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential curl ffmpeg git libsqlite3-dev libyaml-dev nodejs npm pkg-config sqlite3 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

WORKDIR /rails

ENV RAILS_ENV="development" \
    BRAND_THEME="tartiflette" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="test"

COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4 && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache

COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY . .

# JavaScript bundle (esbuild) and stylesheet (theme:sync + Tailwind), built
# once: the image runs the code it was built from, without watchers.
RUN npm run build && \
    bin/rails tailwindcss:build && \
    rm -rf node_modules tmp/cache

# Unprivileged user. /rails/storage (SQLite), /secrets and /recordings are
# named volumes in compose.yaml: created here, they inherit this ownership and
# mode on first use. /recordings is shared with the egress (its own user).
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p storage tmp log /secrets /recordings && \
    chown -R rails:rails storage tmp log /secrets /recordings && \
    chmod 1777 /recordings
USER 1000:1000

EXPOSE 3000
CMD ["examples/quickstart/start-app.sh"]
