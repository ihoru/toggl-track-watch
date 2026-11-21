"""Firebase Cloud Messaging HTTP v1 sender."""

from __future__ import annotations

import asyncio
import enum
import logging
from typing import Protocol

import aiohttp

log = logging.getLogger(__name__)

SCOPE = "https://www.googleapis.com/auth/firebase.messaging"


class SendResult(enum.Enum):
    OK = "ok"
    UNREGISTERED = "unregistered"  # The app was uninstalled or the token is no longer valid: forget it.
    FAILED = "failed"


class Sender(Protocol):
    async def send(self, token: str, data: dict[str, str]) -> SendResult: ...


def message(token: str, data: dict[str, str]) -> dict:
    return {
        "message": {
            "token": token,
            "data": data,
            # High priority wakes the phone from Doze, so the watch updates right away. Each change is
            # its own message (no collapse key): the phone compares every entry with what it knows.
            "android": {"priority": "HIGH", "ttl": "86400s"},
        }
    }


class FcmSender:
    """Sends data messages with a Firebase service account (GOOGLE_APPLICATION_CREDENTIALS)."""

    def __init__(self, credentials_file: str, project_id: str | None, session: aiohttp.ClientSession):
        from google.oauth2 import service_account

        self._credentials = service_account.Credentials.from_service_account_file(credentials_file, scopes=[SCOPE])
        self.project_id = project_id or self._credentials.project_id
        if not self.project_id:
            raise ValueError("Set FIREBASE_PROJECT_ID: the service account file has no project_id")
        self._session = session
        self._lock = asyncio.Lock()

    async def _access_token(self) -> str:
        async with self._lock:
            if not self._credentials.valid:
                from google.auth.transport.requests import Request

                await asyncio.get_running_loop().run_in_executor(None, self._credentials.refresh, Request())
            return self._credentials.token

    async def send(self, token: str, data: dict[str, str]) -> SendResult:
        url = f"https://fcm.googleapis.com/v1/projects/{self.project_id}/messages:send"
        headers = {"Authorization": f"Bearer {await self._access_token()}"}
        try:
            async with self._session.post(url, json=message(token, data), headers=headers, timeout=aiohttp.ClientTimeout(total=15)) as r:
                if r.status == 200:
                    return SendResult.OK
                body = await r.text()
        except (aiohttp.ClientError, asyncio.TimeoutError) as e:
            log.warning("FCM request failed: %s", e)
            return SendResult.FAILED
        if r.status == 404 or "UNREGISTERED" in body or (r.status == 400 and "registration token" in body.lower()):
            return SendResult.UNREGISTERED
        log.warning("FCM error %s: %s", r.status, body[:300])
        return SendResult.FAILED
