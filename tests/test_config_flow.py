"""Config and options flows."""

from unittest.mock import patch

import pytest
from homeassistant.config_entries import SOURCE_MQTT, SOURCE_USER
from homeassistant.core import HomeAssistant
from homeassistant.data_entry_flow import FlowResultType
from homeassistant.helpers.service_info.mqtt import MqttServiceInfo
from pytest_homeassistant_custom_component.common import MockConfigEntry

from custom_components.factorio.const import DOMAIN

DATA = {"provider": "mqtt", "server_id": "main"}


@pytest.fixture(autouse=True)
def auto_enable_custom_integrations(enable_custom_integrations):
    yield


@pytest.fixture(autouse=True)
def skip_entry_setup():
    with patch("custom_components.factorio.async_setup_entry", return_value=True):
        yield


def discovery(topic="factorio/main/hello", payload='{"v":1,"server_id":"main"}') -> MqttServiceInfo:
    return MqttServiceInfo(topic=topic, payload=payload, qos=1, retain=True,
                           subscribed_topic="factorio/+/hello", timestamp=0)


async def test_user_flow_creates_entry(hass: HomeAssistant, mqtt_mock):
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_USER})
    assert (result["type"], result["step_id"]) == (FlowResultType.FORM, "user")
    result = await hass.config_entries.flow.async_configure(result["flow_id"], DATA)
    assert (result["type"], result["step_id"]) == (FlowResultType.FORM, "categories")
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"players": True})
    assert result["type"] == FlowResultType.CREATE_ENTRY
    assert result["title"] == "Factorio main"
    assert result["data"] == DATA
    assert result["options"] == {"players": True}


async def test_user_flow_rejects_bad_server_id(hass: HomeAssistant, mqtt_mock):
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_USER})
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"provider": "mqtt", "server_id": "Bad ID!"})
    assert result["errors"] == {"server_id": "invalid_server_id"}


async def test_mqtt_discovery_flow(hass: HomeAssistant, mqtt_mock):
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_MQTT}, data=discovery())
    assert (result["type"], result["step_id"]) == (FlowResultType.FORM, "confirm")
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {})
    assert result["step_id"] == "categories"
    result = await hass.config_entries.flow.async_configure(result["flow_id"], {"players": True})
    assert result["type"] == FlowResultType.CREATE_ENTRY
    assert result["data"] == DATA


async def test_discovery_with_empty_payload_aborts(hass: HomeAssistant, mqtt_mock):
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_MQTT},
                                                       data=discovery(payload=""))
    assert result["type"] == FlowResultType.ABORT


async def test_duplicate_aborts(hass: HomeAssistant, mqtt_mock):
    MockConfigEntry(domain=DOMAIN, unique_id="main", data=DATA).add_to_hass(hass)
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_MQTT}, data=discovery())
    assert (result["type"], result["reason"]) == (FlowResultType.ABORT, "already_configured")
    result = await hass.config_entries.flow.async_init(DOMAIN, context={"source": SOURCE_USER})
    result = await hass.config_entries.flow.async_configure(result["flow_id"], DATA)
    assert (result["type"], result["reason"]) == (FlowResultType.ABORT, "already_configured")


async def test_options_flow_toggles_players(hass: HomeAssistant, mqtt_mock):
    entry = MockConfigEntry(domain=DOMAIN, unique_id="main", data=DATA, options={"players": True})
    entry.add_to_hass(hass)
    result = await hass.config_entries.options.async_init(entry.entry_id)
    assert result["step_id"] == "init"
    result = await hass.config_entries.options.async_configure(result["flow_id"], {"players": False})
    assert result["type"] == FlowResultType.CREATE_ENTRY
    assert entry.options == {"players": False}
