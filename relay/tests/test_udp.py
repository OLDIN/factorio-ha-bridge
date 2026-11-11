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
