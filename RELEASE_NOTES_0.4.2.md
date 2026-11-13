# Release 0.4.2

Released: 2026-11-13

## ✨ Features

- feat(relay): UPS measurement restarts when players return after an auto-pause
- feat(relay): UPS, server start time and game version in state/hello
- feat(relay): UPS meter from heartbeat ticks (pure)

## 🔧 Other Changes

- refactor(mod): drop a pending machines publish built with an older line rule
- perf(mod): no 600-tick updates on snapshot ticks
- perf(mod): update production records in place
- perf(mod): build planet static data on init/load, not in the first snapshot
- perf(mod): spread the machines publish over three scanner steps
- perf(mod): O(1) scanner removal; no registry compaction at lap start
- perf(mod): snapshot reuses the last machines publish; planets with machines need no surface search
- perf(mod): trim machines on an exact size estimate; positions without sorting every stopped id
- perf(mod): encode each category once; build update/snapshot envelopes from the encoded JSON
- refactor(mod): defense attack state no longer shadows state(); unused loop variable
- ci: mod tests on Lua 5.2 with luacheck, relay ruff and pytest on every PR
- test(mod): no integer division operator, so the tests run on Lua 5.2 like the game

## 🔄 Update Instructions

1. Mod: published to the Factorio mod portal automatically; players get it when they join
2. Server: `deploy/update.sh` (relay + mod; asks before restarting the game)
