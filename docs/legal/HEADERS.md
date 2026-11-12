# Licensing information per file

The copyright and licence of every file of the tree are declared by `REUSE.toml`
(REUSE specification 3.3; since 3.2, `REUSE.toml` replaces `.reuse/dep5` and lets a
repository annotate its files without a header in each of them):

- the default annotation, `path = "**"`, covers all files of the Program:
  `AGPL-3.0-only WITH LicenseRef-Live-AGPL-3.0-Terms`, copyright
  `2026 Luc Létoffé and the Live contributors`;
- the annotations below it cover third-party files (fonts, the file adapted from LiveKit)
  with `precedence = "override"`.

`reuse lint` checks that every file is covered and that every licence it names is in
`LICENSES/`.

## The expression

- The additional terms (`ADDITIONAL_TERMS.md`, AGPL-3.0 section 7) are a **`LicenseRef-`**,
  written after `WITH`. That is the form the REUSE tool accepts (tested with `reuse` 6.3.0,
  spec 3.3) and the form other AGPL projects with section 7 terms use (for example
  `AGPL-3.0-only WITH LicenseRef-Pretalx-AGPL-3.0-Terms`). `AdditionRef-` is not used.
- The text of `LicenseRef-Live-AGPL-3.0-Terms` is `LICENSES/LicenseRef-Live-AGPL-3.0-Terms.txt`,
  a copy of `ADDITIONAL_TERMS.md`: keep the two identical. The suffix follows the repository
  name: rename it in one pass if the repository name changes.
- `NOTICE`, `README.md`, `README.fr.md` and `CONTRIBUTING.md` point to `ADDITIONAL_TERMS.md`.

## A header in a file (optional)

A file does not need a header. One may be added, for example to a new file or to a file
that is often copied out of the repository; with `precedence = "closest"`, it takes
precedence over the default of `REUSE.toml`. Use three lines: copyright, SPDX expression,
pointer to the terms.

```
SPDX-FileCopyrightText: 2026 Luc Létoffé and the Live contributors
SPDX-License-Identifier: AGPL-3.0-only WITH LicenseRef-Live-AGPL-3.0-Terms
Additional terms under AGPL-3.0 section 7 apply: see ADDITIONAL_TERMS.md
```

- Year: the repository started on 12 August 2026, so `2026`. Do not add years afterwards
  unless the file changes substantially in a later year.
- With the tool: copy `docs/legal/reuse-template-live.jinja2` to `.reuse/templates/live.jinja2`,
  then `reuse annotate --template live --copyright "Luc Létoffé and the Live contributors"
  --year 2026 --license "AGPL-3.0-only WITH LicenseRef-Live-AGPL-3.0-Terms" <file>`.
  Comment styles produced: `#` (Ruby, shell, YAML, Python), `//` (JS, JSX, MJS), `/* */`
  (CSS), `<!-- -->` (HTML). Shebang lines stay first.
- `.erb` files are not recognised by the tool. Use this block as the first lines (a
  server-side comment, not sent to the browser; `reuse lint` reads it; tested with Erubi
  `trim: true`):

```
<%#
  SPDX-FileCopyrightText: 2026 Luc Létoffé and the Live contributors
  SPDX-License-Identifier: AGPL-3.0-only WITH LicenseRef-Live-AGPL-3.0-Terms
  Additional terms under AGPL-3.0 section 7 apply: see ADDITIONAL_TERMS.md
%>
```

## Special files

| File | Declared by | Note |
|---|---|---|
| `app/javascript/rooms/room_tiles.jsx` | `REUSE.toml` (override); its first lines below | adapted from LiveKit `ParticipantTile` 2.9 (Apache-2.0): the first lines are the notice of change that Apache-2.0 section 4(b) asks for |
| Fonts | `REUSE.toml` (override), OFL-1.1 | see THIRD_PARTY_NOTICES.md |

### Header of `room_tiles.jsx`

Copyright lines come from `REUSE.toml`; the header is the notice of change:

```
// This file adapts the ParticipantTile component of @livekit/components-react 2.9
// (Copyright 2023 LiveKit, Inc., Apache License 2.0, https://www.apache.org/licenses/LICENSE-2.0).
// Changes: the screen-share label is localised, and spotlight and consent markers are
// rendered by a portal into the root node of a camera tile. The Apache-2.0 terms apply to
// the parts that derive from the original. Licence of the file (REUSE.toml):
// AGPL-3.0-only WITH LicenseRef-Live-AGPL-3.0-Terms AND Apache-2.0; additional terms
// under AGPL-3.0 section 7 apply: see ADDITIONAL_TERMS.md.
```
