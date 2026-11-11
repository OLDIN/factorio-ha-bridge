"""Relay orchestration: mod datagrams in, state/events out, HA config to the game."""

from __future__ import annotations

import asyncio
import json
import logging
import time
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Any, Protocol

from . import __version__
from .config import Settings
from .game_state import compute_game_state
from .outputs.base import Output
from .protocol import PROTOCOL_VERSION, ProtocolError, parse_mod_message
from .rcon import RconError
from .state import StateStore

_LOGGER = logging.getLogger(__name__)
CONFIG_COMMAND = "/factorio-ha-config"
EMPTY_CONFIG: dict[str, Any] = {"v": PROTOCOL_VERSION, "categories": {}}


class Rcon(Protocol):
    alive: bool

    async def exec(self, command: str, timeout: float = 5.0) -> str: ...


def _compact(obj: Any) -> str:
    return json.dumps(obj, separators=(",", ":"))


def _utcnow_iso() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


class Relay:
    def __init__(
        self,
        settings: Settings,
        output: Output,
        rcon: Rcon,
        monotonic: Callable[[], float] = time.monotonic,
        utcnow: Callable[[], str] = _utcnow_iso,
    ) -> None:
        self._settings = settings
        self._output = output
        self._rcon = rcon
        self._monotonic = monotonic
        self._utcnow = utcnow
        self._store = StateStore()
        self._last_heartbeat: float | None = None
        self._config: dict[str, Any] | None = None
        self._game_state: tuple[str, str | None] | None = None
        self._since = utcnow()
        self._published: dict[str, Any] | None = None
        self._tasks: set[asyncio.Task[None]] = set()
        self._started = monotonic()

    # --- inputs -------------------------------------------------------------

    def handle_datagram(self, raw: bytes) -> None:
        task = asyncio.get_running_loop().create_task(self.process_datagram(raw))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def process_datagram(self, raw: bytes) -> None:
        try:
            msg = parse_mod_message(raw)
        except ProtocolError as err:
            _LOGGER.warning("Ignored datagram (%s): %r", err, raw[:200])
            return
        if msg.type == "event":
            name = msg.body.get("event")
            if not isinstance(name, str):
                _LOGGER.warning("Ignored event without a name: %r", raw[:200])
                return
            data = msg.body.get("data")
            await self._output.publish_event(
                {"v": PROTOCOL_VERSION, "event": name, "tick": msg.tick,
                 "time": self._utcnow(), "data": data if isinstance(data, dict) else {}}
            )
            return
        self._store.apply(msg)
        if msg.type == "heartbeat":
            self._last_heartbeat = self._monotonic()
        if msg.type == "hello":
            _LOGGER.info("Mod says hello (version %s)", self._store.mod_version)
            await self._output.publish_hello(self._hello())
            await self._send_config()
        await self.evaluate()

    async def on_config(self, config: dict[str, Any] | None) -> None:
        self._config = config if isinstance(config, dict) else EMPTY_CONFIG
        await self._send_config()

    async def on_rcon_connected(self) -> None:
        await self._send_config()
        await self.evaluate()

    async def on_output_connected(self) -> None:
        await self._output.publish_hello(self._hello())
        await self._publish_state(force=True)

    def seed(self, state: dict[str, Any]) -> None:
        """Continue from the state published before a relay restart.

        Fills only what is still unknown: when the broker comes up after the relay,
        fresh data from the game must win over the retained copy.
        """
        players = state.get("players_online")
        if self._store.players_online is None and isinstance(players, int) and not isinstance(players, bool):
            self._store.players_online = players
        tick = state.get("tick")
        if self._store.tick is None and isinstance(tick, int) and not isinstance(tick, bool):
            self._store.tick = tick
        data = state.get("data")
        if not self._store.data and isinstance(data, dict):
            self._store.data = dict(data)
        game_state, since = state.get("game_state"), state.get("game_state_since")
        if self._game_state is None and isinstance(game_state, str) and isinstance(since, str):
            self._game_state = (game_state, state.get("game_state_reason"))
            self._since = since

    def seed_hello(self, hello: dict[str, Any]) -> None:
        """Remember the mod version from the hello published before a relay restart."""
        version = hello.get("mod_version")
        if self._store.mod_version is None and isinstance(version, str):
            self._store.mod_version = version

    # --- periodic -----------------------------------------------------------

    async def run_evaluator(self, interval: float = 1.0) -> None:
        while True:
            await self.evaluate()
            await asyncio.sleep(interval)

    async def evaluate(self) -> None:
        age = None if self._last_heartbeat is None else self._monotonic() - self._last_heartbeat
        current = compute_game_state(
            self._rcon.alive, age, self._store.players_online, self._settings.heartbeat_timeout
        )
        # Right after start RCON is not connected yet and no heartbeat has arrived, so
        # anything but "running" is not trustworthy: keep the seeded state meanwhile.
        in_grace = self._monotonic() - self._started < self._settings.heartbeat_timeout
        if in_grace and current[0] != "running":
            pass
        elif current != self._game_state:
            _LOGGER.info("Game state: %s (%s)", current[0], current[1])
            self._game_state = current
            self._since = self._utcnow()
        await self._publish_state()

    # --- helpers ------------------------------------------------------------

    def _hello(self) -> dict[str, Any]:
        return {"v": PROTOCOL_VERSION, "server_id": self._settings.server_id,
                "relay_version": __version__, "mod_version": self._store.mod_version}

    async def _publish_state(self, force: bool = False) -> None:
        if self._game_state is None:
            return
        state = self._store.public_state(self._game_state[0], self._game_state[1], self._since)
        comparable = {k: v for k, v in state.items() if k != "tick"}
        if force or comparable != self._published:
            self._published = comparable
            await self._output.publish_state(state)

    async def _send_config(self) -> None:
        if self._config is None or not self._rcon.alive:
            return
        command = f"{CONFIG_COMMAND} {_compact(self._config)}"
        try:
            answer = await self._rcon.exec(command)
        except RconError as err:
            _LOGGER.warning("Config not delivered yet (%s); will retry on next hello/reconnect", err)
            return
        _LOGGER.info("Config delivered to the game: %s", answer)
