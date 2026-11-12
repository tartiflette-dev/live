# Third-party notices

> Versions are those of `Gemfile.lock`, `package-lock.json` and `public/fonts` surveyed on 5 November 2026; the lockfiles and fonts of the published tree were checked unchanged since, on 12 November 2026. This file is a human summary of the lockfiles, not a generated inventory: when a dependency changes, its line changes with it.

The Program's own licence is in `LICENSE`, `ADDITIONAL_TERMS.md` and `NOTICE`. Components below keep their own licences. All of them are compatible with the AGPL-3.0 as used here. **Policy:** no third-party dependency under the AGPL or the SSPL, and none under a licence that the AGPL-3.0 cannot carry.

## 1. Code adapted from a third-party work

### `app/javascript/rooms/room_tiles.jsx`: adapted from `ParticipantTile` (LiveKit components-js 2.9)

- Original: `ParticipantTile` of `@livekit/components-react` 2.9, Copyright 2023 LiveKit, Inc., licensed under the **Apache License 2.0** (`docs/legal/licenses/Apache-2.0.txt`; upstream `NOTICE`: "Copyright 2023 LiveKit, Inc.").
- The file reuses the structure and the content of that component, with changes: the screen-share label is localised ("Écran de <nom>" instead of a hard-coded English label), and, for a camera tile, spotlight and consent markers are rendered by a portal into the tile's root node.
- Apache-2.0 section 4 obligations: (a) the licence text is provided; (b) the file carries a prominent notice that it was changed (its header, `docs/legal/HEADERS.md`); (c) copyright and attribution notices of the original are kept (above); (d) the upstream NOTICE text is reproduced above.
- The adapted code is distributed under the Apache-2.0 for the part that derives from the original, and under the Program's licence for the rest of the file (`AGPL-3.0-only WITH LicenseRef-Live-AGPL-3.0-Terms AND Apache-2.0`). Apache-2.0 is compatible with the AGPL-3.0.

## 2. Fonts (SIL Open Font License 1.1)

Each font travels with its OFL 1.1 text (copyright line, Reserved Font Name if any, licence body); the body alone is also in `docs/legal/licenses/OFL-1.1.txt`. OFL conditions respected: the copyright notice and the licence travel with the fonts; the fonts are not sold by themselves; no Modified Version is published under a Reserved Font Name.

| Font | Files | Copyright (font metadata / upstream) | Reserved Font Name | Notes |
|---|---|---|---|---|
| Aspekta 2.100 | `public/fonts/Aspekta-{400,500,700,800,900}.woff2` | Copyright (c) 2025 Ivo Dolenc | **"Aspekta"** (upstream `LICENSE.txt`) | Licence text shipped as `OFL-Aspekta.txt` beside the files. Files measured byte-identical (SHA-256) to upstream `packages/fonts/webfonts` on 5 Nov 2026: unmodified, so the name may be kept. Do not publish a modified version under the name "Aspekta". |
| JetBrains Mono 2.304 | `public/fonts/JetBrainsMono-{400,700}.woff2` | Copyright 2020 The JetBrains Mono Project Authors (https://github.com/JetBrains/JetBrainsMono) | none declared (upstream `OFL.txt` and font metadata); "JetBrains Mono" is a trademark of JetBrains s.r.o. (font metadata): not licensed here | Licence text shipped as `OFL-JetBrainsMono.txt` beside the files. Same font as upstream release 2.304 (`fonts/webfonts/JetBrainsMono-Regular.woff2` and `-Bold.woff2` of `JetBrainsMono-2.304.zip`, SHA-256 `a9cb1cd8…` and `c503cc5e…`): not byte-identical, but once decompressed every table is identical to upstream except `head`, whose checksum differs (same version 2.304, same 1,743 glyphs, same character map, checked on 12 Nov 2026). The files were re-encoded as WOFF2, not modified; the build that re-encoded them is not recorded. OFL requires the licence and copyright to remain. Used as the `Ponctuation FR` family through `unicode-range` (a CSS selection of glyphs, not a font modification). |
| Bricolage Grotesque | `themes/tartiflette/assets/fonts/bricolage-grotesque-*.woff2` | Copyright 2022 The Bricolage Grotesque Project Authors (https://github.com/ateliertriay/bricolage) | none declared in the shipped licence text | Licence text shipped as `OFL-bricolage-grotesque.txt` beside the files. |
| DM Sans | `themes/tartiflette/assets/fonts/dm-sans-*.woff2` | Copyright 2014 The DM Sans Project Authors (https://github.com/googlefonts/dm-fonts) | none declared in the shipped licence text | Licence text shipped as `OFL-dm-sans.txt` beside the files. |

`public/fonts/OFL-Aspekta.txt` is the upstream `LICENSE.txt` of https://github.com/ivodolenc/aspekta and `public/fonts/OFL-JetBrainsMono.txt` the upstream `OFL.txt` of https://github.com/JetBrains/JetBrainsMono, both copied verbatim on 5 Nov 2026.

## 3. Assets from tartiflette.dev

The logo, favicon and style sheets of tartiflette.dev, the theme's previews and its screenshots are not part of this tree. The Tartiflette theme runs on Live's neutral tokens, favicon and logo (`docs/theme-pack.md`).

## 4. Ruby gems

Runtime closure of `Gemfile.lock` (115 gems), by licence. Where a gem offers a choice, the first option is the one relied upon. Private gem `undust-charte` (and its dependency `view_component`) is added by the undust distribution in its own Gemfile, outside the public tree: the published `Gemfile` and `Gemfile.lock` do not reference it.

| Licence | Count | Gems |
|---|---|---|
| MIT | 77 | action_text-trix 2.1.19, actioncable 8.1.4.1, actionmailbox 8.1.4.1, actionmailer 8.1.4.1, actionpack 8.1.4.1, actiontext 8.1.4.1, actionview 8.1.4.1, activejob 8.1.4.1, activemodel 8.1.4.1, activerecord 8.1.4.1, activestorage 8.1.4.1, activesupport 8.1.4.1, aes_key_wrap 1.1.0, attr_required 1.0.2, bootsnap 1.25.0, builder 3.3.0, concurrent-ruby 1.3.8, connection_pool 3.0.2, crass 1.0.8, erubi 1.13.1, et-orbi 1.4.1, faraday 2.14.3, faraday-follow_redirects 0.5.0, faraday-net_http 3.4.4, fugit 1.13.0, globalid 1.4.0, hashie 5.1.0, i18n 1.15.2, ice_cube 0.17.0, image_processing 1.14.0, jbuilder 2.15.1, jsbundling-rails 1.3.1, json-jwt 1.17.2, jwt 2.10.3, loofah 2.25.3, mail 2.9.1, mini_magick 5.3.3, mini_mime 1.1.5, minitest 6.0.6, nokogiri 1.19.7, omniauth 2.1.4, omniauth-rails_csrf_protection 1.0.2, omniauth_openid_connect 0.8.0, openid_connect 2.5.0, prism 1.9.0, propshaft 1.3.2, public_suffix 7.0.5, raabro 1.5.0, rack 3.2.8, rack-oauth2 2.3.0, rack-protection 4.2.1, rack-session 2.1.2, rack-test 2.2.0, rackup 2.3.1, rails 8.1.4.1, rails-dom-testing 2.3.0, rails-html-sanitizer 1.7.2, rails-i18n 8.1.0, railties 8.1.4.1, rake 13.4.2, ruby-vips 2.3.0, solid_cable 4.0.2, solid_cache 1.0.10, solid_queue 1.6.0, stimulus-rails 1.3.4, swd 2.0.3, tailwindcss-rails 4.6.0, tailwindcss-ruby 4.3.3, thor 1.5.0, thruster 0.1.25, turbo-rails 2.0.23, twirp 1.13.1, tzinfo 2.0.6, useragent 0.16.11, validate_url 1.0.15, webfinger 2.1.3, zeitwerk 2.8.3 |
| Apache-2.0 | 4 | livekit-server-sdk 1.0.0, msgpack 1.8.4, websocket-driver 0.8.2, websocket-extensions 0.1.5 |
| BSD-3-Clause | 4 | ffi 1.17.4, google-protobuf 4.35.1, puma 8.0.2, sqlite3 2.10.2 |
| BSD-2-Clause | 1 | bindata 3.0.0 |
| BSD-2-Clause (chosen) | 1 | icalendar 2.13.0 |
| BSD-2-Clause (or Ruby) | 22 | base64 0.3.0, bigdecimal 4.1.3, csv 3.3.6, date 3.5.1, drb 2.2.3, erb 6.0.7, io-console 0.9.4, irb 1.18.0, logger 1.7.0, net-http 0.9.1, net-imap 0.6.7, net-pop 0.1.2, net-protocol 0.4.0, net-smtp 0.5.2, pp 0.6.4, prettyprint 0.2.0, racc 1.8.1, rbs 4.2.0, securerandom 0.4.1, timeout 0.6.1, tsort 0.2.0, uri 1.1.1 |
| MIT (or Apache-2.0) | 1 | marcel 1.2.1 |
| MIT (or BSD-2-Clause) | 1 | nio4r 2.7.5 |
| Ruby | 2 | json 2.21.2, reline 0.7.0 |
| Ruby (or GPL-2.0-only) | 1 | rdoc 8.1.0 |

Notes:

- **icalendar 2.13.0** is offered under BSD-2-Clause, GPL-3.0-only and its own terms (same terms as Ruby); this project uses it **under BSD-2-Clause**.
- **sqlite3** gem (BSD-3-Clause) bundles SQLite, which is in the public domain.
- **nokogiri** (MIT) bundles libxml2 and libxslt (MIT) in its precompiled build.
- **swd 2.0.3** and **validate_url 1.0.15** declare no licence in their gemspec; their repositories carry an MIT licence file (checked 5 Nov 2026).
- **json**, **reline** (Ruby licence) and **rdoc** (Ruby licence or GPL-2.0-only) are Ruby standard-library gems.
- **Development and test only, not distributed** (28 gems closure): `brakeman` 8.1.0 (Brakeman Public Use License, not an OSI licence; replace it if the public CI is to be reused commercially), `bundler-audit` 0.9.3 (GPL-3.0-or-later), `rubocop-rails-omakase` and its closure, `debug`, `web-console`, `capybara`, `selenium-webdriver` (Apache-2.0). Tools that are run but not conveyed do not affect the licence of the Program.

## 5. JavaScript (npm)

Bundled into the browser JavaScript served to users by `esbuild`; their licence notices must stay reachable (licence comments kept in the bundle, or a licences page in the instance).

| Licence | Packages |
|---|---|
| (Apache-2.0 AND BSD-3-Clause) | @bufbuild/protobuf 1.10.1 |
| 0BSD | tslib 2.8.1 |
| Apache-2.0 | @livekit/components-core 0.12.15, @livekit/components-react 2.9.24, @livekit/components-styles 1.2.0, @livekit/mutex 1.1.1, @livekit/protocol 1.50.4, livekit-client 2.21.0, rxjs 7.8.2 |
| BSD-3-Clause | webrtc-adapter 9.0.6 |
| MIT | @floating-ui/core 1.8.0, @floating-ui/dom 1.7.6, @floating-ui/utils 0.2.12, @types/dom-mediacapture-record 1.0.22, clsx 2.1.1, events 3.3.0, jose 6.2.8, lodash.debounce 4.0.8, loglevel 1.9.1, loglevel 1.9.2, react 19.2.8, react-dom 19.2.8, scheduler 0.27.0, sdp 3.2.2, sdp-transform 2.15.0, typed-emitter 2.1.0, usehooks-ts 3.1.1 |

Build tools (not served): esbuild 0.28.2 and its platform binaries (`@esbuild/*`), MIT.

## 6. Transcriber service (`transcriber/`, Python)

| Package | Licence |
|---|---|
| livekit-agents 0.12.21, livekit-plugins-silero 0.7.5 | Apache-2.0 |
| PyJWT ~=2.15.1 | MIT |
| httpx 0.28.1 | BSD-3-Clause |

The Silero VAD model shipped with `livekit-plugins-silero` is distributed by its authors under the MIT licence (licence of the upstream repository, https://github.com/snakers4/silero-vad; the copy inside the plugin was not compared with it). Test dependencies (`pytest`, `pytest-asyncio`) are not part of the image.

## 7. System packages and base images

- The container images install **ffmpeg** (Debian build: licensed under the LGPL or GPL depending on the enabled libraries; the Debian build with libx264 is effectively GPL). Conveying an image means providing the corresponding sources and notices: the project **publishes the Dockerfiles, not the built images**, until this is settled.
- Base images: Debian (various licences), Ruby (BSD-2-Clause or Ruby licence), Python (PSF-2.0).
- `infra/` (LiveKit server and egress, coturn) is not part of the public tree.
