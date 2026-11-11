"""Parsing of messages sent by the factorio-ha mod (protocol v1, see docs/protocol.md)."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

PROTOCOL_VERSION = 1
MOD_TYPES = frozenset({"hello", "heartbeat", "snapshot", "update", "event"})


class ProtocolError(Exception):
    """A datagram that is not a valid protocol v1 mod message."""


@dataclass(frozen=True)
class ModMessage:
    type: str
    tick: int
    body: dict[str, Any] = field(default_factory=dict)


def _normalize_data(data: Any) -> dict[str, Any]:
    # helpers.table_to_json encodes an empty Lua table as [] — treat it as {}.
    if data == []:
        return {}
    if not isinstance(data, dict):
        raise ProtocolError(f"data must be an object, got {type(data).__name__}")
    players = data.get("players")
    if isinstance(players, dict) and players.get("online") == {}:
        data = {**data, "players": {**players, "online": []}}
    return data


def parse_mod_message(raw: bytes) -> ModMessage:
    try:
        obj = json.loads(raw)
    except (UnicodeDecodeError, ValueError) as err:
        raise ProtocolError(f"not JSON: {err}") from err
    if not isinstance(obj, dict):
        raise ProtocolError("message must be a JSON object")
    if obj.get("v") != PROTOCOL_VERSION:
        raise ProtocolError(f"unsupported protocol version: {obj.get('v')!r}")
    msg_type = obj.get("type")
    if msg_type not in MOD_TYPES:
        raise ProtocolError(f"unknown message type: {msg_type!r}")
    tick = obj.get("tick")
    if not isinstance(tick, int) or isinstance(tick, bool):
        raise ProtocolError(f"tick must be an integer, got {tick!r}")
    body = {k: v for k, v in obj.items() if k not in ("v", "type", "tick")}
    if "data" in body:
        body["data"] = _normalize_data(body["data"])
    return ModMessage(type=msg_type, tick=tick, body=body)
