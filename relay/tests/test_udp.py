import asyncio
import socket

from factorio_ha_relay.udp import start_udp_listener


async def test_udp_delivers_datagram():
    got: list[bytes] = []
    transport = await start_udp_listener("127.0.0.1", 0, got.append)
    port = transport.get_extra_info("sockname")[1]
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.sendto(b'{"v":1}', ("127.0.0.1", port))
    for _ in range(100):
        if got:
            break
        await asyncio.sleep(0.01)
    transport.close()
    assert got == [b'{"v":1}']


def test_only_loopback_sources_accepted():
    from factorio_ha_relay.udp import _Protocol

    got: list[bytes] = []
    proto = _Protocol(got.append)
    proto.datagram_received(b"lan", ("10.1.2.3", 5000))
    proto.datagram_received(b"v4", ("127.0.0.1", 5000))
    proto.datagram_received(b"v6", ("::1", 5000, 0, 0))
    assert got == [b"v4", b"v6"]
