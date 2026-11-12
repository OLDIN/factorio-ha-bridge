"""MqttOutput against a real Mosquitto in Docker (skipped when Docker is unavailable)."""

import asyncio
import json
import shutil
import subprocess
import uuid

import aiomqtt
import pytest

from factorio_ha_relay.config import Settings
from factorio_ha_relay.outputs.mqtt import MqttOutput


def _docker_ok() -> bool:
    if not shutil.which("docker"):
        return False
    return subprocess.run(["docker", "info"], capture_output=True).returncode == 0


pytestmark = pytest.mark.skipif(not _docker_ok(), reason="docker unavailable")


@pytest.fixture(scope="module")
def broker_port():
    name = f"fha-test-{uuid.uuid4().hex[:8]}"
    subprocess.run(
        ["docker", "run", "-d", "--rm", "--name", name, "-p", "127.0.0.1::1883",
         "eclipse-mosquitto:2", "mosquitto", "-c", "/mosquitto-no-auth.conf"],
        check=True, capture_output=True,
    )
    try:
        out = subprocess.run(["docker", "port", name, "1883/tcp"], check=True,
                             capture_output=True, text=True).stdout
        port = int(out.strip().splitlines()[0].rsplit(":", 1)[1])
        yield port
    finally:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True)


async def _wait_broker(port: int) -> None:
    for _ in range(100):
        try:
            async with aiomqtt.Client("127.0.0.1", port):
                return
        except aiomqtt.MqttError:
            await asyncio.sleep(0.1)
    raise AssertionError("broker did not start")


def _settings(port: int, server_id: str) -> Settings:
    return Settings(server_id=server_id, rcon_password="x", mqtt_host="127.0.0.1", mqtt_port=port)


async def _started(output: MqttOutput, on_config):
    connected = asyncio.Event()

    async def on_connected():
        connected.set()

    task = asyncio.create_task(output.start(on_config, on_connected))
    await asyncio.wait_for(connected.wait(), 5)
    return task


async def _noop(_cfg):
    return None


async def test_state_retained_and_read_back(broker_port):
    await _wait_broker(broker_port)
    sid = uuid.uuid4().hex[:6]
    out = MqttOutput(_settings(broker_port, sid))
    task = await _started(out, _noop)
    state = {"v": 1, "game_state": "running", "players_online": 1}
    await out.publish_state(state)
    try:
        async with aiomqtt.Client("127.0.0.1", broker_port) as client:
            await client.subscribe(f"factorio/{sid}/state")
            msg = await asyncio.wait_for(anext(aiter(client.messages)), 5)
            assert msg.retain and json.loads(msg.payload) == state
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)


async def test_availability_online_retained(broker_port):
    await _wait_broker(broker_port)
    sid = uuid.uuid4().hex[:6]
    task = await _started(MqttOutput(_settings(broker_port, sid)), _noop)
    try:
        async with aiomqtt.Client("127.0.0.1", broker_port) as client:
            await client.subscribe(f"factorio/{sid}/availability")
            msg = await asyncio.wait_for(anext(aiter(client.messages)), 5)
            assert msg.payload == b"online"
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)


async def test_no_seed_when_nothing_retained(broker_port):
    await _wait_broker(broker_port)
    seeds: list = []
    connected = asyncio.Event()

    async def on_connected():
        connected.set()

    out = MqttOutput(_settings(broker_port, uuid.uuid4().hex[:6]))
    task = asyncio.create_task(out.start(_noop, on_connected, seeds.append))
    try:
        await asyncio.wait_for(connected.wait(), 10)
        assert seeds == []
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)


async def test_config_delivered_and_cleared(broker_port):
    await _wait_broker(broker_port)
    sid = uuid.uuid4().hex[:6]
    configs: list = []

    async def on_config(cfg):
        configs.append(cfg)

    task = await _started(MqttOutput(_settings(broker_port, sid)), on_config)
    try:
        async with aiomqtt.Client("127.0.0.1", broker_port) as client:
            cfg = {"v": 1, "categories": {"players": True}}
            await client.publish(f"factorio/{sid}/config", json.dumps(cfg), qos=1, retain=True)
            await client.publish(f"factorio/{sid}/config", b"", qos=1, retain=True)
        for _ in range(50):
            if len(configs) >= 2:
                break
            await asyncio.sleep(0.1)
        assert configs == [cfg, None]
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)


async def test_graceful_stop_publishes_offline(broker_port):
    """docker stop -> SIGTERM -> task cancelled: a clean disconnect sends no last will."""
    await _wait_broker(broker_port)
    sid = uuid.uuid4().hex[:6]
    task = await _started(MqttOutput(_settings(broker_port, sid)), _noop)
    task.cancel()
    await asyncio.gather(task, return_exceptions=True)
    async with aiomqtt.Client("127.0.0.1", broker_port) as client:
        await client.subscribe(f"factorio/{sid}/availability")
        msg = await asyncio.wait_for(anext(aiter(client.messages)), 5)
        assert msg.payload == b"offline"


async def test_config_callback_error_does_not_kill_output(broker_port):
    """Final review #1: an exception from on_config must not tear down the MQTT loop."""
    await _wait_broker(broker_port)
    sid = uuid.uuid4().hex[:6]
    configs: list = []

    async def on_config(cfg):
        configs.append(cfg)
        if len(configs) == 1:
            raise RuntimeError("boom")

    task = await _started(MqttOutput(_settings(broker_port, sid)), on_config)
    try:
        async with aiomqtt.Client("127.0.0.1", broker_port) as client:
            await client.publish(f"factorio/{sid}/config", '{"v":1,"categories":{}}', qos=1, retain=True)
            await asyncio.sleep(0.3)
            await client.publish(f"factorio/{sid}/config", '{"v":1,"categories":{"players":true}}', qos=1, retain=True)
        for _ in range(50):
            if len(configs) >= 2:
                break
            await asyncio.sleep(0.1)
        assert len(configs) == 2
        assert not task.done()
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)


async def test_seed_delivered_on_first_connect(broker_port):
    """Seed from the retained state and hello once MQTT is reachable, before on_connected."""
    await _wait_broker(broker_port)
    sid = uuid.uuid4().hex[:6]
    first = MqttOutput(_settings(broker_port, sid))
    task = await _started(first, _noop)
    state = {"v": 1, "game_state": "running", "players_online": 2}
    hello = {"v": 1, "server_id": sid, "relay_version": "0.1.0", "mod_version": "0.1.0"}
    await first.publish_state(state)
    await first.publish_hello(hello)
    task.cancel()
    await asyncio.gather(task, return_exceptions=True)

    order: list = []
    connected = asyncio.Event()

    async def on_connected():
        order.append("connected")
        connected.set()

    second = MqttOutput(_settings(broker_port, sid))
    task = asyncio.create_task(second.start(_noop, on_connected, lambda s: order.append(("seed", s))))
    try:
        await asyncio.wait_for(connected.wait(), 5)
        assert order == [("seed", {"state": state, "hello": hello}), "connected"]
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)


async def test_data_topic_retained_and_cleared(broker_port):
    await _wait_broker(broker_port)
    sid = uuid.uuid4().hex[:6]
    out = MqttOutput(_settings(broker_port, sid))
    task = await _started(out, _noop)
    payload = {"v": 1, "tick": 5, "data": {"queue": ["a"]}}
    try:
        await out.publish_data("research", payload)
        async with aiomqtt.Client("127.0.0.1", broker_port) as client:
            await client.subscribe(f"factorio/{sid}/data/research")
            msg = await asyncio.wait_for(anext(aiter(client.messages)), 5)
            assert msg.retain and json.loads(msg.payload) == payload
        await out.publish_data("research", None)
        async with aiomqtt.Client("127.0.0.1", broker_port) as client:
            await client.subscribe(f"factorio/{sid}/data/research")
            with pytest.raises(TimeoutError):
                await asyncio.wait_for(anext(aiter(client.messages)), 1)
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)


async def test_seed_reads_data_topics(broker_port):
    await _wait_broker(broker_port)
    sid = uuid.uuid4().hex[:6]
    first = MqttOutput(_settings(broker_port, sid))
    task = await _started(first, _noop)
    await first.publish_data("research", {"v": 1, "tick": 5, "data": {"queue": ["a"]}})
    await first.publish_data("planets", {"v": 1, "tick": 5, "data": {"bodies": []}})
    await first.publish_data("gone", {"v": 1, "tick": 5, "data": {"x": 1}})
    await first.publish_data("gone", None)
    task.cancel()
    await asyncio.gather(task, return_exceptions=True)

    seeds: list = []
    connected = asyncio.Event()

    async def on_connected():
        connected.set()

    second = MqttOutput(_settings(broker_port, sid))
    task = asyncio.create_task(second.start(_noop, on_connected, seeds.append))
    try:
        await asyncio.wait_for(connected.wait(), 5)
        assert seeds == [{"data": {"research": {"queue": ["a"]}, "planets": {"bodies": []}}}]
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)


async def test_seed_read_is_bounded_and_ignores_non_retained(broker_port):
    await _wait_broker(broker_port)
    sid = uuid.uuid4().hex[:6]
    first = MqttOutput(_settings(broker_port, sid))
    task = await _started(first, _noop)
    await first.publish_state({"v": 1, "game_state": "running"})
    await first.publish_hello({"v": 1, "server_id": sid})
    task.cancel()
    await asyncio.gather(task, return_exceptions=True)

    stop = asyncio.Event()

    async def flood():
        async with aiomqtt.Client("127.0.0.1", broker_port) as pub:
            while not stop.is_set():
                await pub.publish(f"factorio/{sid}/data/x", '{"v":1,"tick":1,"data":{"k":1}}', qos=0)
                await asyncio.sleep(0.05)

    flooder = asyncio.create_task(flood())
    await asyncio.sleep(0.2)
    out = MqttOutput(_settings(broker_port, sid))
    try:
        async with out._new_client("seedtest") as client:
            started = asyncio.get_running_loop().time()
            found = await out._receive_retained(client, timeout=1.0)
            elapsed = asyncio.get_running_loop().time() - started
    finally:
        stop.set()
        await flooder
    assert elapsed < 1.4
    assert set(found) == {"state", "hello"}


async def test_tick_published_compact_not_retained(broker_port):
    await _wait_broker(broker_port)
    sid = uuid.uuid4().hex[:6]
    out = MqttOutput(_settings(broker_port, sid))
    task = await _started(out, _noop)
    try:
        async with aiomqtt.Client("127.0.0.1", broker_port) as client:
            await client.subscribe(f"factorio/{sid}/tick", qos=1)
            await out.publish_tick({"v": 1, "tick": 600})
            msg = await asyncio.wait_for(anext(aiter(client.messages)), 5)
            assert msg.payload == b'{"v":1,"tick":600}'
            assert not msg.retain
        async with aiomqtt.Client("127.0.0.1", broker_port) as late:  # nothing retained for a late subscriber
            await late.subscribe(f"factorio/{sid}/tick", qos=1)
            with pytest.raises(TimeoutError):
                await asyncio.wait_for(anext(aiter(late.messages)), 0.5)
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
