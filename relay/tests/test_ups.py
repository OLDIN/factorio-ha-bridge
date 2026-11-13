from factorio_ha_relay.ups import UpsMeter


def feed(meter: UpsMeter, *, start: float, seconds: float, every: float, ticks: int, tick0: int) -> tuple[float, int]:
    """Heartbeats every `every` seconds advancing `ticks` each; returns the last (time, tick)."""
    now, tick = start, tick0
    meter.add(now, tick)
    while now - start < seconds:
        now += every
        tick += ticks
        meter.add(now, tick)
    return now, tick


def test_steady_60():
    meter = UpsMeter()
    feed(meter, start=1000.0, seconds=60, every=5, ticks=300, tick0=3000)
    assert meter.value() == 60.0


def test_half_speed():
    meter = UpsMeter()
    feed(meter, start=1000.0, seconds=60, every=10, ticks=300, tick0=3000)
    assert meter.value() == 30.0


def test_double_speed():
    meter = UpsMeter()
    feed(meter, start=1000.0, seconds=60, every=5, ticks=600, tick0=3000)
    assert meter.value() == 120.0


def test_short_span_is_none():
    meter = UpsMeter()
    meter.add(1000.0, 3000)
    assert meter.value() is None  # one sample
    feed(meter, start=1000.0, seconds=25, every=5, ticks=300, tick0=3000)
    assert meter.value() is None  # 25 s < 30 s


def test_tick_back_resets():
    meter = UpsMeter()
    now, tick = feed(meter, start=1000.0, seconds=60, every=5, ticks=300, tick0=90000)
    meter.add(now + 5, tick - 50000)  # a save was loaded: the tick went back
    assert meter.value() is None


def test_duplicate_tick_is_ignored():
    meter = UpsMeter()
    now, tick = feed(meter, start=1000.0, seconds=60, every=5, ticks=300, tick0=3000)
    meter.add(now + 0.1, tick)  # a player joined on the heartbeat tick: a second heartbeat, same tick
    assert meter.value() == 60.0


def test_window_drops_old():
    meter = UpsMeter()
    now, tick = feed(meter, start=1000.0, seconds=60, every=5, ticks=300, tick0=3000)
    feed(meter, start=now, seconds=60, every=5, ticks=150, tick0=tick)
    assert meter.value() == 30.0


def test_reset():
    meter = UpsMeter()
    feed(meter, start=1000.0, seconds=60, every=5, ticks=300, tick0=3000)
    meter.reset()
    assert meter.value() is None
