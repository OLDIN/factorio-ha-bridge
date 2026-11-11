#!/usr/bin/env python3
"""Run one console command on the local dev server over RCON and print the reply.

Usage: rcon-exec.py '<command>'   (127.0.0.1:27015, password "dev")
Note: the first /c in a save asks to confirm disabling achievements; send it twice.
"""

import asyncio
import logging
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "relay"))

from factorio_ha_relay.rcon import RconLink  # noqa: E402


logging.disable(logging.CRITICAL)  # RconLink warns when we hang up


async def main(command: str) -> None:
    link = RconLink("127.0.0.1", 27015, "dev", retry_delay=0.5)
    task = asyncio.create_task(link.run())
    try:
        for _ in range(40):
            if link.alive:
                break
            await asyncio.sleep(0.25)
        print(await link.exec(command, timeout=15))
    finally:
        task.cancel()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    asyncio.run(main(sys.argv[1]))
