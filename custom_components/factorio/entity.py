"""Base entity: ids from internal names, never unavailable."""

from __future__ import annotations

from typing import TYPE_CHECKING

from homeassistant.core import callback
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity import Entity
from homeassistant.util import slugify

from .const import DOMAIN

if TYPE_CHECKING:
    from . import FactorioConfigEntry


class FactorioEntity(Entity):
    _attr_has_entity_name = True
    _attr_should_poll = False

    def __init__(self, entry: FactorioConfigEntry, platform: str, key: str) -> None:
        self._core = entry.runtime_data.core
        server_id = self._core.server_id
        self._attr_translation_key = key
        self._attr_unique_id = f"{server_id}_{key}"
        # Internal names, independent of the UI language (spec: ids never change).
        self.entity_id = f"{platform}.factorio_{slugify(server_id)}_{key}"
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, server_id)},
            name=f"Factorio {server_id}",
            manufacturer="factorio-ha",
            model="Factorio server",
        )

    @property
    def available(self) -> bool:
        # Data entities never go unavailable; connection entities show the link state.
        return True

    async def async_added_to_hass(self) -> None:
        self.async_on_remove(self._core.add_listener(self._handle_core_update))

    @callback
    def _handle_core_update(self) -> None:
        self.async_write_ha_state()
