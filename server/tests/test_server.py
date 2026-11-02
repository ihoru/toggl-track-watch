import asyncio
import json

import pytest

from trackwatch_push import toggl
from trackwatch_push.app import Config, make_app
from trackwatch_push.fcm import SendResult, message
from trackwatch_push.store import Device, DeviceStore

WEBHOOK_SECRET = "webhook-secret"
APP_SECRET = "app-secret"
AUTH = {"Authorization": f"Bearer {APP_SECRET}"}

STOP_EVENT = {
    "event_id": 1,
    "created_at": "2026-11-02T12:00:00Z",
    "creator_id": 7,
    "metadata": {
        "action": "updated",
        "model": "time_entry",
        "path": "/api/v9/workspaces/42/time_entries/99/stop",
        "request_type": "PATCH",
        "workspace_id": "42",
        "event_user_id": "7",
    },
    "payload": {
        "id": 99,
        "workspace_id": 42,
        "user_id": 7,
        "description": "Writing",
        "project_id": None,
        "start": "2026-11-02T11:00:00Z",
        "stop": "2026-11-02T12:00:00Z",
        "duration": 3600,
        "tags": ["x"],
        "server_deleted_at": None,
    },
    "subscription_id": 5,
}


class FakeSender:
    def __init__(self, result=SendResult.OK):
        self.result = result
        self.sent = []

    async def send(self, token, data):
        self.sent.append((token, data))
        return self.result


@pytest.fixture
def store(tmp_path):
    return DeviceStore(tmp_path / "devices.json")


@pytest.fixture
def sender():
    return FakeSender()


@pytest.fixture
async def client(aiohttp_client, store, sender):
    return await aiohttp_client(make_app(Config(WEBHOOK_SECRET, APP_SECRET), store, sender))


async def post_event(client, event, secret=WEBHOOK_SECRET):
    body = json.dumps(event).encode()
    return await client.post("/toggl/webhook", data=body, headers={toggl.SIGNATURE_HEADER: toggl.sign(secret, body)})


async def settle():
    for _ in range(5):
        await asyncio.sleep(0)


def test_signature():
    body = b'{"a":1}'
    assert toggl.verify_signature("s", body, toggl.sign("s", body))
    assert not toggl.verify_signature("s", body, toggl.sign("other", body))
    assert not toggl.verify_signature("s", body, None)
    assert not toggl.verify_signature("s", body, "md5=abc")


def test_parse_stop_event():
    event = toggl.parse_event(STOP_EVENT)
    assert isinstance(event, toggl.TimeEntryEvent)
    assert (event.action, event.user_id, event.workspace_id) == ("updated", 7, 42)
    data = event.fcm_data()
    assert data["kind"] == "time_entry" and data["action"] == "updated"
    entry = json.loads(data["entry"])
    assert entry["stop"] == "2026-11-02T12:00:00Z" and "tags" not in entry


def test_parse_deleted_and_other_events():
    deleted = {**STOP_EVENT, "payload": {**STOP_EVENT["payload"], "server_deleted_at": "2026-11-02T12:01:00Z"}}
    assert toggl.parse_event(deleted).action == "deleted"
    project = {"metadata": {"model": "project", "action": "created"}, "payload": {"id": 1}}
    assert isinstance(toggl.parse_event(project), toggl.OtherEvent)
    assert toggl.parse_event({"payload": "ping", "validation_code": "abc"}) == toggl.Ping("abc")
    with pytest.raises(ValueError):
        toggl.parse_event([1])


def test_long_descriptions_are_cut():
    long = {**STOP_EVENT, "payload": {**STOP_EVENT["payload"], "description": "x" * 5000}}
    entry = json.loads(toggl.parse_event(long).fcm_data()["entry"])
    assert len(entry["description"]) == toggl.MAX_DESCRIPTION


def test_fcm_message_is_high_priority_data():
    m = message("tok", {"kind": "time_entry"})["message"]
    assert m["token"] == "tok" and m["data"] == {"kind": "time_entry"}
    assert m["android"]["priority"] == "HIGH" and "notification" not in m


async def test_ping_answers_validation_code(client):
    r = await post_event(client, {"payload": "ping", "validation_code": "code-1"})
    assert r.status == 200 and await r.json() == {"validation_code": "code-1"}


async def test_rejects_bad_signature(client, sender, store):
    store.register(Device("tok", 7))
    r = await post_event(client, STOP_EVENT, secret="wrong")
    assert r.status == 401
    r = await client.post("/toggl/webhook", data=json.dumps(STOP_EVENT))
    assert r.status == 401
    await settle()
    assert sender.sent == []


async def test_event_goes_to_the_users_devices_only(client, sender, store):
    store.register(Device("mine", 7))
    store.register(Device("someone-else", 8))
    r = await post_event(client, STOP_EVENT)
    assert r.status == 200
    await settle()
    assert [t for t, _ in sender.sent] == ["mine"]
    assert store.last_event_at is not None


async def test_unregistered_tokens_are_forgotten(client, sender, store):
    sender.result = SendResult.UNREGISTERED
    store.register(Device("gone", 7))
    await post_event(client, STOP_EVENT)
    await settle()
    assert store.all() == []


async def test_register_needs_the_app_secret(client, store):
    r = await client.post("/devices", json={"token": "t", "user_id": 7})
    assert r.status == 401
    r = await client.post("/devices", json={"token": "t", "user_id": 7}, headers={"Authorization": "Bearer nope"})
    assert r.status == 401
    assert store.all() == []


async def test_register_and_unregister(client, store, tmp_path):
    r = await client.post("/devices", json={"token": "t", "user_id": 7, "workspace_id": 42, "name": "Pixel"}, headers=AUTH)
    assert r.status == 200
    assert [(d.token, d.user_id, d.workspace_id, d.name) for d in store.all()] == [("t", 7, 42, "Pixel")]
    # Persisted across restarts.
    assert [d.token for d in DeviceStore(tmp_path / "devices.json").all()] == ["t"]

    r = await client.post("/devices", json={"token": "t"}, headers=AUTH)
    assert r.status == 400
    r = await client.post("/devices", data="nope", headers=AUTH)
    assert r.status == 400

    r = await client.delete("/devices", json={"token": "t"}, headers=AUTH)
    assert (await r.json())["removed"] is True
    assert store.all() == []


async def test_health(client):
    r = await client.get("/health")
    assert (await r.json())["ok"] is True
