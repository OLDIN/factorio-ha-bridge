-- `players` category: who is online and how long they have been AFK; player deaths.

local transport = require("scripts.transport")
local config = require("scripts.config")

local players = {}

-- list: {{name, afk_time (ticks)}}. Only whole minutes > 0.
function players.afk_minutes(list)
  local out = {}
  for _, p in ipairs(list) do
    local minutes = math.floor((p.afk_time or 0) / 3600)
    if minutes > 0 then out[p.name] = minutes end
  end
  return out
end

function players.death_data(player, planet, surface_name, cause)
  return {
    player = player.name,
    planet = planet,
    surface = surface_name,
    cause = cause and cause.name or nil,
  }
end

function players.collect()
  local names, list = {}, {}
  for _, player in pairs(game.connected_players) do
    names[#names + 1] = player.name
    list[#list + 1] = { name = player.name, afk_time = player.afk_time }
  end
  table.sort(names)
  return { online = names, afk_minutes = players.afk_minutes(list) }
end

-- Every 600 ticks (and on join/leave): push changes.
function players.refresh()
  if not config.enabled("players") then return end
  transport.update_if_changed("players", players.collect())
end

function players.on_died(e)
  if not config.enabled("players") then return end
  local player = game.get_player(e.player_index)
  if not player then return end
  local surface = player.surface
  local planet = surface and surface.valid and surface.planet
  local cause = e.cause and e.cause.valid and e.cause or nil
  local data = players.death_data(player, planet and planet.name or nil,
    surface and surface.valid and surface.name or nil, cause)
  -- planet/cause are absent (not null) when unknown: Lua cannot encode null; consumers treat absent as null
  transport.send({ type = "event", event = "player_died", data = data })
end

return players
