# Release 0.4.0

Released: 2026-11-12

## ✨ Features

- feat(mod): machines on space platforms (by_platform groups); rebuild the machine registry after an update
- feat(mod): platforms category: where each platform is or flies, damage and travel events
- feat(mod): platform route direction, state transitions and damage episodes (pure logic)
- feat(mod): output full counts as stopped only when HA asks; planet-level status counters

## 🔄 Update Instructions

1. Mod: published to the Factorio mod portal automatically; players get it when they join
2. Server: `deploy/update.sh` (relay + mod; asks before restarting the game)
