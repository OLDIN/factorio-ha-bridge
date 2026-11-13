import json

import pytest

from factorio_ha_relay import __version__
from factorio_ha_relay.config import Settings
from factorio_ha_relay.rcon import RconError
from factorio_ha_relay.relay import Relay, parse_game_version

ON = {"v": 1, "categories": {"players": True}}
ON_CMD = '/factorio-ha-config {"v":1,"categories":{"players":true}}'
OFF_CMD = '/factorio-ha-config {"v":1,"categories":{}}'


class FakeOutput:
    def __init__(self):
        self.hello, self.state, self.event, self.data, self.tick = [], [], [], [], []

    async def publish_hello(self, hello):
        self.hello.append(hello)

    async def publish_state(self, state):
        self.state.append(state)

    async def publish_event(self, event):
        self.event.append(event)

    async def publish_data(self, category, payload):
        self.data.append((category, payload))

    async def publish_tick(self, tick):
        self.tick.append(tick)


class FakeRcon:
    def __init__(self, alive=True):
        self.alive = alive
        self.commands = []
        self.fail = False
        self.fail_commands: set[str] = set()
        self.answers: dict[str, str] = {}

    async def exec(self, command, timeout=5.0):
        self.commands.append(command)
        if self.fail or command in self.fail_commands:
            raise RconError("no answer")
        return self.answers.get(command, "ok")


def sent_configs(rcon) -> list[str]:
    """Only the config commands (a connect also asks for /version)."""
    return [c for c in rcon.commands if c.startswith("/factorio-ha-config")]


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
    relay, output, rcon, clock = env
    rcon.alive = False
    clock.t += 16  # past the startup grace period
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
    assert sent_configs(rcon) == [ON_CMD]


async def test_config_resent_on_hello_and_rcon_reconnect(env):
    relay, _, rcon, _ = env
    await relay.on_config(ON)
    await relay.process_datagram(dg({"type": "hello", "tick": 1, "mod_version": "0.1.0"}))
    await relay.on_rcon_connected()
    assert sent_configs(rcon) == [ON_CMD, ON_CMD, ON_CMD]


async def test_no_config_nothing_sent_on_hello(env):
    relay, _, rcon, _ = env
    await relay.process_datagram(dg({"type": "hello", "tick": 1, "mod_version": "0.1.0"}))
    assert rcon.commands == []


async def test_hello_published_with_mod_version(env):
    relay, output, _, _ = env
    await relay.process_datagram(dg({"type": "hello", "tick": 1, "mod_version": "0.1.0"}))
    assert output.hello[-1] == {"v": 1, "server_id": "t1", "relay_version": __version__, "mod_version": "0.1.0",
                                "game_version": None}


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


SEEDED = {"v": 1, "game_state": "running", "game_state_reason": None,
          "game_state_since": "2026-11-11T09:00:00+00:00", "tick": 50,
          "players_online": 1, "data": {"players": {"online": ["alice"]}}}


async def test_startup_grace_keeps_seeded_state(env):
    """Final review #2: real startup order (RCON down, then up, then heartbeat) must not flap."""
    relay, output, rcon, clock = env
    relay.seed(SEEDED)
    rcon.alive = False
    await relay.evaluate()
    rcon.alive = True
    clock.t += 2
    await relay.on_rcon_connected()
    clock.t += 1
    await relay.process_datagram(dg({"type": "heartbeat", "tick": 60, "players_online": 1}))
    assert {(s["game_state"], s["game_state_since"]) for s in output.state} == {
        ("running", "2026-11-11T09:00:00+00:00")}


async def test_startup_grace_ends_with_real_state(env):
    relay, output, _, clock = env
    relay.seed(SEEDED)
    clock.t += 16
    await relay.evaluate()
    assert (output.state[-1]["game_state"], output.state[-1]["game_state_reason"]) == ("paused", "unknown")
    assert output.state[-1]["game_state_since"] != "2026-11-11T09:00:00+00:00"


async def test_fresh_start_publishes_nothing_during_grace(env):
    relay, output, rcon, clock = env
    rcon.alive = False
    await relay.evaluate()
    assert output.state == []
    clock.t += 16
    await relay.evaluate()
    assert output.state[-1]["game_state"] == "stopped"


async def test_late_seed_fills_only_empty_fields(env):
    """Broker came up after the relay: the retained state must not override fresh data."""
    relay, output, _, _ = env
    await relay.process_datagram(dg({"type": "heartbeat", "tick": 300, "players_online": 0}))
    relay.seed({**SEEDED, "players_online": 3, "game_state": "paused"})
    await relay.on_output_connected()
    state = output.state[-1]
    assert (state["players_online"], state["game_state"]) == (0, "running")
    assert state["data"] == {"players": {"online": ["alice"]}}


async def test_seed_hello_restores_mod_version(env):
    """After a relay restart on a paused game the mod's hello may not come for a long time."""
    relay, output, _, _ = env
    relay.seed_hello({"v": 1, "server_id": "t1", "relay_version": "0.1.0", "mod_version": "0.1.0"})
    await relay.on_output_connected()
    assert output.hello[-1]["mod_version"] == "0.1.0"


async def test_seed_hello_does_not_override_live_version(env):
    relay, output, _, _ = env
    await relay.process_datagram(dg({"type": "hello", "tick": 1, "mod_version": "0.2.0"}))
    relay.seed_hello({"mod_version": "0.1.0"})
    await relay.on_output_connected()
    assert output.hello[-1]["mod_version"] == "0.2.0"


async def test_periodic_hello_does_not_resend_config(env):
    relay, _, rcon, _ = env
    await relay.on_config(ON)
    await relay.process_datagram(dg({"type": "hello", "tick": 1, "mod_version": "0.2.0", "reason": "periodic"}))
    assert rcon.commands == [ON_CMD]


async def test_init_hello_resends_config(env):
    relay, _, rcon, _ = env
    await relay.on_config(ON)
    await relay.process_datagram(dg({"type": "hello", "tick": 1, "mod_version": "0.2.0", "reason": "init"}))
    assert rcon.commands == [ON_CMD, ON_CMD]


async def test_hello_without_reason_resends_config(env):
    relay, _, rcon, _ = env
    await relay.on_config(ON)
    await relay.process_datagram(dg({"type": "hello", "tick": 1, "mod_version": "0.1.0"}))
    assert rcon.commands == [ON_CMD, ON_CMD]


async def test_changed_category_published_once(env):
    relay, output, _, _ = env
    snap = {"type": "snapshot", "tick": 10, "data": {"research": {"queue": ["a"]}}}
    await relay.process_datagram(dg(snap))
    await relay.process_datagram(dg({**snap, "tick": 20}))
    assert output.data == [("research", {"v": 1, "tick": 10, "data": {"queue": ["a"]}})]


async def test_removed_category_published_as_none(env):
    relay, output, _, _ = env
    await relay.process_datagram(dg({"type": "snapshot", "tick": 10, "data": {"research": {"queue": []}}}))
    await relay.process_datagram(dg({"type": "snapshot", "tick": 20, "data": {}}))
    assert output.data[-1] == ("research", None)


async def test_multipart_snapshot_applied_when_complete(env):
    relay, output, _, _ = env
    await relay.process_datagram(dg({"type": "snapshot", "tick": 9, "part": 1, "parts": 2,
                                     "data": {"planets": {"bodies": []}}}))
    assert output.data == []
    await relay.process_datagram(dg({"type": "snapshot", "tick": 9, "part": 2, "parts": 2,
                                     "data": {"research": {"queue": []}}}))
    assert {c for c, _ in output.data} == {"planets", "research"}


async def test_bad_category_name_skipped(env):
    relay, output, _, _ = env
    await relay.process_datagram(dg({"type": "snapshot", "tick": 10,
                                     "data": {"Bad/Name": {"a": 1}, "research": {"queue": []}}}))
    assert [c for c, _ in output.data] == ["research"]


async def test_seed_data_does_not_override_fresh(env):
    relay, output, _, _ = env
    await relay.process_datagram(dg({"type": "snapshot", "tick": 10, "data": {"research": {"queue": ["new"]}}}))
    relay.seed_data({"research": {"queue": ["old"]}, "planets": {"bodies": []}})
    await relay.on_output_connected()
    published = dict(output.data)
    assert published["research"]["data"] == {"queue": ["new"]}
    assert published["planets"]["data"] == {"bodies": []}


async def test_heartbeat_publishes_game_clock(env):
    relay, output, _, _ = env
    await relay.process_datagram(dg({"type": "heartbeat", "tick": 600, "players_online": 1}))
    assert output.tick == [{"v": 1, "tick": 600}]
    await relay.process_datagram(dg({"type": "heartbeat", "tick": 900, "players_online": 1}))
    assert output.tick == [{"v": 1, "tick": 600}, {"v": 1, "tick": 900}]


async def test_other_messages_do_not_publish_game_clock(env):
    relay, output, _, _ = env
    await relay.process_datagram(dg({"type": "hello", "tick": 1, "mod_version": "0.1.0"}))
    await relay.process_datagram(dg({"type": "snapshot", "tick": 2, "data": {"players": {"online": ["a"]}}}))
    await relay.process_datagram(dg({"type": "update", "tick": 3, "data": {"players": {"online": ["b"]}}}))
    await relay.process_datagram(
        dg({"type": "event", "tick": 4, "event": "player_joined", "data": {"player": "guest"}}))
    assert output.tick == []


# --- server health: UPS, server start, game version ------------------------------------------


async def beat(relay, tick, players=1):
    await relay.process_datagram(dg({"type": "heartbeat", "tick": tick, "players_online": players}))


async def beats(relay, clock, *, tick, seconds, every=5, step=300, players=1):
    """Heartbeats every `every` s for `seconds` s after the current one; returns the last tick."""
    elapsed = 0
    while elapsed < seconds:
        clock.t += every
        elapsed += every
        tick += step
        await beat(relay, tick, players)
    return tick


async def test_ups_in_state_after_30s(env):
    relay, output, _, clock = env
    await beat(relay, 3000)
    tick = await beats(relay, clock, tick=3000, seconds=25)
    assert output.state[-1]["ups"] is None
    await beats(relay, clock, tick=tick, seconds=5)
    assert output.state[-1]["ups"] == 60.0


async def test_ups_published_at_most_once_a_minute(env):
    relay, output, _, clock = env
    await beat(relay, 3000)
    tick = await beats(relay, clock, tick=3000, seconds=30)
    assert output.state[-1]["ups"] == 60.0
    published = len(output.state)
    tick = await beats(relay, clock, tick=tick, seconds=55)
    assert len(output.state) == published  # same speed, within the minute: nothing new
    await beats(relay, clock, tick=tick, seconds=10, step=150)  # slower from here
    assert len(output.state) == published + 1
    assert output.state[-1]["ups"] == 57.5  # the minute 30..90 s: 3450 ticks


async def test_ups_null_when_paused(env):
    relay, output, _, clock = env
    await beat(relay, 3000, players=0)
    await beats(relay, clock, tick=3000, seconds=35, players=0)
    assert output.state[-1]["ups"] == 60.0
    clock.t += 20
    await relay.evaluate()
    assert output.state[-1]["game_state"] == "paused"
    assert output.state[-1]["ups"] is None


async def test_slow_server_keeps_ups(env):
    relay, output, _, clock = env
    tick = 3000
    await beat(relay, tick)
    for _ in range(4):  # a heartbeat every 30 s (300 ticks): 10 UPS
        for _ in range(29):
            clock.t += 1
            await relay.evaluate()
        clock.t += 1
        tick += 300
        await beat(relay, tick)
    clock.t += 20
    await relay.evaluate()
    assert (output.state[-1]["game_state"], output.state[-1]["game_state_reason"]) == ("paused", "unknown")
    assert output.state[-1]["ups"] == 10.0


async def test_ups_null_after_a_minute_silent(env):
    relay, output, _, clock = env
    await beat(relay, 3000)
    await beats(relay, clock, tick=3000, seconds=35)
    assert output.state[-1]["ups"] == 60.0
    clock.t += 61
    await relay.evaluate()
    assert output.state[-1]["ups"] is None


def health_env():
    """A relay with a wall clock the test sets: wall[0] is what utcnow returns."""
    clock, output, rcon = Clock(), FakeOutput(), FakeRcon()
    wall = ["2026-11-13T06:00:00+00:00"]
    relay = Relay(Settings(server_id="t1", rcon_password="x"), output, rcon,
                  monotonic=lambda: clock.t, utcnow=lambda: wall[0])
    return relay, output, rcon, wall


async def test_rcon_connect_sets_server_started_and_version():
    relay, output, rcon, wall = health_env()
    rcon.answers["/version"] = "2.0.72"
    await beat(relay, 300)
    wall[0] = "2026-11-13T07:00:00+00:00"
    await relay.on_rcon_connected()
    assert "/version" in rcon.commands
    assert output.hello[-1]["game_version"] == "2.0.72"
    assert output.state[-1]["server_started"] == "2026-11-13T07:00:00+00:00"


async def test_rcon_reconnect_updates_started_and_version():
    relay, output, rcon, wall = health_env()
    rcon.answers["/version"] = "2.0.72"
    await beat(relay, 300)
    wall[0] = "2026-11-13T07:00:00+00:00"
    await relay.on_rcon_connected()
    assert output.state[-1]["server_started"] == "2026-11-13T07:00:00+00:00"
    rcon.answers["/version"] = "Version: 2.0.73 (build 1, linux64, headless)"  # the game was updated
    wall[0] = "2026-11-13T09:00:00+00:00"
    await relay.on_rcon_connected()
    assert [h["game_version"] for h in output.hello] == ["2.0.72", "2.0.73"]
    assert output.state[-1]["server_started"] == "2026-11-13T09:00:00+00:00"


async def test_version_failure_keeps_going(env):
    relay, output, rcon, _ = env
    await relay.on_config(ON)
    rcon.fail_commands.add("/version")
    await relay.on_rcon_connected()
    assert sent_configs(rcon) == [ON_CMD, ON_CMD]
    await relay.on_output_connected()
    assert output.hello[-1]["game_version"] is None


async def test_server_started_null_without_rcon(env):
    relay, output, rcon, clock = env
    await beat(relay, 300)
    await relay.on_rcon_connected()
    assert output.state[-1]["server_started"] is not None
    rcon.alive = False
    clock.t += 16
    await relay.evaluate()
    assert output.state[-1]["game_state"] == "stopped"
    assert output.state[-1]["server_started"] is None


async def test_seed_ignores_server_started(env):
    relay, output, _, _ = env
    relay.seed({**SEEDED, "server_started": "2020-01-01T00:00:00+00:00", "ups": 59.9})
    await relay.on_output_connected()
    assert output.state[-1]["server_started"] is None
    assert output.state[-1]["ups"] is None


def test_parse_game_version():
    assert parse_game_version("2.0.72") == "2.0.72"
    assert parse_game_version("Version: 2.0.72 (build 82645, linux64, headless)") == "2.0.72"
    assert parse_game_version("") is None
    assert parse_game_version("Unknown command") is None
