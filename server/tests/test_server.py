import asyncio
import json

import pytest

from trackwatch_push import toggl
from trackwatch_push.app import Config, RateLimiter, make_app
from trackwatch_push.fcm import SendResult, message
from trackwatch_push.store import UNVALIDATED_TTL, RegistrationStore

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
    return RegistrationStore(tmp_path / "registrations.json")


@pytest.fixture
def sender():
    return FakeSender()


@pytest.fixture
async def client(aiohttp_client, store, sender):
    return await aiohttp_client(make_app(Config(max_registrations=5, registrations_per_ip_hour=4), store, sender))


async def post_event(client, reg, event, secret=None):
    body = json.dumps(event).encode()
    headers = {toggl.SIGNATURE_HEADER: toggl.sign(secret or reg["secret"], body)}
    return await client.post(reg["webhook_path"], data=body, headers=headers)


async def register(client, token="mine", user_id=7, **extra):
    r = await client.post("/registrations", json={"token": token, "user_id": user_id, **extra})
    assert r.status == 201, await r.text()
    return await r.json()


def auth(reg):
    return {"Authorization": f"Bearer {reg['secret']}"}


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


@pytest.mark.parametrize("description", ["x" * 5000, "Щ" * 3000, "🙂" * 2000])
def test_long_descriptions_fit_in_an_fcm_message(description):
    long = {**STOP_EVENT, "payload": {**STOP_EVENT["payload"], "description": description}}
    data = toggl.parse_event(long).fcm_data()
    assert len(json.dumps(data, ensure_ascii=False).encode()) < 4096
    entry = json.loads(data["entry"])
    assert entry["description"] and description.startswith(entry["description"])


def test_short_non_latin_descriptions_are_kept():
    event = {**STOP_EVENT, "payload": {**STOP_EVENT["payload"], "description": "Работа"}}
    assert json.loads(toggl.parse_event(event).fcm_data()["entry"])["description"] == "Работа"


def test_fcm_message_is_high_priority_data():
    m = message("tok", {"kind": "time_entry"})["message"]
    assert m["token"] == "tok" and m["data"] == {"kind": "time_entry"}
    assert m["android"]["priority"] == "HIGH" and "notification" not in m


async def test_ping_answers_validation_code_and_validates(client, store):
    reg = await register(client)
    r = await client.get(f"/registrations/{reg['id']}", headers=auth(reg))
    assert (await r.json())["validated"] is False
    r = await post_event(client, reg, {"payload": "ping", "validation_code": "code-1"})
    assert r.status == 200 and await r.json() == {"validation_code": "code-1"}
    r = await client.get(f"/registrations/{reg['id']}", headers=auth(reg))
    assert (await r.json())["validated"] is True


async def test_rejects_bad_signature_and_unknown_ids(client, sender):
    reg = await register(client)
    other = await register(client, token="other")
    # Signed with another registration's secret.
    r = await post_event(client, reg, STOP_EVENT, secret=other["secret"])
    assert r.status == 401
    r = await client.post(reg["webhook_path"], data=json.dumps(STOP_EVENT))
    assert r.status == 401
    r = await post_event(client, {**reg, "webhook_path": "/toggl/webhook/nope"}, STOP_EVENT)
    assert r.status == 410
    await settle()
    assert sender.sent == []


async def test_event_goes_to_its_own_registration_and_user_only(client, sender, store):
    mine = await register(client, token="mine", user_id=7)
    await register(client, token="same-user-other-subscription", user_id=7)
    admin = await register(client, token="admin", user_id=8)
    assert (await post_event(client, mine, STOP_EVENT)).status == 200
    # The admin's subscription also gets user 7's entry; it isn't the admin's, so it isn't sent.
    assert (await post_event(client, admin, STOP_EVENT)).status == 200
    await settle()
    assert [t for t, _ in sender.sent] == ["mine"]
    assert store.get(mine["id"]).last_event_at is not None
    assert store.get(mine["id"]).validated_at is not None


async def test_unregistered_tokens_are_forgotten(client, sender, store):
    sender.result = SendResult.UNREGISTERED
    reg = await register(client)
    await post_event(client, reg, STOP_EVENT)
    await settle()
    assert store.all() == []


async def test_register_update_delete(client, store, tmp_path):
    reg = await register(client, token="t", workspace_id=42, name="Pixel")
    assert reg["webhook_path"] == f"/toggl/webhook/{reg['id']}"
    assert [(r.token, r.user_id, r.workspace_id, r.name) for r in store.all()] == [("t", 7, 42, "Pixel")]
    # Persisted across restarts.
    assert [r.token for r in RegistrationStore(tmp_path / "registrations.json").all()] == ["t"]

    path = f"/registrations/{reg['id']}"
    r = await client.put(path, json={"token": "t2", "user_id": 7}, headers=auth(reg))
    assert r.status == 200 and store.get(reg["id"]).token == "t2"
    r = await client.put(path, json={"token": "t3", "user_id": 7}, headers={"Authorization": "Bearer nope"})
    assert r.status == 404 and store.get(reg["id"]).token == "t2"
    r = await client.put(path, json={"token": "t3"}, headers=auth(reg))
    assert r.status == 400

    r = await client.delete(path, headers={"Authorization": "Bearer nope"})
    assert r.status == 404
    r = await client.delete(path, headers=auth(reg))
    assert r.status == 200 and store.all() == []


async def test_registering_again_replaces_the_old_registration(client, store):
    first = await register(client, token="t")
    second = await register(client, token="t")
    assert [r.id for r in store.all()] == [second["id"]] != [first["id"]]


async def test_bad_registrations(client, store):
    for body in ({"token": "t"}, {"token": "", "user_id": 7}, {"token": "t", "user_id": True}, [1]):
        r = await client.post("/registrations", json=body)
        assert r.status == 400
    r = await client.post("/registrations", data="nope")
    assert r.status == 400
    assert store.all() == []


async def test_registrations_are_limited_per_ip(client):
    for i in range(4):
        await register(client, token=f"t{i}")
    r = await client.post("/registrations", json={"token": "t9", "user_id": 7})
    assert r.status == 429
    # Behind a local reverse proxy, the forwarded address counts.
    r = await client.post("/registrations", json={"token": "t9", "user_id": 7}, headers={"X-Forwarded-For": "203.0.113.5"})
    assert r.status == 201


async def test_server_full(client, store):
    for i in range(5):
        store.create(f"t{i}", 7, None, "")
    r = await client.post("/registrations", json={"token": "t9", "user_id": 7})
    assert r.status == 503


def test_unvalidated_registrations_expire(store):
    old = store.create("old", 7, None, "")
    kept = store.create("validated", 7, None, "")
    store.touch(kept.id, validated=True)
    assert store.expire_unvalidated(now=old.created_at + UNVALIDATED_TTL + 1) == 1
    assert [r.token for r in store.all()] == ["validated"]


def test_rate_limiter_window():
    limiter = RateLimiter(2, window=10)
    assert limiter.allow("a", 0) and limiter.allow("a", 1) and not limiter.allow("a", 2)
    assert limiter.allow("b", 2)
    assert limiter.allow("a", 11)


async def test_health(client):
    r = await client.get("/health")
    assert (await r.json())["ok"] is True
