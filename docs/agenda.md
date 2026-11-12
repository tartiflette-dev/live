# Agenda, personal calendar feed and change notices

| Route | Audience | Response |
|---|---|---|
| GET /agenda | Anonymous | Upcoming published webinars grouped by month (Europe/Paris), past ones collapsed, and how to get the personal feed (section `#inscription`) |
| GET /agenda/:token.ics | The person who owns the token, calendar clients | `text/calendar; charset=utf-8`, inline: every published webinar, past included; `?kind=` restricts it to one `Webinar::KINDS` format (`X-WR-CALNAME` = « Café IA — Webinaires Acme »), unknown kind → 400 `text/plain`; unknown, empty or revoked token → 404 |
| GET /agenda.ics | Anyone (former public feed) | 410 Gone, `text/plain`: « Ce flux public est fermé. Inscrivez-vous à un webinaire (…/agenda) pour recevoir votre lien d'agenda personnel… », whatever `kind` |
| GET /w/:slug.ics | Anonymous | Same serialization, one event, attachment; 404 for draft visibility or unknown slug |
| GET /agenda/next.json | Anonymous, third-party sites (tartiflette.dev) | Next published dates and where to register for the personal feed, see below |

`/agenda/next.json`, `/w/:slug.ics` and the 410 of `/agenda.ics` answer `Access-Control-Allow-Origin: *`, without `Access-Control-Allow-Credentials`: the data is public. These open responses are always in French: they ignore `?locale=` and the locale cookie (`ApplicationController#switch_locale` is skipped for them), and they never read or write the session or any cookie, so no `Set-Cookie` is ever sent and a public cache can store them (asserted by the tests). The HTML page /agenda keeps the app's language rotation. They are simple GETs: no preflight, hence no `rack-cors`. The HTML pages are not opened to other origins. The public webinar page offers the single-event file and a prefilled Google Calendar link before the live starts.

## Personal feed

The feed of every date is reserved to people whose registration is confirmed. Code: `CalendarSubscription`, `CalendarFeedsController`, `CalendarSubscriptionMailer`.

- **One subscription per person** (normalized email), opaque token (`SecureRandom.urlsafe_base64(24)`), `revoked_at`, `fetch_count` and `last_fetched_at`. It is created at the FIRST confirmation that proves the mailbox: `Registration#confirm!` (form `/r/:token`, private link, hand over of a provisional identity) or `RegistrationRequest#confirm!` (API, « préviens-moi » alone included). Never before.
- **One mail per person** (`CalendarSubscriptionMailer#feed_link`, « Ajoute le Café IA à ton agenda » / « Votre lien d'agenda personnel »), sent after the confirming transaction commits: `webcal://`, Google (`calendar/r?cid=webcal://…`), Outlook for Microsoft 365 and Outlook.com (`…/calendar/0/addfromweb`), and the https address (any other calendar, or a one-off download). The links carry `?kind=<voice>` when the voice of the mail is a format (Café IA → Café IA only; a mixed API request → every format). A later confirmation sends nothing; after a revocation, the next confirmation issues a NEW token and a new mail. No marketing withdrawal link: this is not prospection.
- **The feed**: `WebinarCalendar#feed`, the serialization of the former public feed, pinned byte for byte by `AgendaFeedGoldenTest`. No session, no cookie, no CORS (only the person's calendar reads it), always French, `Cache-Control: max-age=0, private, must-revalidate` (no shared cache keeps a response addressed by a token), ETag/304. Every read that resolves the token, 304 included, increments `fetch_count` and sets `last_fetched_at` without touching `updated_at`: the active subscribers are measured without the proxy logs. The token never reaches the request log (`TokenPathMask`, prefix `/agenda`, `/agenda/next.json` excepted).
- **Revoke** (leaked link): `CalendarSubscription.find_by(email: "…").revoke!` in the console; the link answers 404 at once. **Erasure** (`crm:erase`) deletes the subscription (`calendar_subscriptions=` counter). **Retention**: `RetentionPurgeJob` deletes a subscription once its address has no registration and no registration request left, so at the term of the last one (12 months after the webinar, or after the request for « préviens-moi »).
- Measure: `CalendarSubscription.active.where("last_fetched_at > ?", 1.day.ago).count`.

People confirmed before this feed existed receive their link at their next confirmation; nothing is sent to them retroactively.

## Change notices to registrants

When a published webinar still to come is moved or unpublished, its confirmed registrations are told (`WebinarChangeNotice`, `WebinarChangeNoticeJob`, `WebinarChangeMailer`). A model callback (`Webinar` `after_update_commit` on `starts_at` or `visibility`) sees every path: edit screen and console alike. The first publication of a draft announces nothing, even to registrations confirmed through the private participants link.

- **Quiet period**: every change bumps `webinar_change_notices.revision` and schedules the job 10 minutes later (`QUIET_PERIOD`); only the job carrying the latest revision compares the webinar with the last announced state (`starts_at`, `published`). A date fixed back, or an unpublication undone, within the period sends nothing; three edits in a row send one mail, for the last state.
- **Urgency**: when the webinar concerned starts within 30 minutes (`URGENT_WINDOW`; the announced date for a cancellation, the earlier of the announced and new dates for a move), the job runs at once, without the quiet period. "Still to come" is judged at the moment of the change (`changed_at`), not when the job runs: a 18:00 café unpublished at 17:55 is announced even if the job runs at 18:01.
- **What is sent** to confirmed registrations never removed from the room, in the voice of the show:
  - « nouvelle date » (`rescheduled`): published and its date differs from the last announced, or published again after an announced cancellation. The event is attached (`<slug>.ics`, same UID as `/w/:slug.ics`, increasing SEQUENCE): a calendar that has it moves it. With the personal link: the access link `/r/:token`.
  - « annulé » (`cancelled`): unpublished; the mail gives the date that was announced. No attachment (`METHOD:CANCEL` would be iTIP); the personal feed drops the event at its next refresh.
  - Only for a webinar still to come at the moment of the change: not started (`draft`) and the relevant date (announced for a cancellation, new for a move) after `changed_at`. Otherwise the current state becomes the announced one, silently.
- **Once per recipient**: each recipient is first marked (`webinar_change_deliveries`, unique per notice, revision and registration), then the mails are enqueued after the transaction. A replayed job, or one resumed after a crash, mails only those not marked. A mail can be missed (crash between the mark and the enqueue), never doubled — the reminder's rule.
- Deleting the webinar or a registration deletes their marks (foreign keys `on_delete: cascade`).

## Serialization

`WebinarCalendar` is the only consumer of the `icalendar` gem (RFC 5545 folding, TEXT escaping, CRLF) and also builds the prefilled Google Calendar event, so both share one description. Serialization contract:

- instants in UTC (`Z`), no VTIMEZONE;
- `UID` = `<slug>@<APP_HOST>`; slugs are unique and immutable;
- `DTSTAMP` = `LAST-MODIFIED` = `updated_at`, so an unchanged feed is byte-identical and conditional GETs answer 304;
- `SEQUENCE` = seconds between `created_at` and `updated_at`: 0 at creation, increasing with every update;
- `DTEND` = start + `Webinar::PLANNED_DURATIONS` (café IA 1 h, bootcamp 3 h, an assumption: the model has no end time);
- `DESCRIPTION` = plain-text description, format and price, public page URL; `URL` and `LOCATION` = public page;
- no `METHOD`: neither the feed nor the file is an iTIP message (`METHOD:PUBLISH` would require a matching Content-Type `method` parameter and an `ORGANIZER`);
- feed only: `X-WR-CALNAME`, `REFRESH-INTERVAL` and `X-PUBLISHED-TTL` of one hour.

The unfiltered feed is pinned byte for byte by `test/controllers/agenda_feed_golden_test.rb` against `test/fixtures/files/agenda_feed.ics`, generated from the former public feed before the `kind` filter existed and served today by the personal feed. Changing the serialization means regenerating that file deliberately.

Unpublishing a webinar removes it from the feed: subscribed calendars mirror the feed and drop the event at their next refresh. `STATUS:CANCELLED` is not used in the feed, because it would expose draft titles; registrants learn of the cancellation by mail (above).

Each date on /agenda shows its programme under its title when one is announced (topic · speakers · lead host).

"Past" on /agenda is the exact complement of the homepage groups (live, starting late, upcoming): an ended live, or a draft never started beyond `Webinar::LATE_START_WINDOW`.

The double opt-in mail carries no `.ics`: it goes to an unverified address, and a calendar entry before confirmation would let a visitor believe they are registered. The personal feed link leaves after the confirmation (above); the day-before reminder, sent to confirmed registrations only, attaches `WebinarCalendar#event` ([registration-reminders.md](registration-reminders.md)).

## GET /agenda/next.json

Interface contract: `live.agenda.next.v2` (since 09/11/2026). Adding fields is compatible; removing or renaming one, or changing the selection rule, is a new version to announce to tartiflette.dev.

v2 versus v1: the `calendar` block no longer offers a public subscription feed — `ics_url`, `webcal_url` and `google_subscribe_url` are removed (the feed they pointed at answers 410) and `register_url` is added: the section of /agenda that explains how to get the personal feed (register to a webinar). The per-webinar `ics_url` (`/w/:slug.ics`, one event) stays public and unchanged.

Parameters, both optional:

- `kind`: one of `Webinar::KINDS` (`cafe_ia`, `bootcamp`). An empty value means no filter; any other value → 400 `{"error":"invalid_kind","message":"kind must be one of: cafe_ia, bootcamp","allowed_kinds":["cafe_ia","bootcamp"]}`.
- `limit`: default 3, clamped to 1..10; an unreadable value falls back to 3.

Selection (`AgendaController#next_dates` → `Webinar.next_dates`): published webinars only, the homepage groups in their order — live (`state: live`), starting late (`starting_late`), upcoming (`upcoming`) — each sorted by `starts_at` then `id`, truncated to `limit`. An ended webinar or one never started beyond `Webinar::LATE_START_WINDOW` (`past?`) never appears. So during a live: [live, next, next]; once it has ended: the next three.

`Cache-Control: max-age=60, public`. Instants are ISO 8601 UTC; URLs are absolute, on the request host. The `calendar` block does not depend on `kind`. `ends_at` is `Webinar#planned_ends_at` (assumed duration, see below). `google_calendar_url` is `WebinarCalendar#google_event_url`, the prefilled event of the public page.

```json
{
  "calendar": {
    "page_url": "https://live.example.org/agenda",
    "register_url": "https://live.example.org/agenda#inscription"
  },
  "webinars": [
    {
      "slug": "cafe-ia-novembre",
      "title": "Café IA de novembre",
      "kind": "cafe_ia",
      "status": "upcoming",
      "date_status": "to_confirm",
      "starts_at": "2026-11-05T17:00:00Z",
      "ends_at": "2026-11-05T18:00:00Z",
      "url": "https://live.example.org/w/cafe-ia-novembre",
      "ics_url": "https://live.example.org/w/cafe-ia-novembre.ics",
      "google_calendar_url": "https://calendar.google.com/calendar/render?action=TEMPLATE&…",
      "free": true,
      "price_label": "Gratuit",
      "topic": {
        "title": "Agents IA : ce qui marche vraiment",
        "summary": "Deux retours de terrain, puis vos questions."
      },
      "speakers": ["Anne Martin", "Karim Benali"],
      "lead_host": "Anne Martin"
    }
  ]
}
```

`status` is `live`, `starting_late` or `upcoming`. `date_status` (added, compatible) is `confirmed` when every host of the webinar will be there for its current date (the owner is presumed present, co-hosts answer), `to_confirm` otherwise; a live webinar is `confirmed` ([host-presence.md](host-presence.md)). The programme of the webinar (added 10/11/2026, compatible; `Webinar::Program`, entered on the owner's edit screen or by any host on `/webinars/:slug/program`): `topic` is `null` when no topic is announced, otherwise `{ "title", "summary" }` (`summary` may be `null`); `speakers` is the list of announced speakers' display names, in speaking order, at most 3, `[]` when none; `lead_host` is the display name of who leads this date (rotating role, not necessarily the owner), or `null`. All three are plain text: a consumer inserts them as text, never as HTML. `price_label` (and `google_calendar_url` text) are always French, whatever `?locale=` or cookie the caller sends.
