"""Persistent Source-RCON link to the Factorio server.

A live, authenticated connection means the Factorio process is alive. Command
timeouts do not drop the connection: a paused game may not answer commands.
"""

from __future__ import annotations

import asyncio
import itertools
import logging
import struct
from collections.abc import Awaitable, Callable

_LOGGER = logging.getLogger(__name__)

_AUTH = 3
_AUTH_RESPONSE = 2
_EXEC = 2


class RconError(Exception):
    """RCON command could not be executed."""


def _packet(req_id: int, ptype: int, body: str) -> bytes:
    payload = struct.pack("<ii", req_id, ptype) + body.encode() + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


async def _read_packet(reader: asyncio.StreamReader) -> tuple[int, int, str]:
    size = struct.unpack("<i", await reader.readexactly(4))[0]
    data = await reader.readexactly(size)
    req_id, ptype = struct.unpack("<ii", data[:8])
    return req_id, ptype, data[8:-2].decode(errors="replace")


class RconLink:
    def __init__(self, host: str, port: int, password: str, retry_delay: float = 5.0) -> None:
        self._host = host
        self._port = port
        self._password = password
        self._retry_delay = retry_delay
        self._writer: asyncio.StreamWriter | None = None
        self._pending: dict[int, asyncio.Future[str]] = {}
        self._ids = itertools.count(1)
        self._lock = asyncio.Lock()
        self._callbacks: set[asyncio.Task[None]] = set()
        self._last_error: str | None = None
        self.alive = False
        self.on_connected: Callable[[], Awaitable[None]] | None = None

    async def run(self) -> None:
        while True:
            try:
                await self._session()
            except asyncio.CancelledError:
                raise
            except (OSError, asyncio.IncompleteReadError, RconError) as err:
                message = str(err) or type(err).__name__
                # Warn once per distinct problem (wrong password, refused...), then stay quiet.
                level = logging.DEBUG if message == self._last_error else logging.WARNING
                _LOGGER.log(level, "RCON unavailable: %s", message)
                self._last_error = message
            finally:
                self._drop()
            await asyncio.sleep(self._retry_delay)

    async def _session(self) -> None:
        reader, writer = await asyncio.open_connection(self._host, self._port)
        self._writer = writer
        auth_id = next(self._ids)
        writer.write(_packet(auth_id, _AUTH, self._password))
        await writer.drain()
        while True:
            req_id, ptype, _ = await _read_packet(reader)
            if ptype != _AUTH_RESPONSE:
                continue  # some servers send an empty response before the auth result
            if req_id == -1:
                raise RconError("authentication failed")
            if req_id == auth_id:
                break
        self.alive = True
        self._last_error = None
        _LOGGER.info("RCON connected to %s:%s", self._host, self._port)
        if self.on_connected is not None:
            # Run concurrently: the callback may exec(), whose answer is read below.
            callback = asyncio.create_task(self._run_on_connected(self.on_connected))
            self._callbacks.add(callback)
            callback.add_done_callback(self._callbacks.discard)
        while True:
            req_id, _, body = await _read_packet(reader)
            future = self._pending.pop(req_id, None)
            if future is not None and not future.done():
                future.set_result(body)
            # unknown ids are late answers to timed-out commands: dropped

    @staticmethod
    async def _run_on_connected(callback: Callable[[], Awaitable[None]]) -> None:
        try:
            await callback()
        except Exception:  # noqa: BLE001 - a callback bug must not kill the link
            _LOGGER.exception("RCON on_connected callback failed")

    def _drop(self) -> None:
        if self.alive:
            _LOGGER.warning("RCON connection lost")
        self.alive = False
        if self._writer is not None:
            self._writer.close()
            self._writer = None
        for future in self._pending.values():
            if not future.done():
                future.set_exception(RconError("connection lost"))
        self._pending.clear()

    async def exec(self, command: str, timeout: float = 5.0) -> str:
        async with self._lock:
            # Checked under the lock: the link may have dropped while we waited for it.
            writer = self._writer
            if not self.alive or writer is None:
                raise RconError("not connected")
            req_id = next(self._ids)
            future: asyncio.Future[str] = asyncio.get_running_loop().create_future()
            self._pending[req_id] = future
            try:
                writer.write(_packet(req_id, _EXEC, command))
                await writer.drain()
                return await asyncio.wait_for(future, timeout)
            except TimeoutError as err:
                raise RconError(f"no answer within {timeout}s") from err
            except OSError as err:
                raise RconError(f"connection error: {err}") from err
            finally:
                self._pending.pop(req_id, None)
