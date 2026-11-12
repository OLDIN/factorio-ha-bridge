# Release 0.3.0

Released: 2026-11-12

## ✨ Features

- feat(relay): game clock topic for game-time rules
- feat(mod): machines and drills categories (production lines, depleted drills)
- feat(mod): production groups and status buckets (pure logic)

## 🐛 Bug Fixes

- fix(mod): cheap trim, per-category publish, ready-after-lap, lean machine scan

## 🔄 Update Instructions

1. Mod: published to the Factorio mod portal automatically; players get it when they join
2. Server: `deploy/update.sh` (relay + mod; asks before restarting the game)
