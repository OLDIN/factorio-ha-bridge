"""FactorioCore without Home Assistant."""

from custom_components.factorio.core import FactorioCore, build_config
from custom_components.factorio.providers.base import ProviderMessage

STATE = {
    "v": 1, "game_state": "running", "game_state_reason": None,
    "game_state_since": "2026-11-11T10:00:00+00:00", "tick": 300,
    "players_online": 2, "data": {"players": {"online": ["guest", "alice"]}},
}


def feed(core: FactorioCore, kind: str, payload) -> None:
    core.handle_message(ProviderMessage(kind=kind, payload=payload))


def test_running_when_online():
    core = FactorioCore("main")
    feed(core, "availability", "online")
    feed(core, "state", STATE)
    assert core.relay_online is True
    assert core.game_state == "running"
    assert core.game_state_since == "2026-11-11T10:00:00+00:00"


def test_no_connection_keeps_last_values():
    core = FactorioCore("main")
    feed(core, "availability", "online")
    feed(core, "state", STATE)
    feed(core, "availability", "offline")
    assert core.game_state == "no_connection"
    assert core.players_online == 2
    assert core.players == ["guest", "alice"]


def test_nothing_known_yet():
    core = FactorioCore("main")
    assert (core.relay_online, core.game_state, core.players_online, core.players) == (None, None, None, None)


def test_players_none_when_category_absent():
    core = FactorioCore("main")
    feed(core, "state", {**STATE, "data": {}})
    assert core.players is None


def test_paused_reason():
    core = FactorioCore("main")
    feed(core, "availability", "online")
    feed(core, "state", {**STATE, "game_state": "paused", "game_state_reason": "no_players"})
    assert (core.game_state, core.game_state_reason) == ("paused", "no_players")


def test_mod_version_from_hello():
    core = FactorioCore("main")
    feed(core, "hello", {"v": 1, "server_id": "main", "relay_version": "0.1.0", "mod_version": "0.1.0"})
    assert core.mod_version == "0.1.0"


def test_event_reaches_event_listeners():
    core = FactorioCore("main")
    got = []
    core.add_event_listener(lambda name, data: got.append((name, data)))
    feed(core, "event", {"v": 1, "event": "player_joined", "tick": 9, "time": "t", "data": {"player": "guest"}})
    assert got == [("player_joined", {"player": "guest"})]


def test_malformed_payloads_ignored():
    core = FactorioCore("main")
    calls = []
    core.add_listener(lambda: calls.append(1))
    feed(core, "state", "not a dict")
    feed(core, "event", {"no": "name"})
    assert (core.game_state, calls) == (None, [])


def test_listeners_notified_on_change_and_unsubscribe_works():
    core = FactorioCore("main")
    calls = []
    unsubscribe = core.add_listener(lambda: calls.append(1))
    feed(core, "availability", "online")
    feed(core, "state", STATE)
    unsubscribe()
    feed(core, "availability", "offline")
    assert calls == [1, 1]


def test_build_config_defaults_on():
    assert build_config({}) == {"v": 1, "categories": {"players": True}}
    assert build_config({"players": False}) == {"v": 1, "categories": {"players": False}}
