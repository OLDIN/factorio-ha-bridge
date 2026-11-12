# Release 0.2.0

Released: 2026-11-12

## ✨ Features

- feat(mod): attacks merged by time and distance; AFK and player deaths
- feat(mod): turret ammo/power and damaged walls per planet
- feat(mod): planets, research and evolution categories
- feat(relay): per-category data topics, multi-part snapshots, no config resend on periodic hello

## 🐛 Bug Fixes

- fix: final review — player-force research, turret revive/clone, drop wall migrate, docs
- fix(mod): safe initial turret fill, capped per step
- fix(relay): bounded seed read, retained messages only

## 📝 Documentation

- docs: protocol and categories for 2a

## 🔧 Other Changes

- perf(mod): check damaged walls in portions
- refactor(mod): split into modules; hello reason; multi-part snapshots
- chore: dev server with Space Age and extra mods

## 🔄 Update Instructions

1. Mod: published to the Factorio mod portal automatically; players get it when they join
2. Server: `deploy/update.sh` (relay + mod; asks before restarting the game)
