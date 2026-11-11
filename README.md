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

## Deploy (next to a factoriotools/factorio container)

1. Install the mod on the server (mod portal: `factorio-ha`).
2. Factorio service: `network_mode: host`, `command: ["--enable-lua-udp=34198"]`.
3. `cp deploy/.env.example deploy/.env` and fill in MQTT settings.
4. `FACTORIO_DATA_DIR=<your factorio data dir> docker compose -f <factorio compose> -f deploy/docker-compose.relay.yml up -d --build`

## Roadmap

What is done and what is planned (sensors, events, attacks, production lines,
space platforms…) is tracked in one place:
[ha-factorio → Roadmap](https://github.com/OLDIN/ha-factorio#roadmap).

## Releasing the mod

Bump `version` in `mod/factorio-ha/info.json`, add a `Version: X.Y.Z` entry to
`mod/factorio-ha/changelog.txt` and merge to `main`. The `Publish mod` workflow
uploads it to the mod portal (skipped if that version is already there) and tags
`mod-vX.Y.Z`. It needs the repository secret `FACTORIO_API_KEY`
(factorio.com → profile → API keys, usage "ModPortal: Upload Mods").

## Development

```bash
cd relay && uv venv .venv && uv pip install -e ".[test]" && .venv/bin/pytest -q
scripts/dev-server.sh            # local headless Factorio with the mod (RCON 127.0.0.1:27015, password "dev")
python3 scripts/udp-dump.py      # print what the mod sends
scripts/package-mod.sh           # dist/factorio-ha_<version>.zip
```
