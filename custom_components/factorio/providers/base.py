"""The provider layer: how messages from the relay reach the integration.

The core never knows which provider delivered a message.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, Literal

MessageKind = Literal["availability", "hello", "state", "event"]


@dataclass(frozen=True)
class ProviderMessage:
    kind: MessageKind
    payload: Any


class Provider(ABC):
    @abstractmethod
    async def async_start(self, on_message: Callable[[ProviderMessage], None]) -> None:
        """Start delivering relay messages to on_message."""

    @abstractmethod
    async def async_send_config(self, config: dict[str, Any] | None) -> None:
        """Send the 'what to collect' config to the game (None clears it)."""

    @abstractmethod
    async def async_stop(self) -> None:
        """Stop delivering messages."""
