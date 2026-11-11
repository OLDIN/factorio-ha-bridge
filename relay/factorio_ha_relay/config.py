"""Relay settings from environment variables (FHA_*)."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    server_id: str
    rcon_password: str
    udp_host: str = "127.0.0.1"
    udp_port: int = 34199
    mqtt_host: str = "localhost"
    mqtt_port: int = 1883
    mqtt_user: str | None = None
    mqtt_password: str | None = None
    rcon_host: str = "127.0.0.1"
    rcon_port: int = 27015
    heartbeat_timeout: float = 15.0

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> Settings:
        server_id = env.get("FHA_SERVER_ID", "").strip()
        if not server_id:
            raise ValueError("FHA_SERVER_ID is required")
        password = env.get("FHA_RCON_PASSWORD")
        if not password and env.get("FHA_RCON_PASSWORD_FILE"):
            password = Path(env["FHA_RCON_PASSWORD_FILE"]).read_text().strip()
        if not password:
            raise ValueError("FHA_RCON_PASSWORD or FHA_RCON_PASSWORD_FILE is required")
        return cls(
            server_id=server_id,
            rcon_password=password,
            udp_host=env.get("FHA_UDP_HOST", "127.0.0.1"),
            udp_port=int(env.get("FHA_UDP_PORT", "34199")),
            mqtt_host=env.get("FHA_MQTT_HOST", "localhost"),
            mqtt_port=int(env.get("FHA_MQTT_PORT", "1883")),
            mqtt_user=env.get("FHA_MQTT_USER") or None,
            mqtt_password=env.get("FHA_MQTT_PASSWORD") or None,
            rcon_host=env.get("FHA_RCON_HOST", "127.0.0.1"),
            rcon_port=int(env.get("FHA_RCON_PORT", "27015")),
            heartbeat_timeout=float(env.get("FHA_HEARTBEAT_TIMEOUT", "15")),
        )
