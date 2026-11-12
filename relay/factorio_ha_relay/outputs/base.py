"""The output contract every relay output implements."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Any, Protocol

ConfigCallback = Callable[[dict[str, Any] | None], Awaitable[None]]
ConnectedCallback = Callable[[], Awaitable[None]]
# {"state": {...}, "hello": {...}, "data": {category: {...}}} — whatever this relay had retained before it restarted
SeedCallback = Callable[[dict[str, dict[str, Any]]], None]


class Output(Protocol):
    async def start(
        self, on_config: ConfigCallback, on_connected: ConnectedCallback, on_seed: SeedCallback | None = None
    ) -> None:
        """Run forever: connect, call on_connected on every (re)connect, deliver configs.

        On the first successful connection, hand the state, hello and data categories this relay published
        before it restarted (if any) to on_seed, before on_connected.
        """

    async def publish_hello(self, hello: dict[str, Any]) -> None: ...

    async def publish_state(self, state: dict[str, Any]) -> None: ...

    async def publish_event(self, event: dict[str, Any]) -> None: ...

    async def publish_data(self, category: str, payload: dict[str, Any] | None) -> None:
        """Publish one data category (retained); ``None`` removes it."""

    async def publish_tick(self, tick: dict[str, Any]) -> None:
        """Publish the game clock (not retained); sent once per mod heartbeat, so it stops while the game is paused."""

    async def stop(self) -> None: ...
