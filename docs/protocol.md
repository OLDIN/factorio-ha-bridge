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
{"v":1,"type":"hello","tick":123,"mod_version":"0.2.0","reason":"periodic"}
{"v":1,"type":"heartbeat","tick":123,"players_online":1}
{"v":1,"type":"snapshot","tick":123,"data":{"players":{"online":["alice"]}}}
{"v":1,"type":"update","tick":123,"data":{"players":{"online":["alice","guest"]}}}
{"v":1,"type":"event","tick":123,"event":"player_joined","data":{"player":"guest"}}
```

| type | when | notes |
|---|---|---|
| `hello` | `on_init` (`reason: "init"`), `on_configuration_changed` (`"configuration_changed"`), every 3600 ticks (`"periodic"`) | relay re-sends the last config when it sees one, except on `reason: "periodic"` |
| `heartbeat` | every 300 ticks, and right after a player leaves | `players_online` is always present, even with the `players` category off |
| `snapshot` | every 3600 ticks while a category is enabled, and right after a config is accepted if the config changed or it is the first one since the game was loaded | replaces **all** categories (so it also clears categories just turned off); may be split into `part`/`parts` (see 2a) |
| `update` | when a category's data changes | replaces only the categories it contains |
| `event` | one-shot facts (`player_joined`, `player_left` and the 2a events below) | only for enabled categories |

Until a config arrives the mod sends **only** `hello` and `heartbeat`.

`helpers.table_to_json` encodes an empty table as `[]`, and Lua JSON cannot emit
`null`; see "Lua JSON quirks" under 2a.

## Home Assistant → mod (config)

HA writes a retained MQTT message to `factorio/<server_id>/config`:

```json
{"v":1,"categories":{"players":true,"planets":true,"research":true,"evolution":true,"defense":true}}
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

**Compatibility:** mod 0.2 needs relay >= 0.2. An old relay replaces `data` on every snapshot
part, so with split snapshots the players (and other categories) would flicker. The reverse
(relay 0.2 with mod 0.1.x) works.

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
                        "magnitude":1.0,"state":"built"}]}
"research": {"current":{"name":"planet-discovery-maraxsis","level":1,"progress":0.62,"unlocks":["maraxsis"]},
             "queue":["up to 5 names"]}
"evolution":{"by_planet":{"nauvis":0.92,"gleba":0.61}}
"defense":  {"by_planet":{"nauvis":{"turrets":{"total":120,"no_ammo":6,"no_power":0,"no_ammo_at":[[10,-4]]},
                                    "walls_damaged":{"count":12,"at":[[-412,1180]]},
                                    "attack":{"since_tick":100,"position":[-412,1180],"gps":"[gps=-412,1180,nauvis]",
                                              "losses":{"gun-turret":4,"stone-wall":12}}}}}
"players":  {"online":["alice","guest"],"afk_minutes":{"guest":4}}
```

- `planets`: `kind` is the prototype type (`planet`, `space-location`, ...). `state`:
  `locked` | `unlocked` | `built` (`built` = an unlocked planet whose surface has player
  buildings; any `player`-force entity counts, including characters and vehicles, which is accepted). `parent`: the name of the body whose position equals this body's `origin`
  (tolerance `0.01`); absent otherwise. `unlocked_by`: the first technology (by name) with
  an `unlock-space-location` effect for the body; absent when there is none. Bodies with
  `hidden = true` are not sent.
- `research`: `current` is absent when nothing is being researched. `progress` is `0..1` rounded to 3 decimals; sent at most every 600 ticks and
  only when it moved by `>= 0.01` (or on a name/level/queue change). `unlocks` lists the
  non-hidden space locations the current technology unlocks. `research_finished` is sent
  immediately. `queue` lists up to 5 names and **includes the current research as its first
  entry** (`LuaForce.research_queue` semantics). Only the `player` force's research is reported.
- `evolution.by_planet`: enemy evolution per planet surface, 4 decimals, only planets with
  a value `> 0`; checked every 600 ticks, sent when any planet moved by `>= 0.005`.
- `defense.by_planet.<planet>`: planets that have turrets or damaged walls always carry both
  `turrets` and `walls_damaged` (so a repaired base reads `count: 0`). Turrets are
  `ammo-turret`, `electric-turret`, `fluid-turret` and `artillery-turret` of the `player`
  force. `no_power` counts `no_power` and `low_power` statuses. Turrets are scanned in
  batches every 10 ticks (a full lap per 600 ticks); the registry is filled in portions on
  first enable. `walls_damaged` covers `wall` and `gate`: a wall is added when it takes
  damage and removed once repaired or destroyed. Repairs are detected by the same 10-tick
  scanner step, in portions of about 1/60 of the damaged walls (at least 50), so a pass takes
  about 600 ticks and the tail of a large repair about 1500 ticks.
- `players.afk_minutes`: only players AFK for at least one whole minute.
- `attack` is absent when there is no attack. It is the attack with the most recent loss
  on that planet. Position lists (`no_ammo_at`, `at`) hold at most 5 entries.
- Attacks: a loss of a player-force building by an enemy force starts an attack at that
  position; later losses on the same surface within 100 tiles of the first loss and less
  than 3600 ticks after the latest loss join it. An attack ends after 3600 ticks without
  losses (game ticks, so pausing never ends it). Updates are pushed at most every 300 ticks.
- Losses exclude `character` and robots (`combat-robot`, `construction-robot`,
  `logistic-robot`).
- If `defense` is switched off during an attack, **no** `attack_ended` is sent and the
  attack state is dropped. Consumers must treat a missing `attack` as "no attack".

### Lua JSON quirks

- **Absent means null.** Lua JSON cannot emit `null`, so a field that would be `null` is
  **absent** from mod messages. Consumers must treat an absent field as `null`. This
  affects: `body.parent` and `body.unlocked_by` (`planets`), `research.current`,
  `defense.by_planet.<planet>.attack`, and in `player_died` the fields `planet`, `surface`
  and `cause`.
- **Empty tables.** An empty Lua table may arrive as `[]` or `{}` at any depth (for example
  `afk_minutes`, `queue`, `unlocks`, `by_planet`, `losses`, `no_ammo_at`). Only the
  top-level categories are normalised by the relay (`[]` to `{}`); deeper levels are the
  consumer's job (`as_dict` / `asDict`).

### New events

All of them are sent only while the owning category is enabled (`defense` for attacks and
turrets, `research`, `players`).

| event | data |
|---|---|
| `attack_started` | `planet`, `surface`, `position` `[x,y]`, `gps` (`[gps=x,y,surface]`) |
| `attack_ended` | same, plus `duration_s` (first to last loss), `losses` `{name: count}` |
| `turrets_no_ammo` | `planet`, `count` (some turret has been out of ammo for 600 ticks) |
| `turrets_ok` | `planet` (none has been out of ammo for 600 ticks) |
| `research_finished` | `name`, `level` |
| `player_died` | `player`, `planet` (absent off-planet), `surface`, `cause` (absent when unknown; the killer's prototype name) |

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
