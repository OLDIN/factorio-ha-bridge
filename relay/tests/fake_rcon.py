"""A minimal Source-RCON server for tests (auth, exec, silence, restart)."""

from __future__ import annotations

import asyncio
import struct

AUTH, AUTH_RESPONSE, EXEC, RESPONSE = 3, 2, 2, 0


def packet(req_id: int, ptype: int, body: str) -> bytes:
    payload = struct.pack("<ii", req_id, ptype) + body.encode() + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


class FakeRcon:
    def __init__(self, password: str = "secret") -> None:
        self.password = password
        self.responses: dict[str, str] = {}
        self.silent: set[str] = set()
        self.received: list[str] = []
        self.port = 0
        self._server: asyncio.base_events.Server | None = None
        self._writers: list[asyncio.StreamWriter] = []

    async def start(self) -> None:
        self._server = await asyncio.start_server(self._handle, "127.0.0.1", self.port)
        self.port = self._server.sockets[0].getsockname()[1]

    async def stop(self) -> None:
        for w in self._writers:
            w.close()
        self._writers.clear()
        if self._server:
            self._server.close()
            await self._server.wait_closed()
            self._server = None

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self._writers.append(writer)
        try:
            while True:
                size = struct.unpack("<i", await reader.readexactly(4))[0]
                data = await reader.readexactly(size)
                req_id, ptype = struct.unpack("<ii", data[:8])
                body = data[8:-2].decode()
                if ptype == AUTH:
                    ok = body == self.password
                    writer.write(packet(req_id if ok else -1, AUTH_RESPONSE, ""))
                elif ptype == EXEC:
                    self.received.append(body)
                    if body in self.silent:
                        continue
                    writer.write(packet(req_id, RESPONSE, self.responses.get(body, "")))
                await writer.drain()
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            writer.close()
