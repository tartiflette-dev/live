# Self-hosting the media stack (LiveKit, TURN, egress)

A production starting point for the real-time side of the app: LiveKit
(signalling and SFU, with its embedded TURN server), Redis, the LiveKit egress
for recordings, and Caddy for TLS. It assumes one Linux host with a public IPv4
address. For a local trial, use the quickstart instead
([docs/quickstart.md](../../docs/quickstart.md)).

The app itself (Rails) is deployed separately, for example with the root
`Dockerfile` behind your reverse proxy; it talks to this stack through the
settings listed at the end.

## Files

| File | Role |
|---|---|
| `compose.yaml` | The four services, host networking, LiveKit and egress configuration inline |
| `.env.example` | Every installation-specific value: copy to `.env` |
| `Caddyfile` | TLS for the signalling endpoint and the TURN certificate |

## Before the first start

1. **DNS.** Point `LIVEKIT_DOMAIN` and `TURN_DOMAIN` (two names) at the host.
   Caddy needs them to obtain certificates.
2. **Keys.** Generate the LiveKit API key pair and a Redis password:

   ```sh
   docker run --rm livekit/livekit-server:v1.13.5 generate-keys
   openssl rand -hex 32
   ```

3. **`.env`.** `cp .env.example .env`, then fill it in. Keep it out of version
   control (it holds the secrets).
4. **Recordings directory.** The egress writes as uid 1001; the app must read
   the same directory:

   ```sh
   sudo install -d -o 1001 -g 1000 -m 2775 /srv/live/recordings
   ```

5. **Firewall.** Open these ports to the Internet, and nothing else of this
   stack:

   | Port | Protocol | Use |
   |---|---|---|
   | 80, 443 | TCP | Caddy: certificates and `wss://LIVEKIT_DOMAIN` signalling |
   | 7881 | TCP | WebRTC over TCP (clients without UDP) |
   | 50000-60000 | UDP | WebRTC media |
   | 3478 | UDP | TURN over UDP |
   | 5349 | TCP | TURN over TLS (restrictive networks) |
   | 30000-40000 | UDP | TURN relay ports |

   Redis (6379) and the LiveKit HTTP port (7880) listen on loopback only.

## Start

```sh
docker compose up -d
docker compose logs -f livekit
```

LiveKit restarts until Caddy has obtained the TURN certificate (a minute on
the first start). Check the signalling endpoint:

```sh
curl -i https://livekit.example.com/rtc/validate   # 401: LiveKit answers
```

and the WebRTC path with <https://livekit.io/connection-test>, using a token
generated from your key pair.

## App settings

Give the app the same key pair and these endpoints:

| Variable | Value |
|---|---|
| `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` | the pair from `.env` |
| `LIVEKIT_URL` | `wss://livekit.example.com` (browsers) |
| `LIVEKIT_HOST` | `https://livekit.example.com` (server API calls) |
| `EGRESS_ENABLED` | `true` to record composites |
| `TRACK_EGRESS_ENABLED` | `true` to record one file per speaker |
| `RECORDINGS_ROOT` | the recordings directory, mounted in the app container |

LiveKit posts its webhooks to `APP_URL/webhooks/livekit`, signed with the key
pair: the app must be reachable from this host at that URL.

Sign-in uses any OpenID Connect provider: see "Production sign-in" in
[docs/quickstart.md](../../docs/quickstart.md).

## Operations

- **Certificate renewal.** Caddy renews the TURN certificate, but LiveKit reads
  it at startup: restart LiveKit monthly (`docker compose restart livekit`, for
  example from a systemd timer), outside live sessions.
- **Images.** Each image is pinned by digest, the same ones as the root
  `compose.yaml` for the images they share: a moved tag never changes what
  runs. Upgrade tag and digest
  together (`docker buildx imagetools inspect <image>:<tag>`), and LiveKit with
  the egress.
- **Proxy logs.** Invitation and speaker links carry their token in the query
  string: see "Security notes" in [docs/quickstart.md](../../docs/quickstart.md).
- **Capacity.** A room composite recording runs a Chrome instance in the
  egress: count about two CPU cores per concurrent recording.
