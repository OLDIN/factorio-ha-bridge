"""UDP listener for datagrams from the factorio-ha mod."""

from __future__ import annotations

import asyncio
from collections.abc import Callable


class _Protocol(asyncio.DatagramProtocol):
    def __init__(self, on_datagram: Callable[[bytes], None]) -> None:
        self._on_datagram = on_datagram

    def datagram_received(self, data: bytes, addr: tuple) -> None:
        self._on_datagram(data)


async def start_udp_listener(
    host: str, port: int, on_datagram: Callable[[bytes], None]
) -> asyncio.DatagramTransport:
    loop = asyncio.get_running_loop()
    transport, _ = await loop.create_datagram_endpoint(
        lambda: _Protocol(on_datagram), local_addr=(host, port)
    )
    return transport
