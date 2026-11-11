"""Shared test helpers."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from custom_components.factorio.providers.base import Provider, ProviderMessage


class FakeProvider(Provider):
    """Delivers messages a test pushes; records configs it was asked to send."""

    def __init__(self) -> None:
        self.on_message: Callable[[ProviderMessage], None] | None = None
        self.sent_configs: list[dict[str, Any] | None] = []
        self.stopped = False

    async def async_start(self, on_message: Callable[[ProviderMessage], None]) -> None:
        self.on_message = on_message

    async def async_send_config(self, config: dict[str, Any] | None) -> None:
        self.sent_configs.append(config)

    async def async_stop(self) -> None:
        self.stopped = True

    def push(self, kind: str, payload: Any) -> None:
        assert self.on_message is not None
        self.on_message(ProviderMessage(kind=kind, payload=payload))
