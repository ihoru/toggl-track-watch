"""Command line.

    trackwatch-push serve             run the server
    trackwatch-push registrations     list the registered phones
    trackwatch-push toggl list | events | delete   look at your own Toggl webhook subscriptions

The phone app creates and repairs its Toggl webhook subscription itself, so none of this is
needed for setup. The `toggl` commands read your Toggl API token from TOGGL_API_TOKEN (or ask for
it) and are for troubleshooting from your own computer; the server never needs the token.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import getpass
import json
import logging
import os
import time
import sys
import urllib.error
import urllib.request
from pathlib import Path

TOGGL_API = "https://api.track.toggl.com/api/v9"
WEBHOOKS_API = "https://api.track.toggl.com/webhooks/api/v1"
USER_AGENT = "trackwatch-push (https://github.com/ihoru/toggl-track-watch)"
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

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    config = Config(
        max_registrations=int(os.environ.get("TRACKWATCH_MAX_REGISTRATIONS") or 1000),
        registrations_per_ip_hour=int(os.environ.get("TRACKWATCH_REGISTRATIONS_PER_IP_HOUR") or 10),
    )
    credentials = _env("GOOGLE_APPLICATION_CREDENTIALS")
    store = _store()

    async def build() -> web.Application:
        session = aiohttp.ClientSession()
        sender = FcmSender(credentials, _env("FIREBASE_PROJECT_ID", required=False), session)
        app = make_app(config, store, sender)

        async def close(_: web.Application) -> None:
            await session.close()

        app.on_cleanup.append(close)
        logging.getLogger(__name__).info("Sending to Firebase project %s; %d registration(s)", sender.project_id, len(store))
        return app

    web.run_app(build(), host=args.host, port=args.port, access_log=None)


def _store():
    from .store import RegistrationStore

    return RegistrationStore(Path(os.environ.get("TRACKWATCH_DATA_DIR", "data")) / "registrations.json")


def _when(ts: float | None) -> str:
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(ts)) if ts else "never"


def registrations(_: argparse.Namespace) -> None:
    items = sorted(_store().all(), key=lambda r: r.created_at)
    for r in items:
        state = "validated" if r.validated_at else "NOT validated"
        print(f"{r.id[:8]}  user {r.user_id}  {r.name or '-'}  {state}  last event {_when(r.last_event_at)}")
    print(f"{len(items)} registration(s), {len({r.user_id for r in items})} user(s)")


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
    ours = [s for s in subscriptions if str(s.get("description") or "").startswith(DESCRIPTION)]

    def show(items) -> None:
        print(json.dumps(items, indent=2))

    if args.action == "list":
        show(subscriptions)
        return
    if not ours:
        sys.exit(f"No '{DESCRIPTION}' subscription in workspace {workspace}; the phone app creates it.")
    sub_id = ours[0]["subscription_id"]
    if args.action == "events":
        show(_toggl("GET", f"{base}/{sub_id}/events", token))
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

    p = sub.add_parser("registrations", help="list the registered phones")
    p.set_defaults(func=registrations)

    p = sub.add_parser("toggl", help="look at your own Toggl webhook subscriptions")
    p.add_argument("action", choices=["list", "events", "delete"])
    p.add_argument("--workspace", type=int, help="workspace id (default: your default workspace)")
    p.set_defaults(func=toggl_command)

    args = parser.parse_args(sys.argv[1:] or ["serve"])
    if args.command is None:
        args = parser.parse_args(["serve"])
    args.func(args)


if __name__ == "__main__":
    main()
