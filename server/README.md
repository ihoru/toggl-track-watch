# Track Watch live updates server

Without this server the phone app asks Toggl for changes every 15 minutes, so a timer stopped on
the web or desktop can stay "running" on the watch for up to 15 minutes. With it, Toggl tells the
server about every time-entry change, the server pushes it to the phone, and the phone updates the
watch within seconds. The phone then polls Toggl only once a day, as a safety net.

```
Toggl Track ──webhook──► this server ──FCM data message──► phone app ──Data Layer──► watch
 (time_entry created /     (checks the      (Firebase Cloud        (refreshes only when the
  updated / deleted)        signature)        Messaging)             change is new to it)
```

* The server never sees your Toggl API token. It keeps only the webhook secret, an app secret
  and the phones' FCM tokens (`data/devices.json`).
* The phone skips the Toggl call when the event is its own change coming back, and applies
  deletions directly. A change made elsewhere costs one or two Toggl requests.
* The app works without the server exactly as before. Builds without a Firebase configuration
  (forks, Dependabot pull requests) don't show live updates at all.

Setup takes four parts, in this order: Firebase, the server, the Toggl subscription, the phone app.

## 1. Firebase

1. In the [Firebase console](https://console.firebase.google.com/), **Create a project** (Google
   Analytics isn't needed).
2. **Add app → Android**. Package name: `su.iho.trackwatch`. Nickname: e.g. "Track Watch phone".
   The SHA-1 certificate isn't needed for messaging. Download **`google-services.json`**.
3. Give the app build that file. It isn't committed (the repository is public, and `.gitignore`
   keeps it out):
   * **CI and releases:** GitHub → repository **Settings → Secrets and variables → Actions → New
     repository secret**. Name `GOOGLE_SERVICES_JSON`, value: the whole content of the file. The
     Build and Release workflows write it to `android/app/src/phone/google-services.json`.
   * **Local builds:** copy it to `android/app/src/phone/google-services.json`.
4. **Project settings → Cloud Messaging**: check that **Firebase Cloud Messaging API (V1)** is
   enabled (it is for new projects).
5. **Project settings → Service accounts → Generate new private key**. Keep the downloaded JSON
   for the server as `firebase-service-account.json`. It can send messages to your app: keep it
   private and never commit it.

## 2. The server

Needs a public HTTPS URL, e.g. `https://push.example.com` (the phone app only accepts `https://`).

```sh
cd server
cp .env.example .env
python3 -c "import secrets; print(secrets.token_urlsafe(32))"   # or: uv run trackwatch-push secret
```

Put that random string in `.env` as `TRACKWATCH_APP_SECRET` (you'll enter it in the phone app too).
`TOGGL_WEBHOOK_SECRET` comes from step 3. Copy the service account file next to `compose.yaml`
as `firebase-service-account.json`, then:

```sh
docker compose up -d --build
docker compose logs -f
```

The container listens on `127.0.0.1:8080`. Put it behind your HTTPS reverse proxy, for nginx:

```nginx
server {
    listen 443 ssl;
    server_name push.example.com;
    # ssl_certificate … (e.g. from certbot)

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

Without Docker: `uv sync --no-dev`, then run `uv run trackwatch-push serve` with the variables
below in the environment (e.g. from a systemd unit).

| Variable | |
|---|---|
| `TOGGL_WEBHOOK_SECRET` | Signs Toggl's calls; printed by `toggl subscribe`. |
| `TRACKWATCH_APP_SECRET` | Phones must send it to register. |
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to the Firebase service account JSON (set by `compose.yaml`). |
| `FIREBASE_PROJECT_ID` | Optional; read from the service account file. |
| `TRACKWATCH_DATA_DIR` | Where `devices.json` is kept (`/data` in Docker, on the `data` volume; `./data` otherwise). |
| `HOST`, `PORT` | Default `0.0.0.0:8080`. |

Endpoints: `POST /toggl/webhook` (Toggl), `POST`/`DELETE /devices` (the phone app, with
`Authorization: Bearer <TRACKWATCH_APP_SECRET>`), `GET /health` (also shows when the last Toggl
event arrived).

## 3. The Toggl webhook subscription

Run these on your own computer (they need your Toggl API token, from
[your Toggl profile](https://track.toggl.com/profile); the server doesn't):

```sh
cd server
uv sync
export TOGGL_API_TOKEN=…            # or leave it unset to be asked
uv run trackwatch-push toggl subscribe https://push.example.com/toggl/webhook
```

It creates (or updates) a subscription named "Track Watch live updates" in your default workspace
(`--workspace <id>` for another one) for `time_entry` created, updated and deleted events, and
prints `TOGGL_WEBHOOK_SECRET=…`. Put that line in the server's `.env`, restart it
(`docker compose up -d`), then validate the URL:

```sh
uv run trackwatch-push toggl ping    # Toggl sends a ping; the server answers its validation code
uv run trackwatch-push toggl list    # validated_at is now set and enabled is true
```

Other commands: `toggl events` (recent deliveries and their errors), `toggl enable` (Toggl turns
a subscription off after repeated delivery failures, e.g. while the server was down), `toggl delete`.

Toggl's limits are per workspace: the Free plan allows 1 webhook with up to 3 event filters, which
is exactly what this uses; Starter allows 2 webhooks with 6, Premium 3 with 12. Docs:
[Toggl Webhooks API](https://engineering.toggl.com/docs/webhooks_start).

## 4. The phone app

Install a build made with `GOOGLE_SERVICES_JSON` (any CI or release build after the secret is
set). In the phone app, tap the sync row to open the details, then **Live updates → Set up**:

* **Server URL:** `https://push.example.com` (without `/devices`)
* **App secret:** the `TRACKWATCH_APP_SECRET` value

The line turns to **Live updates on** once the server accepted the phone. Stop a timer on
[track.toggl.com](https://track.toggl.com) and the watch should show it stopped within a few
seconds; the server log shows `time_entry updated (user …) -> 1 device(s)`.

## How the phone behaves with live updates on

* Opening the watch app or tile re-sends the phone's state without asking Toggl. The watch's
  **Refresh** button and the phone's **Sync now** still ask Toggl.
* Background polling drops from every 15 minutes to once a day (that run also re-ranks the
  Recent and Frequent lists, and re-registers with the server once a week).
* If registering fails (wrong secret, server down), the phone shows the error and polls every
  15 minutes until it works again.
* While the phone is offline, Firebase keeps the messages (up to a day here) and delivers them
  when it's back.
* High-priority messages wake the phone from Doze. Android may treat them as normal priority if
  an app gets many that show no notification; they still arrive, just later while the phone sleeps.

## Development

```sh
cd server
uv sync
uv run pytest
```
