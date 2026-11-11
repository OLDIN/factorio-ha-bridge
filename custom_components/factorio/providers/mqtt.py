"""MQTT provider: the relay's retained topics via Home Assistant's MQTT integration."""

from __future__ import annotations

import json
import logging
from collections.abc import Callable
from typing import Any

from homeassistant.components import mqtt
from homeassistant.components.mqtt import ReceiveMessage
from homeassistant.core import CALLBACK_TYPE, HomeAssistant, callback
from homeassistant.exceptions import ConfigEntryNotReady

from ..const import TOPIC_PREFIX
from .base import MessageKind, Provider, ProviderMessage

_LOGGER = logging.getLogger(__name__)
_KINDS: tuple[MessageKind, ...] = ("availability", "hello", "state", "event")


class MqttProvider(Provider):
    def __init__(self, hass: HomeAssistant, server_id: str) -> None:
        self._hass = hass
        self._base = f"{TOPIC_PREFIX}/{server_id}"
        self._unsubscribe: list[CALLBACK_TYPE] = []

    async def async_start(self, on_message: Callable[[ProviderMessage], None]) -> None:
        if not await mqtt.async_wait_for_mqtt_client(self._hass):
            raise ConfigEntryNotReady("MQTT is not available")
        for kind in _KINDS:
            self._unsubscribe.append(
                await mqtt.async_subscribe(self._hass, f"{self._base}/{kind}", self._handler(kind, on_message), qos=1)
            )

    @staticmethod
    def _handler(kind: MessageKind, on_message: Callable[[ProviderMessage], None]) -> Callable[[ReceiveMessage], None]:
        @callback
        def handle(msg: ReceiveMessage) -> None:
            payload: Any = msg.payload
            if kind != "availability":
                if not payload:
                    return
                try:
                    payload = json.loads(payload)
                except ValueError:
                    _LOGGER.warning("Ignored invalid JSON on %s: %r", msg.topic, msg.payload)
                    return
            on_message(ProviderMessage(kind=kind, payload=payload))

        return handle

    async def async_send_config(self, config: dict[str, Any] | None) -> None:
        payload = json.dumps(config, separators=(",", ":")) if config else ""
        await mqtt.async_publish(self._hass, f"{self._base}/config", payload, qos=1, retain=True)

    async def async_stop(self) -> None:
        for unsubscribe in self._unsubscribe:
            unsubscribe()
        self._unsubscribe.clear()
