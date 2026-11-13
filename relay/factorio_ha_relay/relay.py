"""Relay orchestration: mod datagrams in, state/events out, HA config to the game."""

from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Any, Protocol

from . import __version__
from .assembler import SnapshotAssembler
from .config import Settings
from .game_state import compute_game_state
from .outputs.base import Output
from .protocol import PROTOCOL_VERSION, ProtocolError, parse_mod_message
from .rcon import RconError
from .state import StateStore
from .ups import UpsMeter

_LOGGER = logging.getLogger(__name__)
CONFIG_COMMAND = "/factorio-ha-config"
CATEGORY_RE = re.compile(r"^[a-z_]+$")
EMPTY_CONFIG: dict[str, Any] = {"v": PROTOCOL_VERSION, "categories": {}}
# UPS goes into `state` at most this often, so the HA sensor (and its recorder) changes once a minute.
UPS_UPDATE_SECONDS = 60.0
# No heartbeat for this long: the game is not just slow, the measurement starts over.
UPS_SILENCE_SECONDS = 60.0
_VERSION_RE = re.compile(r"\d+\.\d+\.\d+")


class Rcon(Protocol):
    alive: bool

    async def exec(self, command: str, timeout: float = 5.0) -> str: ...


def _compact(obj: Any) -> str:
    return json.dumps(obj, separators=(",", ":"))


def _utcnow_iso() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def parse_game_version(answer: str) -> str | None:
    """The game version in the answer to /version ("2.0.72", or with a build and platform after it)."""
    match = _VERSION_RE.search(answer or "")
    return match.group(0) if match else None


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
        self._assembler = SnapshotAssembler()
        self._last_heartbeat: float | None = None
        self._config: dict[str, Any] | None = None
        self._game_state: tuple[str, str | None] | None = None
        self._since = utcnow()
        self._published: dict[str, Any] | None = None
        self._tasks: set[asyncio.Task[None]] = set()
        self._started = monotonic()
        # Server health. Never seeded from the retained state: a reboot of the host restarts the
        # relay and the game together, and a restored start time would hide that restart.
        self._ups_meter = UpsMeter()
        self._ups: float | None = None
        self._ups_at: float | None = None
        self._server_started: str | None = None
        self._game_version: str | None = None

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
        assembled = self._assembler.add(msg)
        if assembled is None:
            return
        msg = assembled
        players_before = self._store.players_online
        self._store.apply(msg)
        if msg.type == "heartbeat":
            self._last_heartbeat = self._monotonic()
            if players_before == 0 and (self._store.players_online or 0) > 0:
                # Players are back: an auto-paused game was standing still, not slow. Measure
                # from here (the last value stays until the next one), so a pause shorter than
                # the heartbeat timeout does not show as a dip.
                self._ups_meter.reset()
            self._measure_ups(self._last_heartbeat, msg.tick)
            await self._output.publish_tick({"v": PROTOCOL_VERSION, "tick": msg.tick})
        if msg.type == "hello":
            _LOGGER.info("Mod says hello (version %s)", self._store.mod_version)
            await self._output.publish_hello(self._hello())
            # a periodic hello is only a liveness ping; old mods send no reason and get the old behaviour
            if msg.body.get("reason") != "periodic":
                await self._send_config()
        await self._publish_changes()
        await self.evaluate()

    async def on_config(self, config: dict[str, Any] | None) -> None:
        self._config = config if isinstance(config, dict) else EMPTY_CONFIG
        await self._send_config()

    async def on_rcon_connected(self) -> None:
        # Every connect follows a gap in RCON: the server (re)started, as far as the relay can tell.
        self._server_started = self._utcnow()
        await self._read_game_version()
        await self._send_config()
        await self.evaluate()

    async def on_output_connected(self) -> None:
        await self._output.publish_hello(self._hello())
        await self._publish_state(force=True)
        self._store.take_changes()
        for category, value in self._store.categories.items():
            await self._publish_category(category, value)

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
        if isinstance(data, dict) and isinstance(data.get("players"), dict):
            self._store.seed_categories({"players": data["players"]})
        game_state, since = state.get("game_state"), state.get("game_state_since")
        if self._game_state is None and isinstance(game_state, str) and isinstance(since, str):
            self._game_state = (game_state, state.get("game_state_reason"))
            self._since = since

    def seed_hello(self, hello: dict[str, Any]) -> None:
        """Remember the mod version from the hello published before a relay restart."""
        version = hello.get("mod_version")
        if self._store.mod_version is None and isinstance(version, str):
            self._store.mod_version = version

    def seed_data(self, data: dict[str, dict[str, Any]]) -> None:
        """Restore categories from the retained data/* topics; only categories still unknown are filled."""
        self._store.seed_categories({k: v for k, v in data.items() if isinstance(v, dict)})

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
        # A slow game (heartbeats more than 15 s apart: under ~20 UPS) keeps its measurement; a
        # stopped server, a game paused without players or a minute without heartbeats does not.
        if current[0] == "stopped" or current == ("paused", "no_players") or age is None or age > UPS_SILENCE_SECONDS:
            self._ups_meter.reset()
            self._ups = self._ups_at = None
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
                "relay_version": __version__, "mod_version": self._store.mod_version,
                "game_version": self._game_version}

    def _measure_ups(self, now: float, tick: int) -> None:
        self._ups_meter.add(now, tick)
        if self._ups_at is not None and now - self._ups_at < UPS_UPDATE_SECONDS:
            return
        value = self._ups_meter.value()
        if value is not None:
            self._ups, self._ups_at = value, now

    async def _read_game_version(self) -> None:
        try:
            answer = await self._rcon.exec("/version")
        except RconError as err:
            _LOGGER.warning("Game version not read (%s)", err)
            return
        version = parse_game_version(answer)
        if version is not None and version != self._game_version:
            self._game_version = version
            await self._output.publish_hello(self._hello())

    async def _publish_changes(self) -> None:
        for category, value in self._store.take_changes().items():
            await self._publish_category(category, value)

    async def _publish_category(self, category: str, value: dict[str, Any] | None) -> None:
        if not CATEGORY_RE.match(category):
            _LOGGER.warning("Skipped category with a bad name: %r", category)
            return
        payload = None if value is None else {"v": PROTOCOL_VERSION, "tick": self._store.tick, "data": value}
        await self._output.publish_data(category, payload)

    async def _publish_state(self, force: bool = False) -> None:
        if self._game_state is None:
            return
        state = self._store.public_state(self._game_state[0], self._game_state[1], self._since)
        state["ups"] = self._ups
        state["server_started"] = self._server_started if self._rcon.alive else None
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
            _LOGGER.warning("Config not delivered yet (%s); will retry on the next RCON reconnect, mod (re)start or config change", err)
            return
        _LOGGER.info("Config delivered to the game: %s", answer)
