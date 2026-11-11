import pytest

from factorio_ha_relay.config import Settings


def test_from_env_defaults(tmp_path):
    pw = tmp_path / "rconpw"
    pw.write_text("s3cret\n")
    s = Settings.from_env({"FHA_SERVER_ID": "main", "FHA_MQTT_HOST": "10.0.0.2",
                           "FHA_RCON_PASSWORD_FILE": str(pw)})
    assert (s.server_id, s.udp_host, s.udp_port, s.mqtt_host, s.mqtt_port) == (
        "main", "127.0.0.1", 34199, "10.0.0.2", 1883)
    assert (s.rcon_host, s.rcon_port, s.rcon_password, s.heartbeat_timeout) == (
        "127.0.0.1", 27015, "s3cret", 15.0)


def test_requires_server_id():
    with pytest.raises(ValueError):
        Settings.from_env({"FHA_RCON_PASSWORD": "x"})


def test_requires_rcon_password():
    with pytest.raises(ValueError):
        Settings.from_env({"FHA_SERVER_ID": "main"})


@pytest.mark.parametrize("server_id", ["MAIN", "a/b", "x+y", "my server", "#"])
def test_server_id_must_match_ha_rules(server_id):
    """Final review: HA discovery accepts only [a-z0-9_-]+; MQTT wildcards break topics."""
    with pytest.raises(ValueError, match="FHA_SERVER_ID"):
        Settings.from_env({"FHA_SERVER_ID": server_id, "FHA_RCON_PASSWORD": "x"})


@pytest.mark.parametrize("make", [lambda d: d / "missing", lambda d: d])
def test_rcon_password_file_problems_are_clear(tmp_path, make):
    """Final review #3: a wrong bind path (docker creates a directory) must give a clear error."""
    with pytest.raises(ValueError, match="FHA_RCON_PASSWORD_FILE"):
        Settings.from_env({"FHA_SERVER_ID": "main", "FHA_RCON_PASSWORD_FILE": str(make(tmp_path))})
