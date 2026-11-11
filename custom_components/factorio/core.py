"""Game state as Home Assistant should see it. Independent of HA and of the provider."""

from __future__ import annotations

from collections.abc import Callable, Mapping
from typing import Any

from .const import CATEGORIES, PROTOCOL_VERSION
from .providers.base import ProviderMessage


def build_config(options: Mapping[str, Any]) -> dict[str, Any]:
    """The 'what to collect' config sent to the game; categories default to on."""
    return {"v": PROTOCOL_VERSION, "categories": {c: bool(options.get(c, True)) for c in CATEGORIES}}


class FactorioCore:
    def __init__(self, server_id: str) -> None:
        self.server_id = server_id
        self.relay_online: bool | None = None
        self._state: dict[str, Any] = {}
        self._hello: dict[str, Any] = {}
        self._listeners: list[Callable[[], None]] = []
        self._event_listeners: list[Callable[[str, dict[str, Any]], None]] = []

    # --- input --------------------------------------------------------------

    def handle_message(self, msg: ProviderMessage) -> None:
        if msg.kind == "availability":
            self.relay_online = msg.payload == "online"
        elif msg.kind == "state" and isinstance(msg.payload, dict):
            self._state = msg.payload
        elif msg.kind == "hello" and isinstance(msg.payload, dict):
            self._hello = msg.payload
        elif msg.kind == "event" and isinstance(msg.payload, dict) and isinstance(msg.payload.get("event"), str):
            data = msg.payload.get("data")
            for listener in list(self._event_listeners):
                listener(msg.payload["event"], data if isinstance(data, dict) else {})
            return
        else:
            return
        for listener in list(self._listeners):
            listener()

    # --- subscriptions --------------------------------------------------------

    def add_listener(self, callback: Callable[[], None]) -> Callable[[], None]:
        self._listeners.append(callback)
        return lambda: self._listeners.remove(callback)

    def add_event_listener(self, callback: Callable[[str, dict[str, Any]], None]) -> Callable[[], None]:
        self._event_listeners.append(callback)
        return lambda: self._event_listeners.remove(callback)

    # --- derived values -------------------------------------------------------

    @property
    def game_state(self) -> str | None:
        if self.relay_online is False:
            return "no_connection"
        return self._state.get("game_state")

    @property
    def game_state_reason(self) -> str | None:
        return None if self.relay_online is False else self._state.get("game_state_reason")

    @property
    def game_state_since(self) -> str | None:
        return self._state.get("game_state_since")

    @property
    def players_online(self) -> int | None:
        return self._state.get("players_online")

    @property
    def players(self) -> list[str] | None:
        players = (self._state.get("data") or {}).get("players")
        if not isinstance(players, dict):
            return None
        online = players.get("online")
        return list(online) if isinstance(online, list) else []

    @property
    def mod_version(self) -> str | None:
        return self._hello.get("mod_version")
