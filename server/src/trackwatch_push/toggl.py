"""Toggl Track Webhooks API v1: signature check and event parsing.

Docs: https://engineering.toggl.com/docs/webhooks_start
"""

from __future__ import annotations

import hashlib
import hmac
import json
from dataclasses import dataclass
from typing import Any

SIGNATURE_HEADER = "X-Webhook-Signature-256"

# Fields of a time entry the phone needs to tell whether it already knows this change.
ENTRY_FIELDS = ("id", "workspace_id", "user_id", "description", "project_id", "start", "stop", "duration", "server_deleted_at")
MAX_ENTRY_BYTES = 3000  # FCM data messages are limited to 4 KB in all.


def verify_signature(secret: str, body: bytes, header: str | None) -> bool:
    """Checks `X-Webhook-Signature-256: sha256=<hex HMAC-SHA256 of the body>`."""
    if not header or not header.startswith("sha256="):
        return False
    expected = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header.removeprefix("sha256=").strip().lower())


def sign(secret: str, body: bytes) -> str:
    """The header value Toggl would send for [body]; used by tests and the `selftest` command."""
    return "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()


@dataclass(frozen=True)
class Ping:
    """Toggl's test event. [validation_code] is set while the subscription is not validated yet."""

    validation_code: str | None


@dataclass(frozen=True)
class TimeEntryEvent:
    action: str  # created, updated or deleted
    user_id: int | None
    workspace_id: int | None
    entry: dict[str, Any]

    def fcm_data(self) -> dict[str, str]:
        """FCM data message values (all strings)."""
        entry = {k: self.entry.get(k) for k in ENTRY_FIELDS if k in self.entry}
        text = _dumps(entry)
        description = entry.get("description")
        if len(text.encode()) > MAX_ENTRY_BYTES and isinstance(description, str):
            # Too long (e.g. a long non-Latin description): cut it to fit. The phone then sees a
            # difference from what it knows and refreshes, which brings the full description.
            room = MAX_ENTRY_BYTES - len(_dumps({**entry, "description": ""}).encode())
            entry["description"] = description.encode()[: max(room, 0)].decode(errors="ignore")
            text = _dumps(entry)
        return {"kind": "time_entry", "action": self.action, "entry": text}


@dataclass(frozen=True)
class OtherEvent:
    """An event the phone doesn't need (another entity type)."""

    model: str | None


Event = Ping | TimeEntryEvent | OtherEvent


def _dumps(value: Any) -> str:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def _int(value: Any) -> int | None:
    try:
        return int(value) if value is not None and value != "" else None
    except (TypeError, ValueError):
        return None


def parse_event(data: Any) -> Event:
    if not isinstance(data, dict):
        raise ValueError("event is not a JSON object")
    payload = data.get("payload")
    if "validation_code" in data or payload == "ping":
        code = data.get("validation_code")
        return Ping(str(code) if code else None)

    metadata = data.get("metadata") if isinstance(data.get("metadata"), dict) else {}
    model = metadata.get("model") or metadata.get("entity")
    if model != "time_entry":
        return OtherEvent(model)
    entry = payload if isinstance(payload, dict) else {}
    action = str(metadata.get("action") or "updated")
    if entry.get("server_deleted_at"):
        action = "deleted"
    if "id" not in entry and metadata.get("time_entry_id") is not None:
        entry = {**entry, "id": metadata["time_entry_id"]}
    return TimeEntryEvent(
        action=action,
        user_id=_int(entry.get("user_id")) or _int(metadata.get("event_user_id")) or _int(data.get("creator_id")),
        workspace_id=_int(entry.get("workspace_id")) or _int(metadata.get("workspace_id")),
        entry=entry,
    )
