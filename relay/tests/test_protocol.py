import pytest

from factorio_ha_relay.protocol import ModMessage, ProtocolError, parse_mod_message


def test_parses_heartbeat():
    m = parse_mod_message(b'{"v":1,"type":"heartbeat","tick":600,"players_online":2}')
    assert isinstance(m, ModMessage)
    assert (m.type, m.tick, m.body["players_online"]) == ("heartbeat", 600, 2)


def test_body_excludes_envelope_fields():
    m = parse_mod_message(b'{"v":1,"type":"hello","tick":1,"mod_version":"0.1.0"}')
    assert m.body == {"mod_version": "0.1.0"}


def test_empty_data_list_becomes_dict():
    m = parse_mod_message(b'{"v":1,"type":"snapshot","tick":1,"data":[]}')
    assert m.body["data"] == {}


def test_empty_players_online_object_becomes_list():
    m = parse_mod_message(b'{"v":1,"type":"update","tick":1,"data":{"players":{"online":{}}}}')
    assert m.body["data"] == {"players": {"online": []}}


@pytest.mark.parametrize(
    "raw",
    [
        b"not json",
        b"\xff",
        b"[1,2]",
        b'{"v":2,"type":"hello","tick":1}',
        b'{"v":1,"type":"boom","tick":1}',
        b'{"v":1,"type":"hello"}',
        b'{"v":1,"type":"hello","tick":"1"}',
        b'{"v":1,"type":"snapshot","tick":1,"data":"x"}',
        b'{"v":1,"type":"he',
    ],
)
def test_rejects_garbage(raw):
    with pytest.raises(ProtocolError):
        parse_mod_message(raw)


def test_top_level_empty_category_list_becomes_dict():
    m = parse_mod_message(b'{"v":1,"type":"snapshot","tick":1,"data":{"defense":[]}}')
    assert m.body["data"] == {"defense": {}}
