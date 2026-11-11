# factorio-ha-bridge

The game side of Factorio → Home Assistant: a Factorio mod and a small relay
that runs next to the server. The Home Assistant integration lives in
[ha-factorio](https://github.com/OLDIN/ha-factorio).

```
Factorio mod ──UDP──▶ relay ──MQTT──▶ Home Assistant (ha-factorio)
             ◀─RCON──        ◀─MQTT──  config: what to collect
```

Status: proof of concept. Protocol: [docs/protocol.md](docs/protocol.md).

| Part | Path |
|---|---|
| Factorio mod `factorio-ha` (Factorio 2.1) | `mod/factorio-ha/` |
| Relay (Python, Docker) | `relay/` |
| Deployment next to `factoriotools/factorio` | `deploy/` |
| Local dev server, packaging | `scripts/` |

## What the mod reports

Each category is switched on from Home Assistant; nothing is sent until the relay
delivers a config.

| Category | Shows |
|---|---|
| `players` | who is online, AFK minutes; events `player_joined`, `player_left`, `player_died` |
| `planets` | every space location: kind, position, parent, locked / unlocked / built |
| `research` | current research (progress, unlocked planets), queue; event `research_finished` |
| `evolution` | enemy evolution per planet |
| `defense` | per planet: turrets without ammo or power, damaged walls, running attack; events `attack_started`, `attack_ended`, `turrets_no_ammo`, `turrets_ok` |

Details and the wire format: [docs/protocol.md](docs/protocol.md).

## Deploy (next to a factoriotools/factorio container)

1. Install the mod on the server (mod portal: `factorio-ha`).
2. Factorio service: `network_mode: host`, `command: ["--enable-lua-udp=34198"]`.
3. `cp deploy/.env.example deploy/.env` and fill in MQTT settings.
4. `FACTORIO_DATA_DIR=<your factorio data dir> docker compose -f <factorio compose> -f deploy/docker-compose.relay.yml up -d --build`

## Roadmap

What is done and what is planned (sensors, events, attacks, production lines,
space platforms…) is tracked in one place:
[ha-factorio → Roadmap](https://github.com/OLDIN/ha-factorio#roadmap).

## Updating on the server

```bash
/opt/factorio-ha-bridge/deploy/update.sh          # relay + mod (asks before restarting the game)
/opt/factorio-ha-bridge/deploy/update.sh relay    # only the relay; the game keeps running
/opt/factorio-ha-bridge/deploy/update.sh mod      # only the mod, if the mod portal has a newer version
```

The relay is rebuilt from `git pull` (unchanged code reuses the Docker cache, so the
container is left alone). A newer mod is installed with `factorio-add-mods.sh`, which
restarts the game. Paths and mod portal credentials can go in
`/root/.factorio-ha-update.env` (see the top of the script).

## Releasing

```bash
python3 scripts/bump_version.py patch --pr   # or minor / major
```

Bumps one version everywhere (mod `info.json`, relay `pyproject.toml` and
`__init__.py`), adds a `changelog.txt` entry for the mod, writes
`RELEASE_NOTES_X.Y.Z.md` from the commits since the last `v*` tag and opens a PR.
After the merge:

- `Release` tags `vX.Y.Z` and publishes the GitHub Release;
- `Publish mod` uploads the mod to the Factorio mod portal (skipped if that version is
  already there). It needs the repository secret `FACTORIO_API_KEY`
  (factorio.com → profile → API keys, usage "ModPortal: Upload Mods").

## Development

```bash
cd relay && uv venv .venv && uv pip install -e ".[test]" && .venv/bin/pytest -q
scripts/dev-server.sh            # local headless Factorio with the mod (RCON 127.0.0.1:27015, password "dev")
python3 scripts/udp-dump.py      # print what the mod sends
scripts/package-mod.sh           # dist/factorio-ha_<version>.zip
```
