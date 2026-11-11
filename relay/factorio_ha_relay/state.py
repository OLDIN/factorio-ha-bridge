"""Last known game data, merged from mod messages."""

from __future__ import annotations

from typing import Any

from .protocol import PROTOCOL_VERSION, ModMessage


class StateStore:
    def __init__(self) -> None:
        self.players_online: int | None = None
        self.tick: int | None = None
        self.mod_version: str | None = None
        self.categories: dict[str, dict[str, Any]] = {}
        self._changes: dict[str, dict[str, Any] | None] = {}

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
            new = dict(msg.body.get("data", {}))
            for name in self.categories.keys() - new.keys():
                self._changes[name] = None
            self._set(new)
            self.categories = new
        elif msg.type == "update":
            data = msg.body.get("data", {})
            self._set(data)
            self.categories = {**self.categories, **data}

    def _set(self, new: dict[str, Any]) -> None:
        for name, value in new.items():
            if name not in self.categories or self.categories[name] != value:
                self._changes[name] = value

    def take_changes(self) -> dict[str, dict[str, Any] | None]:
        """Categories changed since the last call (``None`` = removed)."""
        changes, self._changes = self._changes, {}
        return changes

    def seed_categories(self, categories: dict[str, dict[str, Any]]) -> None:
        """Fill categories not known yet (restored from retained topics); not reported as changes."""
        for name, value in categories.items():
            self.categories.setdefault(name, value)

    def public_state(self, game_state: str, reason: str | None, since: str) -> dict[str, Any]:
        return {
            "v": PROTOCOL_VERSION,
            "game_state": game_state,
            "game_state_reason": reason,
            "game_state_since": since,
            "tick": self.tick,
            "players_online": self.players_online,
            # old integrations read only players here; everything else is in data/<category>
            "data": {"players": self.categories["players"]} if "players" in self.categories else {},
        }
