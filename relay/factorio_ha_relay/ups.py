"""Real game speed (updates per second) from the ticks of the mod's heartbeats."""

from __future__ import annotations

from collections import deque


class UpsMeter:
    """Ticks per second over the heartbeats of the last `window` seconds.

    Pure: the caller passes a monotonic time with each heartbeat's tick. A tick lower than the
    previous one (a save was loaded) starts a new measurement; an equal one (a second heartbeat on
    the same tick, e.g. a player joined) is ignored.
    """

    def __init__(self, window: float = 60.0, min_span: float = 30.0) -> None:
        self._window = window
        self._min_span = min_span
        self._samples: deque[tuple[float, int]] = deque()

    def add(self, now: float, tick: int) -> None:
        if self._samples:
            last = self._samples[-1][1]
            if tick == last:
                return
            if tick < last:
                self._samples.clear()
        self._samples.append((now, tick))
        while now - self._samples[0][0] > self._window:
            self._samples.popleft()

    def reset(self) -> None:
        self._samples.clear()

    def value(self) -> float | None:
        """Ticks per second rounded to 0.1, or None until the samples span `min_span` seconds."""
        if len(self._samples) < 2:
            return None
        (t0, tick0), (t1, tick1) = self._samples[0], self._samples[-1]
        if t1 - t0 < self._min_span:
            return None
        return round((tick1 - tick0) / (t1 - t0), 1)
