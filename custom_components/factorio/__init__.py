"""Factorio: live server state from the factorio-ha mod and relay."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any

from homeassistant.config_entries import ConfigEntry
from homeassistant.const import Platform
from homeassistant.core import HomeAssistant, callback
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers import device_registry as dr

from .const import CONF_SERVER_ID, DOMAIN
from .core import FactorioCore, build_config
from .providers import create_provider
from .providers.base import Provider

_LOGGER = logging.getLogger(__name__)
PLATFORMS = [Platform.BINARY_SENSOR, Platform.SENSOR, Platform.EVENT]


@dataclass
class FactorioRuntime:
    core: FactorioCore
    provider: Provider


type FactorioConfigEntry = ConfigEntry[FactorioRuntime]


async def async_setup_entry(hass: HomeAssistant, entry: FactorioConfigEntry) -> bool:
    server_id: str = entry.data[CONF_SERVER_ID]
    core = FactorioCore(server_id)
    provider = create_provider(hass, entry)
    entry.runtime_data = FactorioRuntime(core=core, provider=provider)

    @callback
    def fire_bus_event(name: str, data: dict[str, Any]) -> None:
        hass.bus.async_fire(f"{DOMAIN}_{name}", {"server_id": server_id, **data})

    known_version: dict[str, str | None] = {"mod": None}

    @callback
    def update_device_version() -> None:
        if core.mod_version == known_version["mod"]:
            return
        registry = dr.async_get(hass)
        device = registry.async_get_device(identifiers={(DOMAIN, server_id)})
        if device is not None:
            known_version["mod"] = core.mod_version
            registry.async_update_device(device.id, sw_version=core.mod_version)

    entry.async_on_unload(core.add_event_listener(fire_bus_event))
    entry.async_on_unload(core.add_listener(update_device_version))

    await provider.async_start(core.handle_message)
    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    await provider.async_send_config(build_config(entry.options))
    entry.async_on_unload(entry.add_update_listener(_async_options_updated))
    return True


async def _async_options_updated(hass: HomeAssistant, entry: FactorioConfigEntry) -> None:
    await entry.runtime_data.provider.async_send_config(build_config(entry.options))


async def async_unload_entry(hass: HomeAssistant, entry: FactorioConfigEntry) -> bool:
    unloaded = await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
    if unloaded:
        await entry.runtime_data.provider.async_stop()
    return unloaded


async def async_remove_entry(hass: HomeAssistant, entry: FactorioConfigEntry) -> None:
    """Integration removed: clear the retained config so the mod stops collecting."""
    try:
        await create_provider(hass, entry).async_send_config(None)
    except HomeAssistantError as err:
        _LOGGER.warning("Could not clear the Factorio config for %s: %s", entry.data[CONF_SERVER_ID], err)
