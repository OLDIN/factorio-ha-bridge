"""Config flow: manual or MQTT discovery (factorio/+/hello), then what to collect."""

from __future__ import annotations

import re
from typing import Any

import voluptuous as vol
from homeassistant.config_entries import ConfigEntry, ConfigFlow, ConfigFlowResult, OptionsFlow
from homeassistant.core import callback
from homeassistant.helpers.selector import SelectSelector, SelectSelectorConfig
from homeassistant.helpers.service_info.mqtt import MqttServiceInfo

from .const import CATEGORIES, CONF_PROVIDER, CONF_SERVER_ID, DOMAIN, PROVIDER_MQTT, PROVIDERS, TOPIC_PREFIX

SERVER_ID_RE = re.compile(r"^[a-z0-9_-]+$")


def _categories_schema(current: dict[str, Any]) -> vol.Schema:
    return vol.Schema({vol.Optional(c, default=bool(current.get(c, True))): bool for c in CATEGORIES})


def _categories(user_input: dict[str, Any]) -> dict[str, bool]:
    return {c: bool(user_input.get(c, True)) for c in CATEGORIES}


class FactorioConfigFlow(ConfigFlow, domain=DOMAIN):
    VERSION = 1

    def __init__(self) -> None:
        self._server_id: str | None = None
        self._provider = PROVIDER_MQTT

    async def async_step_user(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        errors: dict[str, str] = {}
        if user_input is not None:
            server_id = user_input[CONF_SERVER_ID].strip()
            if SERVER_ID_RE.match(server_id):
                await self.async_set_unique_id(server_id)
                self._abort_if_unique_id_configured()
                self._server_id = server_id
                self._provider = user_input[CONF_PROVIDER]
                return await self.async_step_categories()
            errors[CONF_SERVER_ID] = "invalid_server_id"
        schema = vol.Schema(
            {
                vol.Required(CONF_PROVIDER, default=PROVIDER_MQTT): SelectSelector(
                    SelectSelectorConfig(options=PROVIDERS, translation_key="provider")
                ),
                vol.Required(CONF_SERVER_ID): str,
            }
        )
        return self.async_show_form(step_id="user", data_schema=schema, errors=errors)

    async def async_step_mqtt(self, discovery_info: MqttServiceInfo) -> ConfigFlowResult:
        parts = discovery_info.topic.split("/")
        if (
            not discovery_info.payload
            or len(parts) != 3
            or parts[0] != TOPIC_PREFIX
            or not SERVER_ID_RE.match(parts[1])
        ):
            return self.async_abort(reason="invalid_discovery_info")
        await self.async_set_unique_id(parts[1])
        self._abort_if_unique_id_configured()
        self._server_id = parts[1]
        self.context["title_placeholders"] = {"server_id": parts[1]}
        return await self.async_step_confirm()

    async def async_step_confirm(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        if user_input is not None:
            return await self.async_step_categories()
        return self.async_show_form(step_id="confirm", description_placeholders={"server_id": self._server_id or ""})

    async def async_step_categories(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        if user_input is not None:
            return self.async_create_entry(
                title=f"Factorio {self._server_id}",
                data={CONF_PROVIDER: self._provider, CONF_SERVER_ID: self._server_id},
                options=_categories(user_input),
            )
        return self.async_show_form(step_id="categories", data_schema=_categories_schema({}))

    @staticmethod
    @callback
    def async_get_options_flow(config_entry: ConfigEntry) -> OptionsFlow:
        return FactorioOptionsFlow()


class FactorioOptionsFlow(OptionsFlow):
    async def async_step_init(self, user_input: dict[str, Any] | None = None) -> ConfigFlowResult:
        if user_input is not None:
            return self.async_create_entry(data=_categories(user_input))
        return self.async_show_form(step_id="init", data_schema=_categories_schema(dict(self.config_entry.options)))
