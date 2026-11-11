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
    """Final review (re-graded): seed from the retained state once MQTT is reachable, before on_connected."""
    await _wait_broker(broker_port)
    sid = uuid.uuid4().hex[:6]
    first = MqttOutput(_settings(broker_port, sid))
    task = await _started(first, _noop)
    state = {"v": 1, "game_state": "running", "players_online": 2}
    await first.publish_state(state)
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
        assert order == [("seed", state), "connected"]
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
