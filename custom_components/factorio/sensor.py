"""Sensors: game state and players online."""

from __future__ import annotations

from typing import Any

from homeassistant.components.sensor import SensorDeviceClass, SensorEntity, SensorStateClass
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from . import FactorioConfigEntry
from .const import GAME_STATES
from .entity import FactorioEntity


async def async_setup_entry(
    hass: HomeAssistant, entry: FactorioConfigEntry, async_add_entities: AddConfigEntryEntitiesCallback
) -> None:
    async_add_entities([GameStateSensor(entry), PlayersOnlineSensor(entry)])


class GameStateSensor(FactorioEntity, SensorEntity):
    _attr_device_class = SensorDeviceClass.ENUM
    _attr_options = GAME_STATES

    def __init__(self, entry: FactorioConfigEntry) -> None:
        super().__init__(entry, Platform.SENSOR, "game_state")

    @property
    def native_value(self) -> str | None:
        return self._core.game_state

    @property
    def extra_state_attributes(self) -> dict[str, Any]:
        return {"reason": self._core.game_state_reason, "since": self._core.game_state_since}


class PlayersOnlineSensor(FactorioEntity, SensorEntity):
    _attr_state_class = SensorStateClass.MEASUREMENT

    def __init__(self, entry: FactorioConfigEntry) -> None:
        super().__init__(entry, Platform.SENSOR, "players_online")

    @property
    def native_value(self) -> int | None:
        return self._core.players_online

    @property
    def extra_state_attributes(self) -> dict[str, Any] | None:
        players = self._core.players
        return None if players is None else {"players": players}
