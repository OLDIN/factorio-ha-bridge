from factorio_ha_relay.protocol import parse_mod_message
from factorio_ha_relay.state import StateStore


def msg(raw: str):
    return parse_mod_message(raw.encode())


def test_heartbeat_updates_players_and_tick():
    s = StateStore()
    s.apply(msg('{"v":1,"type":"heartbeat","tick":300,"players_online":2}'))
    assert (s.players_online, s.tick) == (2, 300)


def test_hello_sets_mod_version():
    s = StateStore()
    s.apply(msg('{"v":1,"type":"hello","tick":1,"mod_version":"0.1.0"}'))
    assert s.mod_version == "0.1.0"


def test_update_replaces_only_present_categories():
    s = StateStore()
    s.apply(msg('{"v":1,"type":"snapshot","tick":1,"data":{"players":{"online":["a"]},"x":{"k":1}}}'))
    s.apply(msg('{"v":1,"type":"update","tick":2,"data":{"players":{"online":["a","b"]}}}'))
    assert s.data == {"players": {"online": ["a", "b"]}, "x": {"k": 1}}


def test_snapshot_replaces_all_categories():
    s = StateStore()
    s.apply(msg('{"v":1,"type":"snapshot","tick":1,"data":{"players":{"online":["a"]}}}'))
    s.apply(msg('{"v":1,"type":"snapshot","tick":2,"data":{}}'))
    assert s.data == {}


def test_event_does_not_change_state():
    s = StateStore()
    s.apply(msg('{"v":1,"type":"event","tick":5,"event":"player_joined","data":{"player":"g"}}'))
    assert (s.players_online, s.data) == (None, {})


def test_public_state_shape():
    s = StateStore()
    s.apply(msg('{"v":1,"type":"heartbeat","tick":300,"players_online":1}'))
    assert s.public_state("running", None, "2026-11-11T10:00:00+00:00") == {
        "v": 1,
        "game_state": "running",
        "game_state_reason": None,
        "game_state_since": "2026-11-11T10:00:00+00:00",
        "tick": 300,
        "players_online": 1,
        "data": {},
    }
