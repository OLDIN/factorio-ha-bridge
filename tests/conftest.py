"""Shared test helpers."""

from __future__ import annotations

from collections.abc import Callable
from datetime import timedelta
from typing import Any

import pytest
from homeassistant.util import dt as dt_util
from pytest_homeassistant_custom_component.common import async_fire_time_changed

from custom_components.factorio.providers.base import Provider, ProviderMessage


@pytest.fixture
async def mqtt_mock(hass, mqtt_mock):
    """The plugin's mqtt_mock, plus unloading MQTT at teardown so its timers stop."""
    yield mqtt_mock
    for domain in ("factorio", "mqtt"):  # our entry unsubscribes from MQTT first
        for entry in hass.config_entries.async_entries(domain):
            await hass.config_entries.async_unload(entry.entry_id)
    # Let MQTT's debounced (un)subscribe cooldown timers fire.
    async_fire_time_changed(hass, dt_util.utcnow() + timedelta(seconds=30))
    await hass.async_block_till_done()


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
