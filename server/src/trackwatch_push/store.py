"""Registrations: one per phone, kept in a small JSON file.

A registration ties a phone's FCM token to one Toggl webhook subscription, which the phone itself
creates with its own Toggl API token. The server only knows the subscription's callback id and
secret, never the Toggl token.
"""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import tempfile
import threading
import time
from dataclasses import asdict, dataclass
from pathlib import Path

# A registration Toggl never validated (the phone gave up, or someone just called the API) is
# dropped after this long.
UNVALIDATED_TTL = 60 * 60
# Phones check in daily (PUT) and get events while used. One that did neither for this long was
# uninstalled, replaced, or lost its subscription to a newer install.
INACTIVE_TTL = 30 * 24 * 60 * 60


@dataclass
class Registration:
    id: str
    secret: str  # Signs Toggl's calls to /toggl/webhook/<id>; also authenticates the phone.
    token: str  # FCM registration token.
    user_id: int
    workspace_id: int | None = None
    name: str = ""
    created_at: float = 0.0
    updated_at: float = 0.0
    validated_at: float | None = None
    last_event_at: float | None = None


def _hash(secret: str) -> str:
    return hashlib.sha256(secret.encode()).hexdigest()


class RegistrationStore:
    def __init__(self, path: Path):
        self._path = path
        self._lock = threading.Lock()
        self._items: dict[str, Registration] = {}
        if path.exists():
            raw = json.loads(path.read_text() or "{}")
            self._items = {r["id"]: Registration(**r) for r in raw.get("registrations", [])}

    def __len__(self) -> int:
        with self._lock:
            return len(self._items)

    def create(self, token: str, user_id: int, workspace_id: int | None, name: str) -> Registration:
        now = time.time()
        with self._lock:
            # One registration per FCM token: a phone that registers again replaces its old one.
            for old in [r for r in self._items.values() if r.token == token]:
                del self._items[old.id]
            reg = Registration(
                id=secrets.token_urlsafe(16),
                secret=secrets.token_urlsafe(32),
                token=token,
                user_id=user_id,
                workspace_id=workspace_id,
                name=name,
                created_at=now,
                updated_at=now,
            )
            self._items[reg.id] = reg
            self._save()
            return reg

    def get(self, reg_id: str) -> Registration | None:
        with self._lock:
            return self._items.get(reg_id)

    def authorized(self, reg_id: str, secret: str) -> Registration | None:
        """The registration, if [secret] is its secret."""
        reg = self.get(reg_id)
        if reg is None or not secrets.compare_digest(_hash(reg.secret), _hash(secret)):
            return None
        return reg

    def update(self, reg_id: str, **fields) -> Registration | None:
        with self._lock:
            reg = self._items.get(reg_id)
            if reg is None:
                return None
            for key, value in fields.items():
                setattr(reg, key, value)
            reg.updated_at = time.time()
            self._save()
            return reg

    def touch(self, reg_id: str, *, validated: bool = False, event: bool = False) -> None:
        with self._lock:
            reg = self._items.get(reg_id)
            if reg is None:
                return
            now = time.time()
            if validated and reg.validated_at is None:
                reg.validated_at = now
            if event:
                reg.last_event_at = now
            self._save()

    def remove(self, reg_id: str) -> bool:
        with self._lock:
            removed = self._items.pop(reg_id, None) is not None
            if removed:
                self._save()
            return removed

    def remove_token(self, token: str) -> int:
        with self._lock:
            ids = [r.id for r in self._items.values() if r.token == token]
            for reg_id in ids:
                del self._items[reg_id]
            if ids:
                self._save()
            return len(ids)

    def expire_unvalidated(self, now: float | None = None) -> int:
        now = time.time() if now is None else now
        with self._lock:
            ids = [r.id for r in self._items.values() if r.validated_at is None and now - r.created_at > UNVALIDATED_TTL]
            for reg_id in ids:
                del self._items[reg_id]
            if ids:
                self._save()
            return len(ids)

    def expire_inactive(self, now: float | None = None) -> int:
        now = time.time() if now is None else now
        with self._lock:
            ids = [
                r.id
                for r in self._items.values()
                if now - max(r.created_at, r.updated_at, r.last_event_at or 0) > INACTIVE_TTL
            ]
            for reg_id in ids:
                del self._items[reg_id]
            if ids:
                self._save()
            return len(ids)

    def all(self) -> list[Registration]:
        with self._lock:
            return list(self._items.values())

    def last_event_at(self) -> float | None:
        with self._lock:
            return max((r.last_event_at for r in self._items.values() if r.last_event_at), default=None)

    def _save(self) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        data = {"registrations": [asdict(r) for r in self._items.values()]}
        fd, tmp = tempfile.mkstemp(dir=self._path.parent, prefix=".registrations-")
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=1)
        os.chmod(tmp, 0o600)
        os.replace(tmp, self._path)
