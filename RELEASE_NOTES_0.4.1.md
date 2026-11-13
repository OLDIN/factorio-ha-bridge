# Release 0.4.1

Released: 2026-11-13

## 🐛 Bug Fixes

- fix(mod): search each planet for player buildings once per session (spike every 60 s)
- fix(mod): trim the machines category without extra whole-category encodes (spike every 10 s)

## 🔄 Update Instructions

1. Mod: published to the Factorio mod portal automatically; players get it when they join
2. Server: `deploy/update.sh` (relay + mod; asks before restarting the game)
