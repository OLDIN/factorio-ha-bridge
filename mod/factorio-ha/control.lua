-- factorio-ha: streams server state to a local relay over UDP (protocol v1, docs/protocol.md).
-- Nothing but hello/heartbeat is sent until the relay delivers a config from Home Assistant.
-- This file only subscribes to events and dispatches to modules in scripts/.

local transport = require("scripts.transport")
local config = require("scripts.config")
local planets = require("scripts.planets")
local research = require("scripts.research")
local evolution = require("scripts.evolution")

local HEARTBEAT_TICKS = 300 -- 5 s
local SNAPSHOT_TICKS = 3600 -- 60 s
local CHECK_TICKS = 600 -- 10 s: research progress and evolution

-- Session-local: only decides whether the server sends a snapshot (server-only UDP), no desync.
local config_seen_this_session = false

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
  if config.enabled("players") then
    data.players = { online = online_names() }
  end
  if config.enabled("planets") then data.planets = planets.collect() end
  if config.enabled("research") then data.research = research.snapshot() end
  if config.enabled("evolution") then data.evolution = evolution.snapshot() end
  return data
end

local function send_hello(reason)
  transport.send({ type = "hello", mod_version = script.active_mods["factorio-ha"], reason = reason })
end

local function send_heartbeat()
  transport.send({ type = "heartbeat", players_online = #game.connected_players })
end

local function send_snapshot()
  transport.send_snapshot(collect())
end

local function player_event(event_name, player_index)
  send_heartbeat()
  if not config.enabled("players") then return end
  local player = game.get_player(player_index)
  transport.update_if_changed("players", { online = online_names() })
  transport.send({ type = "event", event = event_name, data = { player = player and player.name or "?" } })
end

script.on_init(function()
  config.init()
  send_hello("init")
end)

script.on_configuration_changed(function()
  config.init()
  send_hello("configuration_changed")
end)

script.on_nth_tick(HEARTBEAT_TICKS, send_heartbeat)

script.on_nth_tick(CHECK_TICKS, function()
  research.refresh(false)
  evolution.refresh()
end)

script.on_nth_tick(SNAPSHOT_TICKS, function()
  send_hello("periodic")
  if config.any_enabled() then send_snapshot() end
end)

script.on_event(defines.events.on_research_finished, function(e)
  research.on_finished(e)
  planets.refresh() -- a finished discovery tech unlocks bodies
end)

script.on_event(defines.events.on_surface_created, planets.refresh)
script.on_event(defines.events.on_surface_deleted, planets.refresh)

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
  local ok, changed = config.apply(helpers.json_to_table(cmd.parameter or ""))
  if not ok then
    rcon.print("error: invalid config")
    return
  end
  rcon.print("ok")
  -- A snapshot only when the config changed or it is the first one since the game loaded
  -- (the relay may have restarted and needs the full state).
  if changed or not config_seen_this_session then
    config_seen_this_session = true
    send_snapshot()
  end
end)
