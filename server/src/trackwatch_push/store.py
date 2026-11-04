"""Registered phones, kept in a small JSON file."""

from __future__ import annotations

import json
import os
import tempfile
import threading
import time
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass
class Device:
    token: str
    user_id: int
    workspace_id: int | None = None
    name: str = ""
    registered_at: float = 0.0


class DeviceStore:
    def __init__(self, path: Path):
        self._path = path
        self._lock = threading.Lock()
        self._devices: dict[str, Device] = {}
        self.last_event_at: float | None = None
        if path.exists():
            raw = json.loads(path.read_text() or "{}")
            self._devices = {d["token"]: Device(**d) for d in raw.get("devices", [])}
            self.last_event_at = raw.get("last_event_at")

    def register(self, device: Device) -> None:
        with self._lock:
            device.registered_at = time.time()
            self._devices[device.token] = device
            self._save()

    def remove(self, token: str) -> bool:
        with self._lock:
            removed = self._devices.pop(token, None) is not None
            if removed:
                self._save()
            return removed

    def for_user(self, user_id: int | None) -> list[Device]:
        with self._lock:
            return [d for d in self._devices.values() if user_id is not None and d.user_id == user_id]

    def all(self) -> list[Device]:
        with self._lock:
            return list(self._devices.values())

    def event_received(self) -> None:
        with self._lock:
            self.last_event_at = time.time()
            self._save()

    def _save(self) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        data = {"devices": [asdict(d) for d in self._devices.values()], "last_event_at": self.last_event_at}
        fd, tmp = tempfile.mkstemp(dir=self._path.parent, prefix=".devices-")
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=1)
        os.replace(tmp, self._path)
