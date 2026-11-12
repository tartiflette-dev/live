# Host presence ("date confirmée" / "à confirmer")

## Who is asked

The hosts of a webinar are its owner (`host_sub`) and its current co-hosts (`WebinarHost`, however they were added: by email, carry-over, host invitation link). A project host (group named by `LIVE_ANIMATEURS_GROUP`, admin) is not a host of a webinar on that ground alone.

The **owner is presumed present** for every date: never asked nor reminded by mail, recorded as `present` for the current date (`HostAttendance#presume_present!`, `answered_at` left NULL), and able to switch to "non" from the webinar page. When the date moves, the presumption is renewed for the new date. Only co-hosts receive requests and reminders. A webinar without co-hosts is therefore "date confirmée" right away.

One `HostAttendance` row per host × webinar: `webinar_host_id` is NULL for the owner (unique per webinar), otherwise unique per `WebinarHost`. Removing a co-host or deleting the webinar deletes the row (FK `ON DELETE CASCADE` and `dependent: :destroy`), so the links of their mail stop resolving.

## When

Requests are only sent while the webinar is published and has not started (`Webinar#host_attendance_open?`):

| Event | Effect |
|---|---|
| Created published, or draft → published | `HostAttendanceRequestJob` now |
| `starts_at` changed while published | `HostAttendanceRequestJob` after 10 minutes (`RESCHEDULE_REQUEST_DELAY`): several edits make one mail |
| Co-host added | `HostAttendanceRequestJob` now (only the new co-host has something to receive) |
| Every day at 10:00 Europe/Paris (`config/recurring.yml`, production) | `HostAttendanceReminderJob`: requests never made yet for a published upcoming webinar (published before this feature, request job never run), then reminder of co-hosts without an answer from J-3 (calendar day, Paris), never on the calendar day of the request (Paris) |

A request already claimed whose mail was lost is not sent again. The 10:00 run may send the request for a webinar later the same day: accepted, the co-host can answer from the mail or the webinar page.

An answer is valid for the date it was given for (`answered_for_starts_at`). When the date moves, every co-host answer becomes stale without being erased: the status goes back to "à confirmer" and every co-host is asked again. Requests and reminders are sent at most once per co-host and per date (`requested_for_starts_at`, `reminded_for_starts_at`), claimed by a single conditional UPDATE that compares against the date stored in `webinars`; a co-host who already answered for the current date is neither asked nor reminded.

## Answering

- From the mail: `GET /presence?t=<token>&reponse=oui|non` shows the webinar and the two buttons, without effect (link scanners); the answer is taken by the `POST /presence` of a button, which renders the page (no redirect: the token would be logged). Token in query `t` (filtered from logs), `Cache-Control: no-store`, `Referrer-Policy: strict-origin`. No identity or access cookie: with CSRF protection on, the Rails session cookie only carries the CSRF token of the buttons, no sign-in is opened. Unknown token (removed co-host included) → 404; webinar unpublished, started or past → 410.
- Signed in, from the webinar page: `POST /webinars/:slug/presence` (`answer=present|absent`), for the owner and for a co-host whose verified address matches (same conditions as `Webinar#role_for`). Managers (owner, project hosts) see everyone's answer; a co-host sees the status and their own answer only.

A new "non" from a co-host for the current date sends `HostAttendanceMailer#absence_notice` to the owner right away. Novelty is decided by the conditional UPDATE in the database: two simultaneous "non" make one notice. Nothing changes on the public side: the owner decides (keep, move, unpublish). The owner's own "non" notifies nobody.

## Status

`Webinar#date_status` is `confirmed` when the owner (presumed) and every current co-host are present for the current date, `to_confirm` otherwise; a live or ended webinar is `confirmed`. It is shown before the live (state draft, not past) on the catalogue, `/agenda`, the public webinar page, the host webinar page and the régie, and as the `date_status` field of every entry of `/agenda/next.json` ([agenda.md](agenda.md)). Those lists preload `host_attendances` and `webinar_hosts` (no N+1).
