"""Provider factory."""

from __future__ import annotations

from typing import TYPE_CHECKING

from ..const import CONF_PROVIDER, CONF_SERVER_ID, PROVIDER_MQTT
from .base import Provider

if TYPE_CHECKING:
    from homeassistant.config_entries import ConfigEntry
    from homeassistant.core import HomeAssistant


def create_provider(hass: HomeAssistant, entry: ConfigEntry) -> Provider:
    provider = entry.data[CONF_PROVIDER]
    if provider == PROVIDER_MQTT:
        from .mqtt import MqttProvider  # noqa: PLC0415 - imports homeassistant.components.mqtt

        return MqttProvider(hass, entry.data[CONF_SERVER_ID])
    raise ValueError(f"Unknown provider: {provider}")
