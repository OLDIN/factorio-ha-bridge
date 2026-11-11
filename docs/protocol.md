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
| `hello` | `on_init`, `on_configuration_changed`, every 3600 ticks | relay re-sends the last config when it sees one |
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
