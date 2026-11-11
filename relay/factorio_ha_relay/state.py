"""Last known game data, merged from mod messages."""

from __future__ import annotations

from typing import Any

from .protocol import PROTOCOL_VERSION, ModMessage


class StateStore:
    def __init__(self) -> None:
        self.players_online: int | None = None
        self.tick: int | None = None
        self.mod_version: str | None = None
        self.data: dict[str, Any] = {}

    def apply(self, msg: ModMessage) -> None:
        if msg.type == "event":
            return
        self.tick = msg.tick
        if msg.type == "heartbeat":
            players = msg.body.get("players_online")
            if isinstance(players, int) and not isinstance(players, bool):
                self.players_online = players
        elif msg.type == "hello":
            version = msg.body.get("mod_version")
            self.mod_version = version if isinstance(version, str) else None
        elif msg.type == "snapshot":
            self.data = dict(msg.body.get("data", {}))
        elif msg.type == "update":
            self.data = {**self.data, **msg.body.get("data", {})}

    def public_state(self, game_state: str, reason: str | None, since: str) -> dict[str, Any]:
        return {
            "v": PROTOCOL_VERSION,
            "game_state": game_state,
            "game_state_reason": reason,
            "game_state_since": since,
            "tick": self.tick,
            "players_online": self.players_online,
            "data": self.data,
        }
