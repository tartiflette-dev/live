#!/bin/sh
# Generates the quickstart's development secrets on first launch, in the
# shared `secrets` volume (compose.yaml): LiveKit API key and secret, Redis
# password, Rails secret_key_base, and the LiveKit and egress configurations
# that embed them. Fresh random values for every installation, never committed
# and never reused elsewhere. Later launches keep them; `docker compose down -v`
# deletes them.
#
# Each file is readable by the one service that needs it, and only by it
# (mode 0600): run as root (compose.yaml) so it can set the owners below.
set -eu

# Users of the reading containers: app (examples/quickstart/Dockerfile) and
# egress (livekit/egress image). Redis and LiveKit read as root.
APP_UID=1000
EGRESS_UID=1001

dir="${1:-/secrets}"

if [ -f "$dir/app.env" ]; then
  echo "init-secrets: reusing the secrets generated on first launch"
  exit 0
fi

random_hex() {
  head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
}

api_key="API$(random_hex 8)"
api_secret="$(random_hex 32)"
redis_password="$(random_hex 24)"
secret_key_base="$(random_hex 64)"

umask 077
tmp="$(mktemp -d "$dir/.init.XXXXXX")"

printf '%s' "$redis_password" > "$tmp/redis_password"

cat > "$tmp/livekit.yaml" <<EOF
port: 7880
rtc:
  tcp_port: 7881
  udp_port: 7882
  # Media candidates: the container address, for the egress on the compose
  # network, and loopback, for browsers on this machine through the ports
  # published on localhost.
  use_external_ip: false
  enable_loopback_candidate: true
redis:
  address: redis:6379
  password: $redis_password
keys:
  $api_key: $api_secret
webhook:
  api_key: $api_key
  urls:
    # app.test: network alias of the app container, a host name the Rails
    # development environment accepts.
    - http://app.test:3000/webhooks/livekit
logging:
  level: info
EOF

cat > "$tmp/egress.yaml" <<EOF
api_key: $api_key
api_secret: $api_secret
ws_url: ws://livekit:7880
insecure: true
redis:
  address: redis:6379
  password: $redis_password
health_port: 8080
log_level: info
local_directory: /data
EOF

cat > "$tmp/app.env" <<EOF
LIVEKIT_API_KEY=$api_key
LIVEKIT_API_SECRET=$api_secret
SECRET_KEY_BASE=$secret_key_base
EOF

chown "$APP_UID" "$tmp/app.env"
chown "$EGRESS_UID" "$tmp/egress.yaml"
chmod 0600 "$tmp"/*

# app.env last: its presence marks a complete generation.
mv "$tmp/redis_password" "$tmp/livekit.yaml" "$tmp/egress.yaml" "$dir/"
mv "$tmp/app.env" "$dir/app.env"
rmdir "$tmp"
echo "init-secrets: generated new development secrets"
