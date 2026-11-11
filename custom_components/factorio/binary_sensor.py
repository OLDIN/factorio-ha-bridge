"""Binary sensors: relay connection and whether the game is running."""

from __future__ import annotations

from homeassistant.components.binary_sensor import BinarySensorDeviceClass, BinarySensorEntity
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from . import FactorioConfigEntry
from .entity import FactorioEntity


async def async_setup_entry(
    hass: HomeAssistant, entry: FactorioConfigEntry, async_add_entities: AddConfigEntryEntitiesCallback
) -> None:
    async_add_entities([ConnectionBinarySensor(entry), GameRunningBinarySensor(entry)])


class ConnectionBinarySensor(FactorioEntity, BinarySensorEntity):
    _attr_device_class = BinarySensorDeviceClass.CONNECTIVITY

    def __init__(self, entry: FactorioConfigEntry) -> None:
        super().__init__(entry, Platform.BINARY_SENSOR, "connection")

    @property
    def is_on(self) -> bool:
        return self._core.relay_online is True


class GameRunningBinarySensor(FactorioEntity, BinarySensorEntity):
    _attr_device_class = BinarySensorDeviceClass.RUNNING

    def __init__(self, entry: FactorioConfigEntry) -> None:
        super().__init__(entry, Platform.BINARY_SENSOR, "game_running")

    @property
    def is_on(self) -> bool:
        return self._core.game_state == "running"
