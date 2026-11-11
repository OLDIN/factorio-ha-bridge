"""Reassembly of multi-part snapshots (protocol v1, 2a: ``part`` / ``parts``)."""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

from .protocol import ModMessage

_LOGGER = logging.getLogger(__name__)


@dataclass
class _Pending:
    tick: int
    parts: int
    chunks: dict[int, dict[str, Any]] = field(default_factory=dict)


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


class SnapshotAssembler:
    """Joins the parts of one snapshot (same ``tick``) into a single message.

    A set is complete when all its parts arrived; an incomplete set is dropped as soon
    as a part (or a plain snapshot) with a newer tick shows up.
    """

    def __init__(self) -> None:
        self._pending: _Pending | None = None

    def add(self, msg: ModMessage) -> ModMessage | None:
        if msg.type != "snapshot":
            return msg
        part, parts = msg.body.get("part"), msg.body.get("parts")
        if part is None and parts is None:
            self._drop_if_older(msg.tick)
            return msg
        if not (_is_int(part) and _is_int(parts) and 1 <= part <= parts):
            _LOGGER.warning("Ignored snapshot with bad part numbers: part=%r parts=%r", part, parts)
            return None
        pending = self._pending
        if pending is not None and msg.tick < pending.tick:
            return None  # a late part of a set that was already replaced
        if pending is None or msg.tick > pending.tick or pending.parts != parts:
            self._drop_if_older(msg.tick)
            pending = self._pending = _Pending(tick=msg.tick, parts=parts)
        if part in pending.chunks:
            return None  # duplicate
        data = msg.body.get("data")
        pending.chunks[part] = data if isinstance(data, dict) else {}
        if len(pending.chunks) < pending.parts:
            return None
        self._pending = None
        combined: dict[str, Any] = {}
        for number in sorted(pending.chunks):
            combined.update(pending.chunks[number])
        body = {k: v for k, v in msg.body.items() if k not in ("part", "parts", "data")}
        body["data"] = combined
        return ModMessage(type="snapshot", tick=pending.tick, body=body)

    def _drop_if_older(self, tick: int) -> None:
        if self._pending is not None and self._pending.tick < tick:
            _LOGGER.warning(
                "Dropped incomplete snapshot (tick %s: %s of %s parts)",
                self._pending.tick, len(self._pending.chunks), self._pending.parts,
            )
            self._pending = None
