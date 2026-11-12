from factorio_ha_relay.assembler import SnapshotAssembler
from factorio_ha_relay.protocol import parse_mod_message


def msg(raw: str):
    return parse_mod_message(raw.encode())


def part(tick, n, total, data):
    import json

    return msg(json.dumps({"v": 1, "type": "snapshot", "tick": tick, "part": n, "parts": total, "data": data}))


def test_two_parts_same_tick_combined():
    asm = SnapshotAssembler()
    assert asm.add(part(9, 1, 2, {"planets": {"bodies": []}})) is None
    done = asm.add(part(9, 2, 2, {"research": {"queue": []}}))
    assert done is not None
    assert (done.type, done.tick) == ("snapshot", 9)
    assert done.body == {"data": {"planets": {"bodies": []}, "research": {"queue": []}}}


def test_incomplete_dropped_on_newer_tick():
    asm = SnapshotAssembler()
    assert asm.add(part(9, 1, 2, {"planets": {"a": 1}})) is None
    assert asm.add(part(20, 1, 2, {"planets": {"a": 2}})) is None
    done = asm.add(part(20, 2, 2, {"research": {"b": 1}}))
    assert done.body["data"] == {"planets": {"a": 2}, "research": {"b": 1}}
    # the late second part of the dropped tick-9 set must not complete anything
    assert asm.add(part(9, 2, 2, {"research": {"b": 0}})) is None


def test_message_without_parts_passes_through():
    asm = SnapshotAssembler()
    m = msg('{"v":1,"type":"snapshot","tick":5,"data":{"players":{"online":[]}}}')
    assert asm.add(m) is m
    h = msg('{"v":1,"type":"heartbeat","tick":6,"players_online":0}')
    assert asm.add(h) is h


def test_duplicate_part_ignored():
    asm = SnapshotAssembler()
    assert asm.add(part(9, 1, 2, {"planets": {"a": 1}})) is None
    assert asm.add(part(9, 1, 2, {"planets": {"a": 1}})) is None
    done = asm.add(part(9, 2, 2, {"research": {"b": 1}}))
    assert done is not None and set(done.body["data"]) == {"planets", "research"}
