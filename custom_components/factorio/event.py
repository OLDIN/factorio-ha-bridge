"""Event entity: one-shot game events (player joined/left)."""

from __future__ import annotations

from typing import Any

from homeassistant.components.event import EventEntity
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from . import FactorioConfigEntry
from .const import EVENT_TYPES
from .entity import FactorioEntity


async def async_setup_entry(
    hass: HomeAssistant, entry: FactorioConfigEntry, async_add_entities: AddConfigEntryEntitiesCallback
) -> None:
    async_add_entities([GameEventsEntity(entry)])


class GameEventsEntity(FactorioEntity, EventEntity):
    _attr_event_types = EVENT_TYPES

    def __init__(self, entry: FactorioConfigEntry) -> None:
        super().__init__(entry, Platform.EVENT, "game_events")

    async def async_added_to_hass(self) -> None:
        # Only events matter here, not state changes.
        self.async_on_remove(self._core.add_event_listener(self._handle_game_event))

    @callback
    def _handle_game_event(self, name: str, data: dict[str, Any]) -> None:
        if name in EVENT_TYPES:
            # Game data must not override the event_type attribute HA sets.
            self._trigger_event(name, {k: v for k, v in data.items() if k != "event_type"})
            self.async_write_ha_state()
