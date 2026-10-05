# Track Watch — specification

A Toggl Track client for a Wear OS watch (Pixel Watch 4, Wi‑Fi only), with a
companion Android phone app. The watch is a remote control: **all Toggl API
calls are made by the phone.**

## Decisions

| Topic | Decision |
|---|---|
| Platforms | Android phone + Wear OS watch. One Flutter project, two flavors (`phone`, `wear`), same `applicationId` (`su.iho.trackwatch`) and signing key — required by the Wearable Data Layer. |
| UI | Flutter on both devices, dark theme, Toggl project colors. |
| Native layer | Kotlin: Toggl API client, persistent queue, background sync, Data Layer, tile, complication, ongoing activity. |
| Auth | Paste Toggl API token on the phone. Stored encrypted (Android Keystore). Never sent to the watch. |
| Workspace | One — the account's default workspace. |
| Entry fields | Description and project only (no tags, no billable). |
| Favorites | App-local list of `(description, project)` pairs, edited on the phone (add, add from recent, reorder, delete), synced to the watch. |
| Recents | Last 10 distinct `(description, project)` pairs from history, shown on the watch. |
| History | Last 7 days, grouped by day with daily totals. |
| Watch actions | Start favorite / recent (immediately, haptic), start new (description via voice/keyboard + project picker), stop, continue, edit (description, project), delete (with confirmation). |
| Phone app | Settings only: token, favorites, sync status (queue size, last sync, error / rate limit, "Sync now"). |
| Offline / rate limits | Nothing is lost. The watch queues commands until the phone is reachable; the phone queues commands until Toggl accepts them (network, HTTP 402 quota, 429, 5xx). Commands carry the time the user tapped, so offline start/stop times are exact. UI is optimistic; unsynced entries show a ⟳ marker. Conflicts: last write wins. |
| Refresh | When the watch app or tile opens, after commands, "Sync now", and every 15 minutes in the background. Projects are refreshed at most hourly. A background refresh only wakes the watch when something besides the sync time and API quota changed. |
| Watch layout | Five horizontal pages with dots: Now (running timer with Stop / Cancel, Continue last, New timer), Favorites, Frequent (last 30 days, ranked once a day on the phone), History, Sync (status, Refresh, Open on phone). Starting a timer jumps to Now. The last page and each page's scroll position persist. |
| Watch extras | Ongoing Activity (icon on the watch face while a timer runs, with a static "description · since 9:41" status and a Stop action), a Tile (running timer + Open, then up to 6 timers in a two-column grid, favorites first and then frequent), a short-text complication (elapsed time of the running entry, `—` when idle), and an ambient (dimmed, low-power) screen. |
| Distribution | Personal sideload. GitHub Actions builds both APKs. |

## Architecture

```
 Watch (wear flavor)                           Phone (phone flavor)
 ┌──────────────────────────┐   DataItem       ┌───────────────────────────┐
 │ Flutter UI               │  /cmd/<uuid>     │ PhoneListenerService      │
 │   ⇅ MethodChannel        │ ───────────────► │   → CommandQueue (file)   │
 │ WatchRepository          │                  │   → SyncWorker (WorkMgr)  │
 │  - phone state cache     │   DataItem       │       → Toggl API v9      │
 │  - pending commands      │ ◄─────────────── │   → publish view state    │
 │  - optimistic reducer    │   /state (gzip)  │ Flutter settings UI       │
 │ Tile · Complication ·    │                  │   ⇅ MethodChannel         │
 │ Ongoing Activity         │   Message        │                           │
 │                          │  /refresh ─────► │                           │
 └──────────────────────────┘                  └───────────────────────────┘
```

* **Commands** (`start`, `stop`, `update`, `delete`) are created on the watch
  with a UUID and timestamp, applied locally (optimistic), and written as
  DataItems. The Data Layer stores and forwards them when the phone becomes
  reachable. Starting while a timer runs creates an explicit `stop` first.
* The phone moves each received command into its persistent queue, deletes
  the DataItem, and schedules `SyncWorker`. Entries created offline get a
  local id (`local-<uuid>`) that is mapped to the Toggl id once created.
  Deleting or editing a not-yet-created entry is coalesced in the queue.
* The phone publishes its **view state** (server snapshot with its queue
  applied, projects, favorites, received command ids, sync status) to
  `/state`. The watch applies its own still-unacknowledged commands on top.
* `stop` commands that are less than 2 minutes old use Toggl's `stop`
  endpoint; older ones set the exact stop time.

## Toggl API (v9) used

* `GET /me` — validate token, default workspace
* `GET /workspaces/{wid}` — workspace name
* `GET /workspaces/{wid}/projects?active=true`
* `GET /me/time_entries?start_date=…&end_date=…`
* `POST /workspaces/{wid}/time_entries`
* `PUT /workspaces/{wid}/time_entries/{id}`
* `PATCH /workspaces/{wid}/time_entries/{id}/stop`
* `DELETE /workspaces/{wid}/time_entries/{id}`

Every response's `X-Toggl-Quota-Remaining` / `X-Toggl-Quota-Resets-In` headers are saved and shown on the phone (Sync card) and the watch (Refresh chip).

Quota handling: `402` → wait `X-Toggl-Quota-Resets-In` seconds (default 15 min);
`429` → short backoff; `5xx`/network → WorkManager exponential backoff;
`401/403` → pause and show "invalid token" on the phone; other `4xx` → drop
that command and show the error.
