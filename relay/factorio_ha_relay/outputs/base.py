"""The output contract every relay output implements."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Any, Protocol

ConfigCallback = Callable[[dict[str, Any] | None], Awaitable[None]]
ConnectedCallback = Callable[[], Awaitable[None]]
SeedCallback = Callable[[dict[str, Any]], None]


class Output(Protocol):
    async def start(
        self, on_config: ConfigCallback, on_connected: ConnectedCallback, on_seed: SeedCallback | None = None
    ) -> None:
        """Run forever: connect, call on_connected on every (re)connect, deliver configs.

        On the first successful connection, hand the state this relay published before
        it restarted (if any) to on_seed, before on_connected.
        """

    async def publish_hello(self, hello: dict[str, Any]) -> None: ...

    async def publish_state(self, state: dict[str, Any]) -> None: ...

    async def publish_event(self, event: dict[str, Any]) -> None: ...

    async def stop(self) -> None: ...
