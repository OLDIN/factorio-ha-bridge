"""Game state rules (docs/protocol.md, "Game state")."""

from __future__ import annotations

DEFAULT_HEARTBEAT_TIMEOUT = 15.0


def compute_game_state(
    rcon_alive: bool,
    heartbeat_age: float | None,
    players_online: int | None,
    timeout: float = DEFAULT_HEARTBEAT_TIMEOUT,
) -> tuple[str, str | None]:
    """Return (game_state, reason) from what the relay can observe locally."""
    if not rcon_alive:
        return "stopped", None
    if heartbeat_age is not None and heartbeat_age <= timeout:
        return "running", None
    if players_online == 0:
        return "paused", "no_players"
    return "paused", "unknown"
