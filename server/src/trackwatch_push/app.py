"""HTTP endpoints.

POST   /toggl/webhook  Toggl Track webhook events (signed with the subscription secret).
POST   /devices        The phone registers its FCM token (Authorization: Bearer <app secret>).
DELETE /devices        The phone removes its token (sign-out, live updates turned off).
GET    /health         Liveness check; also says when the last Toggl event arrived.
"""

from __future__ import annotations

import asyncio
import hmac
import json
import logging
from dataclasses import dataclass

from aiohttp import web

from . import toggl
from .fcm import Sender, SendResult
from .store import Device, DeviceStore

log = logging.getLogger(__name__)

MAX_BODY = 256 * 1024


@dataclass(frozen=True)
class Config:
    webhook_secret: str
    app_secret: str


STORE = web.AppKey("store", DeviceStore)
SENDER = web.AppKey("sender", Sender)
CONFIG = web.AppKey("config", Config)
TASKS = web.AppKey("tasks", set)


async def webhook(request: web.Request) -> web.Response:
    body = await request.read()
    if not toggl.verify_signature(request.app[CONFIG].webhook_secret, body, request.headers.get(toggl.SIGNATURE_HEADER)):
        log.warning("Rejected a webhook call with a missing or wrong signature")
        return web.json_response({"error": "bad signature"}, status=401)
    try:
        event = toggl.parse_event(json.loads(body))
    except ValueError as e:
        return web.json_response({"error": str(e)}, status=400)

    if isinstance(event, toggl.Ping):
        log.info("Toggl ping%s", " with validation code" if event.validation_code else "")
        # Answering with the code validates the subscription (Toggl's synchronous validation).
        return web.json_response({"validation_code": event.validation_code} if event.validation_code else {"ok": True})

    request.app[STORE].event_received()
    if isinstance(event, toggl.TimeEntryEvent):
        devices = request.app[STORE].for_user(event.user_id)
        log.info("time_entry %s (user %s) -> %d device(s)", event.action, event.user_id, len(devices))
        # Answer Toggl right away; it retries and eventually disables slow or failing endpoints.
        task = asyncio.create_task(_fan_out(request.app, devices, event.fcm_data()))
        request.app[TASKS].add(task)
        task.add_done_callback(request.app[TASKS].discard)
    return web.json_response({"ok": True})


async def _fan_out(app: web.Application, devices: list[Device], data: dict[str, str]) -> None:
    for device in devices:
        try:
            result = await app[SENDER].send(device.token, data)
        except Exception:
            log.exception("Sending to %s failed", device.name or "a device")
            continue
        if result is SendResult.UNREGISTERED:
            log.info("Forgetting an unregistered device (%s)", device.name or "unnamed")
            app[STORE].remove(device.token)


def _authorized(request: web.Request) -> bool:
    header = request.headers.get("Authorization", "")
    secret = request.app[CONFIG].app_secret
    return header.startswith("Bearer ") and hmac.compare_digest(header.removeprefix("Bearer ").strip(), secret)


async def _json(request: web.Request) -> dict:
    try:
        data = await request.json()
    except (ValueError, UnicodeDecodeError):
        raise web.HTTPBadRequest(text='{"error": "invalid JSON"}', content_type="application/json")
    if not isinstance(data, dict):
        raise web.HTTPBadRequest(text='{"error": "expected an object"}', content_type="application/json")
    return data


async def register(request: web.Request) -> web.Response:
    if not _authorized(request):
        return web.json_response({"error": "wrong app secret"}, status=401)
    data = await _json(request)
    token, user_id = data.get("token"), data.get("user_id")
    if not isinstance(token, str) or not token or not isinstance(user_id, int) or user_id <= 0:
        return web.json_response({"error": "token and user_id are required"}, status=400)
    workspace_id = data.get("workspace_id") if isinstance(data.get("workspace_id"), int) else None
    name = str(data.get("name") or "")[:100]
    request.app[STORE].register(Device(token=token, user_id=user_id, workspace_id=workspace_id, name=name))
    log.info("Registered %s for user %s", name or "a device", user_id)
    return web.json_response({"ok": True, "last_event_at": request.app[STORE].last_event_at})


async def unregister(request: web.Request) -> web.Response:
    if not _authorized(request):
        return web.json_response({"error": "wrong app secret"}, status=401)
    data = await _json(request)
    token = data.get("token")
    removed = isinstance(token, str) and request.app[STORE].remove(token)
    return web.json_response({"ok": True, "removed": removed})


async def health(request: web.Request) -> web.Response:
    return web.json_response({"ok": True, "last_event_at": request.app[STORE].last_event_at})


def make_app(config: Config, store: DeviceStore, sender: Sender) -> web.Application:
    app = web.Application(client_max_size=MAX_BODY)
    app[CONFIG] = config
    app[STORE] = store
    app[SENDER] = sender
    app[TASKS] = set()
    app.router.add_post("/toggl/webhook", webhook)
    app.router.add_post("/devices", register)
    app.router.add_delete("/devices", unregister)
    app.router.add_get("/health", health)
    return app
