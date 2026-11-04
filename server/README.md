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

* Anyone with the app can use it: in the phone app, **Live updates → Turn on** is all it takes. The
  phone registers with the server, gets its own webhook URL and secret, and creates the Toggl
  webhook subscription itself with the user's API token. Toggl has no OAuth for other apps, and the
  phone already has the token, so there is no website to sign in on.
* The server never sees anyone's Toggl API token. It keeps, per phone, the registration (FCM token,
  Toggl user and workspace id, phone model, webhook secret) in `data/registrations.json`. Time
  entries only pass through.
* The phone skips the Toggl call when the event is its own change coming back, and applies
  deletions directly. A change made elsewhere costs one or two Toggl requests.
* The app works without the server exactly as before. Builds without a Firebase configuration
  (forks, Dependabot pull requests) don't show live updates at all.

A server can only push to app builds made with its own Firebase project, so the Play Store app uses
the server built into it (`LIVE_UPDATES_URL` at build time, `https://trackwatch.iho.su` by default).
Running your own makes sense with your own build. Setup: Firebase, the server, the app build.

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

Needs a public HTTPS URL, e.g. `https://push.example.com` (Toggl and the phone app only accept
`https://`). Copy the service account file next to `compose.yaml` as
`firebase-service-account.json`, then:

```sh
cd server
docker compose up -d --build
docker compose logs -f
```

There are no secrets to set. `.env` is optional (see `.env.example`): limits and the host port. The
container listens on `127.0.0.1:8081` (`TRACKWATCH_PORT` changes it). Put it behind your HTTPS
reverse proxy, for nginx:

```nginx
server {
    listen 443 ssl;
    server_name push.example.com;
    # ssl_certificate … (e.g. from certbot)

    location / {
        proxy_pass http://127.0.0.1:8081;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

`X-Forwarded-For` matters: the per-IP registration limit uses the address the proxy saw.

Without Docker: `uv sync --no-dev`, then run `uv run trackwatch-push serve` with the variables
below in the environment (e.g. from a systemd unit).

| Variable | |
|---|---|
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to the Firebase service account JSON (set by `compose.yaml`). |
| `FIREBASE_PROJECT_ID` | Optional; read from the service account file. |
| `TRACKWATCH_MAX_REGISTRATIONS` | Phones in all; default 1000. New ones get 503 beyond it. |
| `TRACKWATCH_REGISTRATIONS_PER_IP_HOUR` | New registrations per IP address per hour; default 10. |
| `TRACKWATCH_DATA_DIR` | Where `registrations.json` is kept (`/data` in Docker, on the `data` volume; `./data` otherwise). |
| `HOST`, `PORT` | Default `0.0.0.0:8080`. |

Endpoints:

| | |
|---|---|
| `POST /registrations` | A phone registers (FCM token, Toggl user id). Answers its id, secret and webhook path. |
| `GET`/`PUT`/`DELETE /registrations/<id>` | Status, new FCM token, removal; `Authorization: Bearer <secret>`. |
| `POST /toggl/webhook/<id>` | Toggl's events for that phone, signed with its secret. Unknown ids get 410. |
| `GET /health` | Liveness check; also says when the last Toggl event arrived. |

Why registering needs no password: the server can only push to the app it was built for, and a
phone only gets events from the Toggl subscription its own token created; for a workspace admin's
subscription, only the admin's own entries are forwarded. Registrations Toggl never validates
expire after an hour.

`uv run trackwatch-push registrations` (in the container: `docker compose exec trackwatch-push
trackwatch-push registrations`) lists the phones: user id, model, validated, last event.

## 3. The app build

Build the phone app with `GOOGLE_SERVICES_JSON` (step 1) and, for your own server,
`LIVE_UPDATES_URL=https://push.example.com` in the environment (a repository variable or secret in
CI). Users can also enter a server in **Live updates → Settings**.

In the phone app, tap the sync row to open the details, then **Live updates → Turn on**. The line
turns to **Live updates on** once Toggl validated the webhook, usually within seconds. Stop a timer
on [track.toggl.com](https://track.toggl.com) and the watch should show it stopped within a few
seconds; the server log shows `time_entry updated -> <id>…`.

The phone's subscription is named "Track Watch live updates" in the user's default workspace.
Toggl's limits are per workspace: the Free plan allows 1 webhook (with up to 3 event filters, which
is exactly what this uses), Starter 2, Premium 3. So on the Free plan one phone per account and
workspace gets live updates: turning them on on a second phone moves the subscription there, and
the first phone says so and goes back to polling. Docs:
[Toggl Webhooks API](https://engineering.toggl.com/docs/webhooks_start).

For troubleshooting, `uv run trackwatch-push toggl list|events|delete` shows your own subscriptions
(it asks for your Toggl API token; run it on your computer).

## How the phone behaves with live updates on

* Opening the watch app or tile re-sends the phone's state without asking Toggl. The watch's
  **Refresh** button and the phone's **Sync now** still ask Toggl.
* Background polling drops from every 15 minutes to once a day. That run also re-ranks the
  Recent and Frequent lists and checks the registration and the Toggl subscription: Toggl turns a
  subscription off after repeated delivery failures (e.g. while the server was down), and the phone
  turns it back on.
* If setting up fails (server down, Toggl's webhook limit reached), the phone shows the error and
  polls every 15 minutes until it works again.
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
