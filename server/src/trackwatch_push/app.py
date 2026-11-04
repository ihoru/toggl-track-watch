"""HTTP endpoints.

POST   /registrations           A phone registers: FCM token + Toggl user id. Answers the id, the
                                secret and the webhook path the phone then subscribes in Toggl.
GET    /registrations/<id>      Status (Authorization: Bearer <secret>): validated, last event.
PUT    /registrations/<id>      Updates the FCM token or account (Bearer <secret>).
DELETE /registrations/<id>      Forgets the phone (Bearer <secret>).
POST   /toggl/webhook/<id>      Toggl Track webhook events, signed with that registration's secret.
GET    /health                  Liveness check.

Anyone may register: the server can only push to the app it was built for (its Firebase project),
and a registration only receives events from a Toggl subscription its owner created. The FCM token
is checked with Firebase (a validate-only send) before it's stored, so registrations need a real
install of the app. Unvalidated registrations expire after an hour; registrations per IP address and
in all are limited.
"""

from __future__ import annotations

import asyncio
import contextlib
import ipaddress
import json
import logging
import time
from collections import defaultdict, deque
from dataclasses import dataclass

from aiohttp import web

from . import toggl
from .fcm import Sender, SendResult
from .store import INACTIVE_TTL, Registration, RegistrationStore

log = logging.getLogger(__name__)

MAX_BODY = 256 * 1024
EXPIRE_EVERY = 10 * 60


@dataclass(frozen=True)
class Config:
    max_registrations: int = 1000
    registrations_per_ip_hour: int = 10


STORE = web.AppKey("store", RegistrationStore)
SENDER = web.AppKey("sender", Sender)
CONFIG = web.AppKey("config", Config)
TASKS = web.AppKey("tasks", set)


class RateLimiter:
    def __init__(self, limit: int, window: float = 3600):
        self._limit = limit
        self._window = window
        self._hits: dict[str, deque[float]] = defaultdict(deque)

    def allow(self, key: str, now: float | None = None) -> bool:
        now = time.monotonic() if now is None else now
        hits = self._hits[key]
        while hits and now - hits[0] > self._window:
            hits.popleft()
        if len(hits) >= self._limit:
            return False
        hits.append(now)
        return True


LIMITER = web.AppKey("limiter", RateLimiter)


def _client_ip(request: web.Request) -> str:
    """The caller's address; behind a local reverse proxy, the address it saw (last X-Forwarded-For hop)."""
    remote = request.remote or ""
    with contextlib.suppress(ValueError):
        if ipaddress.ip_address(remote).is_loopback or ipaddress.ip_address(remote).is_private:
            forwarded = request.headers.get("X-Forwarded-For", "")
            hops = [h.strip() for h in forwarded.split(",") if h.strip()]
            if hops:
                return hops[-1]
    return remote


def _error(status: int, message: str) -> web.Response:
    return web.json_response({"error": message}, status=status)


async def _json(request: web.Request) -> dict:
    try:
        data = await request.json()
    except (ValueError, UnicodeDecodeError):
        raise web.HTTPBadRequest(text='{"error": "invalid JSON"}', content_type="application/json")
    if not isinstance(data, dict):
        raise web.HTTPBadRequest(text='{"error": "expected an object"}', content_type="application/json")
    return data


def _phone_fields(data: dict) -> dict | None:
    token, user_id = data.get("token"), data.get("user_id")
    if not isinstance(token, str) or not token or len(token) > 4096:
        return None
    if not isinstance(user_id, int) or isinstance(user_id, bool) or user_id <= 0:
        return None
    workspace_id = data.get("workspace_id")
    return {
        "token": token,
        "user_id": user_id,
        "workspace_id": workspace_id if isinstance(workspace_id, int) and not isinstance(workspace_id, bool) else None,
        "name": str(data.get("name") or "")[:100],
    }


def _status(reg: Registration) -> dict:
    return {"ok": True, "validated": reg.validated_at is not None, "last_event_at": reg.last_event_at}


def _authorized(request: web.Request) -> Registration | None:
    header = request.headers.get("Authorization", "")
    if not header.startswith("Bearer "):
        return None
    return request.app[STORE].authorized(request.match_info["id"], header.removeprefix("Bearer ").strip())


async def create_registration(request: web.Request) -> web.Response:
    fields = _phone_fields(await _json(request))
    if fields is None:
        return _error(400, "token and user_id are required")
    store = request.app[STORE]
    config = request.app[CONFIG]
    if not request.app[LIMITER].allow(_client_ip(request)):
        return _error(429, "too many registrations, try again later")
    if len(store) >= config.max_registrations:
        store.expire_unvalidated()
        if len(store) >= config.max_registrations:
            log.warning("Registration refused: the limit of %d is reached", config.max_registrations)
            return _error(503, "the server is full")
    if (problem := await _check_token(request.app, fields["token"])) is not None:
        return problem
    reg = store.create(**fields)
    log.info("New registration %s… for user %s (%s)", reg.id[:6], reg.user_id, reg.name or "unnamed")
    return web.json_response(
        {"id": reg.id, "secret": reg.secret, "webhook_path": f"/toggl/webhook/{reg.id}", "validated": False},
        status=201,
    )


async def _check_token(app: web.Application, token: str) -> web.Response | None:
    """An error response unless Firebase knows [token] for this app."""
    try:
        result = await app[SENDER].send(token, {"kind": "check"}, validate_only=True)
    except Exception:
        log.exception("Checking an FCM token failed")
        result = SendResult.FAILED
    if result is SendResult.UNREGISTERED:
        return _error(400, "unknown push token")
    if result is SendResult.FAILED:
        return _error(503, "can't check the push token now, try again later")
    return None


async def get_registration(request: web.Request) -> web.Response:
    reg = _authorized(request)
    return _error(404, "unknown registration") if reg is None else web.json_response(_status(reg))


async def update_registration(request: web.Request) -> web.Response:
    reg = _authorized(request)
    if reg is None:
        return _error(404, "unknown registration")
    fields = _phone_fields(await _json(request))
    if fields is None:
        return _error(400, "token and user_id are required")
    if fields["token"] != reg.token and (problem := await _check_token(request.app, fields["token"])) is not None:
        return problem
    reg = request.app[STORE].update(reg.id, **fields)
    return _error(404, "unknown registration") if reg is None else web.json_response(_status(reg))


async def delete_registration(request: web.Request) -> web.Response:
    reg = _authorized(request)
    if reg is None:
        return _error(404, "unknown registration")
    request.app[STORE].remove(reg.id)
    log.info("Registration %s… removed by the phone", reg.id[:6])
    return web.json_response({"ok": True})


async def webhook(request: web.Request) -> web.Response:
    store = request.app[STORE]
    reg = store.get(request.match_info["id"])
    if reg is None:
        # 410 tells whoever still calls it (an old subscription) that it's gone.
        return _error(410, "unknown subscription")
    body = await request.read()
    if not toggl.verify_signature(reg.secret, body, request.headers.get(toggl.SIGNATURE_HEADER)):
        log.warning("Rejected a webhook call for %s… with a missing or wrong signature", reg.id[:6])
        return _error(401, "bad signature")
    try:
        event = toggl.parse_event(json.loads(body))
    except ValueError as e:
        return _error(400, str(e))

    if isinstance(event, toggl.Ping):
        store.touch(reg.id, validated=True)
        log.info("Toggl ping for %s…%s", reg.id[:6], " with validation code" if event.validation_code else "")
        # Answering with the code validates the subscription (Toggl's synchronous validation).
        return web.json_response({"validation_code": event.validation_code} if event.validation_code else {"ok": True})

    store.touch(reg.id, validated=True, event=True)
    # A workspace admin's subscription can also bring other members' entries: only the phone's own go.
    if isinstance(event, toggl.TimeEntryEvent) and event.user_id == reg.user_id:
        log.info("time_entry %s -> %s…", event.action, reg.id[:6])
        # Answer Toggl right away; it retries and eventually disables slow or failing endpoints.
        task = asyncio.create_task(_send(request.app, reg, event.fcm_data()))
        request.app[TASKS].add(task)
        task.add_done_callback(request.app[TASKS].discard)
    return web.json_response({"ok": True})


async def _send(app: web.Application, reg: Registration, data: dict[str, str]) -> None:
    # The phone may send a new token while this is in flight: only the token that failed is forgotten.
    token = reg.token
    try:
        result = await app[SENDER].send(token, data)
    except Exception:
        log.exception("Sending to %s… failed", reg.id[:6])
        return
    if result is SendResult.UNREGISTERED:
        # The app was uninstalled or its data cleared. The Toggl subscription then gets 410s and
        # Toggl turns it off.
        log.info("Forgetting %s…: its FCM token is no longer registered", reg.id[:6])
        app[STORE].remove_token(token)


async def health(request: web.Request) -> web.Response:
    return web.json_response({"ok": True, "last_event_at": request.app[STORE].last_event_at()})


async def _expire_loop(app: web.Application):
    async def run() -> None:
        while True:
            removed = app[STORE].expire_unvalidated()
            if removed:
                log.info("Dropped %d registration(s) Toggl never validated", removed)
            removed = app[STORE].expire_inactive()
            if removed:
                log.info("Dropped %d registration(s) not seen for %d days", removed, INACTIVE_TTL // 86400)
            await asyncio.sleep(EXPIRE_EVERY)

    task = asyncio.create_task(run())
    yield
    task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await task


def make_app(config: Config, store: RegistrationStore, sender: Sender) -> web.Application:
    app = web.Application(client_max_size=MAX_BODY)
    app[CONFIG] = config
    app[STORE] = store
    app[SENDER] = sender
    app[TASKS] = set()
    app[LIMITER] = RateLimiter(config.registrations_per_ip_hour)
    app.cleanup_ctx.append(_expire_loop)
    app.router.add_post("/registrations", create_registration)
    app.router.add_get("/registrations/{id}", get_registration)
    app.router.add_put("/registrations/{id}", update_registration)
    app.router.add_delete("/registrations/{id}", delete_registration)
    app.router.add_post("/toggl/webhook/{id}", webhook)
    app.router.add_get("/health", health)
    return app
