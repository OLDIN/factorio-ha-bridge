"""Entry point: python -m factorio_ha_relay (configured via FHA_* environment variables)."""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import signal

from .config import Settings
from .outputs.mqtt import MqttOutput
from .rcon import RconLink
from .relay import Relay
from .udp import start_udp_listener

_LOGGER = logging.getLogger("factorio_ha_relay")


async def main() -> None:
    settings = Settings.from_env(os.environ)
    output = MqttOutput(settings)
    rcon = RconLink(settings.rcon_host, settings.rcon_port, settings.rcon_password)
    relay = Relay(settings, output, rcon)

    seed = await output.read_retained_state()
    if seed:
        relay.seed(seed)
        _LOGGER.info("Continuing from retained state: %s", seed.get("game_state"))
    rcon.on_connected = relay.on_rcon_connected

    transport = await start_udp_listener(settings.udp_host, settings.udp_port, relay.handle_datagram)
    _LOGGER.info("Listening for the mod on udp://%s:%s", settings.udp_host, settings.udp_port)

    current = asyncio.current_task()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(sig, current.cancel)
    try:
        async with asyncio.TaskGroup() as tg:
            tg.create_task(rcon.run())
            tg.create_task(output.start(relay.on_config, relay.on_output_connected))
            tg.create_task(relay.run_evaluator())
    except asyncio.CancelledError:
        _LOGGER.info("Shutting down")
    finally:
        transport.close()
        await output.stop()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    with contextlib.suppress(KeyboardInterrupt):
        asyncio.run(main())
