"""UDP listener for datagrams from the factorio-ha mod."""

from __future__ import annotations

import asyncio
import ipaddress
import logging
from collections.abc import Callable

_LOGGER = logging.getLogger(__name__)


class _Protocol(asyncio.DatagramProtocol):
    def __init__(self, on_datagram: Callable[[bytes], None]) -> None:
        self._on_datagram = on_datagram

    def datagram_received(self, data: bytes, addr: tuple) -> None:
        # The mod can only send to localhost; anything else is not ours.
        try:
            loopback = ipaddress.ip_address(addr[0]).is_loopback
        except ValueError:
            loopback = False
        if not loopback:
            _LOGGER.warning("Dropped datagram from non-loopback source %s", addr[0])
            return
        self._on_datagram(data)


async def start_udp_listener(
    host: str, port: int, on_datagram: Callable[[bytes], None]
) -> asyncio.DatagramTransport:
    loop = asyncio.get_running_loop()
    transport, _ = await loop.create_datagram_endpoint(
        lambda: _Protocol(on_datagram), local_addr=(host, port)
    )
    return transport
