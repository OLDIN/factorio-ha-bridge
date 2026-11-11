"""The output contract every relay output implements."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from typing import Any, Protocol

ConfigCallback = Callable[[dict[str, Any] | None], Awaitable[None]]
ConnectedCallback = Callable[[], Awaitable[None]]


class Output(Protocol):
    async def start(self, on_config: ConfigCallback, on_connected: ConnectedCallback) -> None:
        """Run forever: connect, call on_connected on every (re)connect, deliver configs."""

    async def read_retained_state(self, timeout: float = 2.0) -> dict[str, Any] | None:
        """Return the last state this relay published before it restarted, if any."""

    async def publish_hello(self, hello: dict[str, Any]) -> None: ...

    async def publish_state(self, state: dict[str, Any]) -> None: ...

    async def publish_event(self, event: dict[str, Any]) -> None: ...

    async def stop(self) -> None: ...
