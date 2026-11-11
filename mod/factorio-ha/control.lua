-- factorio-ha: streams server state to a local relay over UDP (protocol v1, docs/protocol.md).
-- Nothing but hello/heartbeat is sent until the relay delivers a config from Home Assistant.

local PROTOCOL = 1
local HEARTBEAT_TICKS = 300 -- 5 s
local SNAPSHOT_TICKS = 3600 -- 60 s
local CATEGORIES = { "players" }

-- Session-local: only throttles a log line, never affects game state.
local send_failure_logged = false

local function send(msg)
  msg.v = PROTOCOL
  msg.tick = game.tick
  local port = settings.global["factorio-ha-udp-port"].value
  -- for_player = 0: only the server sends, never the clients.
  local ok, err = pcall(helpers.send_udp, port, helpers.table_to_json(msg), 0)
  if not ok and not send_failure_logged then
    send_failure_logged = true
    log("factorio-ha: UDP send failed (is the server started with --enable-lua-udp?): " .. tostring(err))
  end
end

local function categories()
  return (storage.config and storage.config.categories) or {}
end

local function enabled(name)
  return categories()[name] == true
end

local function any_enabled()
  for _, on in pairs(categories()) do
    if on then return true end
  end
  return false
end

local function online_names()
  local names = {}
  for _, player in pairs(game.connected_players) do
    names[#names + 1] = player.name
  end
  table.sort(names)
  return names
end

local function collect()
  local data = {}
  if enabled("players") then
    data.players = { online = online_names() }
  end
  return data
end

local function send_hello()
  send({ type = "hello", mod_version = script.active_mods["factorio-ha"] })
end

local function send_heartbeat()
  send({ type = "heartbeat", players_online = #game.connected_players })
end

local function send_snapshot()
  send({ type = "snapshot", data = collect() })
end

local function player_event(event_name, player_index)
  send_heartbeat()
  if not enabled("players") then return end
  local player = game.get_player(player_index)
  send({ type = "update", data = { players = { online = online_names() } } })
  send({ type = "event", event = event_name, data = { player = player and player.name or "?" } })
end

script.on_init(function()
  storage.config = { categories = {} }
  send_hello()
end)

script.on_configuration_changed(function()
  storage.config = storage.config or { categories = {} }
  send_hello()
end)

script.on_nth_tick(HEARTBEAT_TICKS, send_heartbeat)

script.on_nth_tick(SNAPSHOT_TICKS, function()
  send_hello()
  if any_enabled() then send_snapshot() end
end)

script.on_event(defines.events.on_player_joined_game, function(e)
  player_event("player_joined", e.player_index)
end)

script.on_event(defines.events.on_player_left_game, function(e)
  player_event("player_left", e.player_index)
end)

-- /factorio-ha-config <json>: sent by the relay over RCON. Server/RCON only.
commands.add_command("factorio-ha-config", "Internal: configuration from the factorio-ha relay.", function(cmd)
  if cmd.player_index then
    local player = game.get_player(cmd.player_index)
    if player then player.print("factorio-ha: this command is for the server only") end
    return
  end
  local parsed = helpers.json_to_table(cmd.parameter or "")
  if type(parsed) ~= "table" or parsed.v ~= PROTOCOL then
    rcon.print("error: invalid config")
    return
  end
  local wanted = type(parsed.categories) == "table" and parsed.categories or {}
  local config = { categories = {} }
  for _, name in ipairs(CATEGORIES) do
    config.categories[name] = wanted[name] == true
  end
  storage.config = config
  rcon.print("ok")
  -- Always one snapshot after a config: it also clears categories that were just turned off.
  send_snapshot()
end)
