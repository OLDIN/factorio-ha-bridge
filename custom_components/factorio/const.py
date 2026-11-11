"""Constants for the Factorio integration."""

DOMAIN = "factorio"
TOPIC_PREFIX = "factorio"

CONF_PROVIDER = "provider"
CONF_SERVER_ID = "server_id"
PROVIDER_MQTT = "mqtt"
PROVIDERS = [PROVIDER_MQTT]

GAME_STATES = ["running", "paused", "stopped", "no_connection"]
EVENT_TYPES = ["player_joined", "player_left"]
CATEGORIES = ["players"]
PROTOCOL_VERSION = 1
