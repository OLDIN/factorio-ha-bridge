import asyncio

import pytest

from factorio_ha_relay.rcon import RconError, RconLink
from fake_rcon import FakeRcon

CMD = '/factorio-ha-config {"v":1,"categories":{"players":true}}'


async def wait_for(predicate, timeout=2.0):
    loop = asyncio.get_running_loop()
    end = loop.time() + timeout
    while not predicate():
        if loop.time() > end:
            raise AssertionError("condition not reached")
        await asyncio.sleep(0.01)


@pytest.fixture
async def server():
    srv = FakeRcon()
    await srv.start()
    yield srv
    await srv.stop()


@pytest.fixture
async def link_factory():
    tasks = []

    def make(port, password="secret"):
        link = RconLink("127.0.0.1", port, password, retry_delay=0.05)
        tasks.append(asyncio.create_task(link.run()))
        return link

    yield make
    for t in tasks:
        t.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)


async def test_rcon_auth_and_exec(server, link_factory):
    server.responses[CMD] = "ok"
    connected = []
    link = link_factory(server.port)
    link.on_connected = lambda: connected.append(1) or asyncio.sleep(0)
    await wait_for(lambda: link.alive)
    assert await link.exec(CMD) == "ok"
    assert connected == [1]


async def test_rcon_wrong_password_not_alive(server, link_factory):
    link = link_factory(server.port, password="nope")
    await asyncio.sleep(0.2)
    assert link.alive is False
    with pytest.raises(RconError):
        await link.exec(CMD)


async def test_exec_when_not_connected_raises(link_factory):
    link = link_factory(1)  # nothing listens on port 1
    with pytest.raises(RconError):
        await link.exec(CMD)


async def test_rcon_reconnects_after_server_restart(server, link_factory):
    connected = []
    link = link_factory(server.port)
    link.on_connected = lambda: connected.append(1) or asyncio.sleep(0)
    await wait_for(lambda: link.alive)
    await server.stop()
    await wait_for(lambda: not link.alive)
    await server.start()  # same port
    await wait_for(lambda: link.alive)
    assert connected == [1, 1]


async def test_rcon_exec_timeout_keeps_link_alive(server, link_factory):
    server.silent.add(CMD)
    server.responses["/second"] = "second"
    link = link_factory(server.port)
    await wait_for(lambda: link.alive)
    with pytest.raises(RconError):
        await link.exec(CMD, timeout=0.1)
    assert link.alive is True
    assert await link.exec("/second") == "second"


async def test_on_connected_can_exec(server, link_factory):
    """The relay re-sends its config from on_connected; that exec must get its answer."""
    server.responses[CMD] = "ok"
    answers = []
    link = link_factory(server.port)

    async def resend():
        answers.append(await link.exec(CMD, timeout=0.5))

    link.on_connected = resend
    await wait_for(lambda: answers, timeout=1.0)
    assert answers == ["ok"]


async def test_concurrent_exec_when_connection_drops_raises_rcon_error(server, link_factory):
    """Final review #1: the exec waiting for the lock must get RconError, not AttributeError."""
    server.silent.update({CMD, "/second"})
    link = link_factory(server.port)
    await wait_for(lambda: link.alive)
    first = asyncio.create_task(link.exec(CMD, timeout=2))
    second = asyncio.create_task(link.exec("/second", timeout=2))
    await asyncio.sleep(0.05)
    await server.stop()
    results = await asyncio.gather(first, second, return_exceptions=True)
    assert all(isinstance(r, RconError) for r in results), results


async def test_auth_failure_logged_once_as_warning(server, link_factory, caplog):
    """Final review #4: a wrong password must be visible at WARNING, without log spam."""
    caplog.set_level("DEBUG", logger="factorio_ha_relay.rcon")
    link_factory(server.port, password="nope")
    await asyncio.sleep(0.4)  # several retries at retry_delay=0.05
    warnings = [r for r in caplog.records if r.levelname == "WARNING" and "authentication failed" in r.getMessage()]
    assert len(warnings) == 1
