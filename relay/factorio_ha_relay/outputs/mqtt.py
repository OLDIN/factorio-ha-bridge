"""MQTT output: retained availability/hello/state, events, and the HA config topic."""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
from typing import Any

import aiomqtt

from ..config import Settings
from .base import ConfigCallback, ConnectedCallback, SeedCallback

_LOGGER = logging.getLogger(__name__)
TOPIC_PREFIX = "factorio"


def _compact(obj: Any) -> str:
    return json.dumps(obj, separators=(",", ":"))


class MqttOutput:
    def __init__(self, settings: Settings, reconnect_delay: float = 5.0) -> None:
        self._settings = settings
        self._reconnect_delay = reconnect_delay
        self._client: aiomqtt.Client | None = None
        self._seeded = False
        base = f"{TOPIC_PREFIX}/{settings.server_id}"
        self.topic_availability = f"{base}/availability"
        self.topic_hello = f"{base}/hello"
        self.topic_state = f"{base}/state"
        self.topic_event = f"{base}/event"
        self.topic_config = f"{base}/config"

    def _new_client(self, suffix: str, **kwargs: Any) -> aiomqtt.Client:
        s = self._settings
        return aiomqtt.Client(
            hostname=s.mqtt_host,
            port=s.mqtt_port,
            username=s.mqtt_user,
            password=s.mqtt_password,
            identifier=f"factorio-ha-relay-{s.server_id}-{suffix}",
            **kwargs,
        )

    async def start(
        self, on_config: ConfigCallback, on_connected: ConnectedCallback, on_seed: SeedCallback | None = None
    ) -> None:
        will = aiomqtt.Will(self.topic_availability, "offline", qos=1, retain=True)
        while True:
            try:
                async with self._new_client("main", will=will) as client:
                    if not self._seeded:
                        retained = await self._receive_retained_state(client)
                        self._seeded = True
                        if retained is not None and on_seed is not None:
                            on_seed(retained)
                    self._client = client
                    await client.publish(self.topic_availability, "online", qos=1, retain=True)
                    await client.subscribe(self.topic_config, qos=1)
                    _LOGGER.info("MQTT connected to %s:%s", self._settings.mqtt_host, self._settings.mqtt_port)
                    await on_connected()
                    try:
                        async for message in client.messages:
                            if message.topic.matches(self.topic_config):
                                try:
                                    await on_config(self._parse_config(message.payload))
                                except Exception:  # noqa: BLE001 - one bad config must not stop the relay
                                    _LOGGER.exception("Handling the config failed")
                    except asyncio.CancelledError:
                        # Graceful stop: a clean disconnect does not trigger the last will.
                        with contextlib.suppress(aiomqtt.MqttError):
                            await client.publish(self.topic_availability, "offline", qos=1, retain=True)
                        raise
            except aiomqtt.MqttError as err:
                _LOGGER.warning("MQTT connection lost (%s); retrying in %ss", err, self._reconnect_delay)
            finally:
                self._client = None
            await asyncio.sleep(self._reconnect_delay)

    @staticmethod
    def _parse_config(payload: Any) -> dict[str, Any] | None:
        if not payload:
            return None
        try:
            config = json.loads(payload)
        except (TypeError, ValueError):
            _LOGGER.warning("Ignored invalid config payload: %r", payload)
            return None
        return config if isinstance(config, dict) else None

    async def _receive_retained_state(self, client: aiomqtt.Client, timeout: float = 2.0) -> dict[str, Any] | None:
        """Read our own retained state once (broker delivers it right after subscribing)."""
        await client.subscribe(self.topic_state, qos=1)
        try:
            async with asyncio.timeout(timeout):
                async for message in client.messages:
                    if not message.topic.matches(self.topic_state):
                        continue
                    try:
                        state = json.loads(message.payload) if message.payload else None
                    except ValueError:
                        return None
                    return state if isinstance(state, dict) else None
        except TimeoutError:
            return None
        finally:
            await client.unsubscribe(self.topic_state)
        return None

    async def _publish(self, topic: str, payload: str, retain: bool) -> None:
        client = self._client
        if client is None:
            return  # state/hello are re-published on the next connect
        try:
            await client.publish(topic, payload, qos=1, retain=retain)
        except aiomqtt.MqttError as err:
            _LOGGER.warning("MQTT publish to %s failed: %s", topic, err)

    async def publish_hello(self, hello: dict[str, Any]) -> None:
        await self._publish(self.topic_hello, _compact(hello), retain=True)

    async def publish_state(self, state: dict[str, Any]) -> None:
        await self._publish(self.topic_state, _compact(state), retain=True)

    async def publish_event(self, event: dict[str, Any]) -> None:
        await self._publish(self.topic_event, _compact(event), retain=False)

    async def stop(self) -> None:
        await self._publish(self.topic_availability, "offline", retain=True)
