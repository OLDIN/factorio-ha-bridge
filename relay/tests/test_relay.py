import json

import pytest

from factorio_ha_relay.config import Settings
from factorio_ha_relay.rcon import RconError
from factorio_ha_relay.relay import Relay

ON = {"v": 1, "categories": {"players": True}}
ON_CMD = '/factorio-ha-config {"v":1,"categories":{"players":true}}'
OFF_CMD = '/factorio-ha-config {"v":1,"categories":{}}'


class FakeOutput:
    def __init__(self):
        self.hello, self.state, self.event = [], [], []

    async def publish_hello(self, hello):
        self.hello.append(hello)

    async def publish_state(self, state):
        self.state.append(state)

    async def publish_event(self, event):
        self.event.append(event)


class FakeRcon:
    def __init__(self, alive=True):
        self.alive = alive
        self.commands = []
        self.fail = False

    async def exec(self, command, timeout=5.0):
        self.commands.append(command)
        if self.fail:
            raise RconError("no answer")
        return "ok"


class Clock:
    def __init__(self):
        self.t = 1000.0


@pytest.fixture
def env():
    clock = Clock()
    output, rcon = FakeOutput(), FakeRcon()
    relay = Relay(Settings(server_id="t1", rcon_password="x"), output, rcon, monotonic=lambda: clock.t)
    return relay, output, rcon, clock


def dg(obj) -> bytes:
    return json.dumps({"v": 1, **obj}).encode()


async def test_heartbeat_makes_running_state(env):
    relay, output, _, _ = env
    await relay.process_datagram(dg({"type": "heartbeat", "tick": 300, "players_online": 1}))
    assert output.state[-1]["game_state"] == "running"
    assert output.state[-1]["players_online"] == 1


async def test_tick_only_change_not_published(env):
    relay, output, _, _ = env
    await relay.process_datagram(dg({"type": "heartbeat", "tick": 300, "players_online": 1}))
    await relay.process_datagram(dg({"type": "heartbeat", "tick": 600, "players_online": 1}))
    assert len(output.state) == 1


async def test_heartbeat_timeout_pauses_with_reason(env):
    relay, output, _, clock = env
    await relay.process_datagram(dg({"type": "heartbeat", "tick": 300, "players_online": 0}))
    clock.t += 16
    await relay.evaluate()
    assert (output.state[-1]["game_state"], output.state[-1]["game_state_reason"]) == ("paused", "no_players")


async def test_rcon_down_means_stopped(env):
    relay, output, rcon, _ = env
    rcon.alive = False
    await relay.evaluate()
    assert output.state[-1]["game_state"] == "stopped"


async def test_since_changes_only_with_game_state(env):
    relay, output, _, clock = env
    await relay.process_datagram(dg({"type": "heartbeat", "tick": 300, "players_online": 1}))
    since = output.state[-1]["game_state_since"]
    await relay.process_datagram(dg({"type": "update", "tick": 301, "data": {"players": {"online": ["a"]}}}))
    assert output.state[-1]["game_state_since"] == since
    assert output.state[-1]["data"] == {"players": {"online": ["a"]}}


async def test_config_forwarded_to_rcon(env):
    relay, _, rcon, _ = env
    await relay.on_config(ON)
    assert rcon.commands == [ON_CMD]


async def test_empty_config_sends_empty_categories(env):
    relay, _, rcon, _ = env
    await relay.on_config(None)
    assert rcon.commands == [OFF_CMD]


async def test_config_not_sent_while_rcon_down_then_sent_on_connect(env):
    relay, _, rcon, _ = env
    rcon.alive = False
    await relay.on_config(ON)
    assert rcon.commands == []
    rcon.alive = True
    await relay.on_rcon_connected()
    assert rcon.commands == [ON_CMD]


async def test_config_resent_on_hello_and_rcon_reconnect(env):
    relay, _, rcon, _ = env
    await relay.on_config(ON)
    await relay.process_datagram(dg({"type": "hello", "tick": 1, "mod_version": "0.1.0"}))
    await relay.on_rcon_connected()
    assert rcon.commands == [ON_CMD, ON_CMD, ON_CMD]


async def test_no_config_nothing_sent_on_hello(env):
    relay, _, rcon, _ = env
    await relay.process_datagram(dg({"type": "hello", "tick": 1, "mod_version": "0.1.0"}))
    assert rcon.commands == []


async def test_hello_published_with_mod_version(env):
    relay, output, _, _ = env
    await relay.process_datagram(dg({"type": "hello", "tick": 1, "mod_version": "0.1.0"}))
    assert output.hello[-1] == {"v": 1, "server_id": "t1", "relay_version": "0.1.0", "mod_version": "0.1.0"}


async def test_event_published_with_time(env):
    relay, output, _, _ = env
    await relay.process_datagram(dg({"type": "event", "tick": 9, "event": "player_joined", "data": {"player": "guest"}}))
    event = output.event[-1]
    assert {k: event[k] for k in ("v", "event", "tick", "data")} == {
        "v": 1, "event": "player_joined", "tick": 9, "data": {"player": "guest"}}
    assert event["time"].endswith("+00:00")


async def test_garbage_datagram_ignored(env):
    relay, output, rcon, _ = env
    await relay.process_datagram(b"\xff")
    await relay.process_datagram(dg({"type": "event", "tick": 1, "event": 5}))
    assert (output.hello, output.state, output.event, rcon.commands) == ([], [], [], [])


async def test_output_reconnect_republishes(env):
    relay, output, _, _ = env
    await relay.process_datagram(dg({"type": "heartbeat", "tick": 300, "players_online": 1}))
    await relay.on_output_connected()
    await relay.on_output_connected()
    assert len(output.hello) == 2
    assert len(output.state) == 3
    assert output.state[-1]["players_online"] == 1


async def test_seed_keeps_values_after_restart(env):
    relay, output, _, _ = env
    relay.seed({"v": 1, "game_state": "paused", "game_state_reason": "no_players",
                "game_state_since": "2026-11-11T09:00:00+00:00", "tick": 50,
                "players_online": 1, "data": {"players": {"online": ["alice"]}}})
    await relay.evaluate()
    state = output.state[-1]
    assert state["players_online"] == 1
    assert state["data"] == {"players": {"online": ["alice"]}}
    assert state["game_state"] == "paused"


async def test_seed_with_same_state_keeps_since(env):
    relay, output, _, _ = env
    relay.seed({"v": 1, "game_state": "paused", "game_state_reason": "no_players",
                "game_state_since": "2026-11-11T09:00:00+00:00", "tick": 50,
                "players_online": 0, "data": {}})
    await relay.on_output_connected()
    assert output.state[-1]["game_state_since"] == "2026-11-11T09:00:00+00:00"


async def test_config_rcon_timeout_does_not_crash(env):
    relay, _, rcon, _ = env
    rcon.fail = True
    await relay.on_config(ON)  # must not raise
