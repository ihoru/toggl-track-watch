"""Command line: `serve` runs the server; `toggl …` manages the Toggl webhook subscription.

    trackwatch-push serve
    trackwatch-push toggl subscribe https://push.example.com/toggl/webhook
    trackwatch-push toggl list | ping | events | enable | delete
    trackwatch-push secret

The `toggl` commands read your Toggl API token from TOGGL_API_TOKEN (or ask for it). They run on
your own computer; the server itself never needs the token.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import getpass
import json
import logging
import os
import secrets
import sys
import urllib.error
import urllib.request
from pathlib import Path

TOGGL_API = "https://api.track.toggl.com/api/v9"
WEBHOOKS_API = "https://track.toggl.com/webhooks/api/v1"
USER_AGENT = "trackwatch-push (https://github.com/ihoru/toggl-track-watch)"
EVENT_FILTERS = [
    {"entity": "time_entry", "action": "created"},
    {"entity": "time_entry", "action": "updated"},
    {"entity": "time_entry", "action": "deleted"},
]
DESCRIPTION = "Track Watch live updates"


def _env(name: str, required: bool = True) -> str | None:
    value = os.environ.get(name, "").strip()
    if required and not value:
        sys.exit(f"Set {name} (see server/README.md)")
    return value or None


def serve(args: argparse.Namespace) -> None:
    import aiohttp
    from aiohttp import web

    from .app import Config, make_app
    from .fcm import FcmSender
    from .store import DeviceStore

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    config = Config(webhook_secret=_env("TOGGL_WEBHOOK_SECRET"), app_secret=_env("TRACKWATCH_APP_SECRET"))
    credentials = _env("GOOGLE_APPLICATION_CREDENTIALS")
    store = DeviceStore(Path(os.environ.get("TRACKWATCH_DATA_DIR", "data")) / "devices.json")

    async def build() -> web.Application:
        session = aiohttp.ClientSession()
        sender = FcmSender(credentials, _env("FIREBASE_PROJECT_ID", required=False), session)
        app = make_app(config, store, sender)

        async def close(_: web.Application) -> None:
            await session.close()

        app.on_cleanup.append(close)
        logging.getLogger(__name__).info("Sending to Firebase project %s; %d device(s) registered", sender.project_id, len(store.all()))
        return app

    web.run_app(build(), host=args.host, port=args.port, access_log=None)


def _toggl(method: str, url: str, token: str, body: dict | None = None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", "Basic " + base64.b64encode(f"{token}:api_token".encode()).decode())
    request.add_header("User-Agent", USER_AGENT)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            text = response.read().decode()
    except urllib.error.HTTPError as e:
        sys.exit(f"Toggl answered {e.code}: {e.read().decode()[:500]}")
    return json.loads(text) if text.strip() else None


def toggl_command(args: argparse.Namespace) -> None:
    token = os.environ.get("TOGGL_API_TOKEN") or getpass.getpass("Toggl API token: ")
    workspace = args.workspace or _toggl("GET", f"{TOGGL_API}/me", token)["default_workspace_id"]
    base = f"{WEBHOOKS_API}/subscriptions/{workspace}"
    subscriptions = _toggl("GET", base, token) or []
    ours = [s for s in subscriptions if s.get("description") == DESCRIPTION]

    def show(items) -> None:
        print(json.dumps(items, indent=2))

    if args.action == "subscribe":
        if not args.url:
            sys.exit("Pass the webhook URL, e.g. https://push.example.com/toggl/webhook")
        secret = os.environ.get("TOGGL_WEBHOOK_SECRET") or secrets.token_urlsafe(32)
        body = {"url_callback": args.url, "event_filters": EVENT_FILTERS, "enabled": True, "description": DESCRIPTION, "secret": secret}
        if ours:
            result = _toggl("PUT", f"{base}/{ours[0]['subscription_id']}", token, body)
        else:
            result = _toggl("POST", base, token, body)
        print(f"Subscription {result['subscription_id']} in workspace {workspace} -> {result['url_callback']}")
        print(f"\nTOGGL_WEBHOOK_SECRET={secret}\n")
        print("Put that line in the server's environment and start it, then run `toggl ping` to validate the URL.")
        return
    if args.action == "list":
        show(subscriptions)
        return
    if not ours:
        sys.exit(f"No '{DESCRIPTION}' subscription in workspace {workspace}; run `toggl subscribe <url>` first.")
    sub_id = ours[0]["subscription_id"]
    if args.action == "ping":
        show(_toggl("POST", f"{WEBHOOKS_API}/ping/{workspace}/{sub_id}", token))
        print("Toggl sent a ping. `toggl list` shows validated_at once the server answered it.")
    elif args.action == "events":
        show(_toggl("GET", f"{base}/{sub_id}/events", token))
    elif args.action == "enable":
        # Toggl disables a subscription after repeated delivery failures; this turns it back on.
        show(_toggl("PATCH", f"{base}/{sub_id}", token, {"enabled": True}))
    elif args.action == "delete":
        _toggl("DELETE", f"{base}/{sub_id}", token)
        print(f"Deleted subscription {sub_id}")


def main() -> None:
    parser = argparse.ArgumentParser(prog="trackwatch-push", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command")

    p = sub.add_parser("serve", help="run the HTTP server (default)")
    p.add_argument("--host", default=os.environ.get("HOST", "0.0.0.0"))
    p.add_argument("--port", type=int, default=int(os.environ.get("PORT", "8080")))
    p.set_defaults(func=serve)

    p = sub.add_parser("toggl", help="manage the Toggl webhook subscription")
    p.add_argument("action", choices=["subscribe", "list", "ping", "events", "enable", "delete"])
    p.add_argument("url", nargs="?", help="webhook URL (for subscribe)")
    p.add_argument("--workspace", type=int, help="workspace id (default: your default workspace)")
    p.set_defaults(func=toggl_command)

    p = sub.add_parser("secret", help="print a random secret for TRACKWATCH_APP_SECRET")
    p.set_defaults(func=lambda _: print(secrets.token_urlsafe(32)))

    args = parser.parse_args(sys.argv[1:] or ["serve"])
    if args.command is None:
        args = parser.parse_args(["serve"])
    args.func(args)


if __name__ == "__main__":
    main()
