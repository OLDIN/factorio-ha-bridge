# factorio-ha protocol v1

Three hops:

```
Factorio mod ──UDP (localhost)──▶ relay ──MQTT──▶ Home Assistant integration
             ◀──RCON command────        ◀──MQTT──  (config: what to collect)
```

All payloads are JSON objects carrying `"v": 1`.

## Mod → relay (UDP)

One JSON object per datagram, sent by the game server only
(`helpers.send_udp(port, json, 0)`) to `127.0.0.1:<relay port>` (default `34199`).
The game itself binds the port given to `--enable-lua-udp` (we use `34198`).

```json
{"v":1,"type":"hello","tick":123,"mod_version":"0.1.0"}
{"v":1,"type":"heartbeat","tick":123,"players_online":1}
{"v":1,"type":"snapshot","tick":123,"data":{"players":{"online":["alice"]}}}
{"v":1,"type":"update","tick":123,"data":{"players":{"online":["alice","guest"]}}}
{"v":1,"type":"event","tick":123,"event":"player_joined","data":{"player":"guest"}}
```

| type | when | notes |
|---|---|---|
| `hello` | `on_init`, `on_configuration_changed`, every 3600 ticks | relay re-sends the last config when it sees one (2a: not on `reason: "periodic"`) |
| `heartbeat` | every 300 ticks, and right after a player leaves | `players_online` is always present, even with the `players` category off |
| `snapshot` | every 3600 ticks while a category is enabled, and always once right after a config is accepted | replaces **all** categories (so it also clears categories just turned off) |
| `update` | when a category's data changes | replaces only the categories it contains |
| `event` | one-shot facts (`player_joined`, `player_left`) | only for enabled categories |

Until a config arrives the mod sends **only** `hello` and `heartbeat`.

`helpers.table_to_json` encodes an empty table as `[]`; receivers treat
`"data": []` as `{}` and `"online": {}` as `[]`.

## Home Assistant → mod (config)

HA writes a retained MQTT message to `factorio/<server_id>/config`:

```json
{"v":1,"categories":{"players":true}}
```

The relay forwards it as the RCON command `/factorio-ha-config <json>`
(the mod answers `ok` or `error: <reason>`; the command is refused for
in-game players). An empty payload (integration removed) is forwarded as
`{"v":1,"categories":{}}`, which turns everything off.

The relay re-sends the last config when: a new config arrives, RCON
(re)connects, or the mod sends `hello`.

## Relay → MQTT

Topic prefix is fixed: `factorio`. JSON is compact (`separators=(",", ":")`).

| topic | retained | payload |
|---|---|---|
| `factorio/<id>/availability` | yes, last will `offline` | `online` / `offline` |
| `factorio/<id>/hello` | yes | `{"v":1,"server_id":"main","relay_version":"0.1.0","mod_version":"0.1.0"}` (`mod_version` is `null` until the mod says hello) |
| `factorio/<id>/state` | yes | `{"v":1,"game_state":"running","game_state_reason":null,"game_state_since":"<ISO-8601 UTC>","tick":123,"players_online":1,"data":{"players":{"online":["alice"]}}}` — published only when something other than `tick` changes |
| `factorio/<id>/event` | no | `{"v":1,"event":"player_joined","tick":123,"time":"<ISO-8601 UTC>","data":{"player":"guest"}}` |
| `factorio/<id>/config` | yes, written by HA | see above |

On startup the relay reads its own retained `state` and `hello` and continues from
them, so a relay restart never blanks the last known values or the mod version.

## Game state (computed by the relay every second)

| RCON connection | heartbeat within 15 s | `game_state` | `game_state_reason` |
|---|---|---|---|
| down | — | `stopped` | `null` |
| up | yes | `running` | `null` |
| up | no, last `players_online == 0` | `paused` | `no_players` |
| up | no, otherwise (or never seen) | `paused` | `unknown` |

`no_connection` is derived by the HA integration from `availability = offline`.

The relay keeps one persistent authenticated RCON connection: a live
connection means the Factorio process is alive. Commands time out without
dropping the connection, because a paused game may not answer them.

## 2a additions (planets, research, evolution, defense)

### Mod → relay

```json
{"v":1,"type":"hello","tick":1,"mod_version":"0.2.0","reason":"init"}
{"v":1,"type":"snapshot","tick":9,"part":1,"parts":2,"data":{"planets":{...},"research":{...}}}
```

- `hello.reason`: `init` | `configuration_changed` | `periodic`. The relay re-sends the
  config on a `hello` only when `reason != "periodic"`; a hello without `reason` (old mod)
  is treated as before and re-sends it.
- `part` / `parts`: a snapshot is split **by category** (a category is never cut in half).
  The relay applies the snapshot once all parts with the same `tick` have arrived; an
  incomplete set is dropped as soon as a part with a newer `tick` arrives. A snapshot
  without `part`/`parts` is complete as is.
- After a config the mod sends a full snapshot only if the config changed or this is the
  first config since the game was loaded.

### Categories (`data.<category>`)

```json
"planets":  {"bodies":[{"name":"nauvis","kind":"planet","x":0.0,"y":-15.0,"distance":15,"orientation":0.275,
                        "magnitude":1.0,"parent":null,"state":"built","unlocked_by":null}]}
"research": {"current":{"name":"planet-discovery-maraxsis","level":1,"progress":0.62,"unlocks":["maraxsis"]},
             "queue":["up to 5 names"]}
"evolution":{"by_planet":{"nauvis":0.92,"gleba":0.61}}
"defense":  {"by_planet":{"nauvis":{"turrets":{"total":120,"no_ammo":6,"no_power":0,"no_ammo_at":[[10,-4]]},
                                    "walls_damaged":{"count":12,"at":[[-412,1180]]},
                                    "attack":{"since_tick":100,"position":[-412,1180],"gps":"[gps=-412,1180,nauvis]",
                                              "losses":{"gun-turret":4,"stone-wall":12}}}}}
"players":  {"online":["alice","guest"],"afk_minutes":{"guest":4}}
```

- `state`: `locked` | `unlocked` | `built`. `parent`: the name of the body whose position
  equals this body's `origin` (tolerance `0.01`), otherwise `null`. Bodies with
  `hidden = true` are not sent.
- `attack` is absent when there is no attack. Position lists (`no_ammo_at`, `at`) hold at
  most 5 entries.
- Empty Lua tables arrive as `[]`: the relay turns an empty top-level category `[]` into
  `{}`; deeper levels are the consumer's job.

### New events

| event | data |
|---|---|
| `attack_started` | `planet`, `surface`, `position` `[x,y]`, `gps` |
| `attack_ended` | same, plus `duration_s`, `losses` `{name: count}` |
| `turrets_no_ammo` | `planet`, `count` |
| `turrets_ok` | `planet` |
| `research_finished` | `name`, `level` |
| `player_died` | `player`, `planet` (or `null`), `surface`, `cause` (or `null`) |

### Relay → MQTT

| topic | retained | payload |
|---|---|---|
| `factorio/<id>/data/<category>` | yes | `{"v":1,"tick":123,"data":{...}}`; an empty payload means the category was switched off |

- Published only when the category's content changes (a category removed by a full
  snapshot gets the empty retained payload). The category name must match `^[a-z_]+$`,
  otherwise the relay logs a warning and skips it.
- `state.data` keeps **only** `players`, so integrations written for 0.1.x keep working;
  all other categories live in `data/*` only.
- On startup the relay also reads its own retained `data/*` topics; fresh game data wins
  over the retained copy, and only categories not yet known are filled from it.
