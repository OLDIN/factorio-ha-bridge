import pytest

from factorio_ha_relay.game_state import compute_game_state


@pytest.mark.parametrize(
    "alive,age,players,expected",
    [
        (False, 1.0, 1, ("stopped", None)),
        (False, None, None, ("stopped", None)),
        (True, 3.0, 1, ("running", None)),
        (True, 20.0, 0, ("paused", "no_players")),
        (True, 20.0, 2, ("paused", "unknown")),
        (True, None, None, ("paused", "unknown")),
        (True, None, 0, ("paused", "no_players")),
    ],
)
def test_compute_game_state(alive, age, players, expected):
    assert compute_game_state(alive, age, players) == expected


def test_timeout_is_configurable():
    assert compute_game_state(True, 20.0, 1, timeout=30.0) == ("running", None)
