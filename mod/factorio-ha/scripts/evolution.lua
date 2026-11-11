-- `evolution` category: enemy evolution per planet surface.

local transport = require("scripts.transport")
local config = require("scripts.config")

local evolution = {}

local STEP = 0.005

local last_sent = {} -- {planet = value}; session-local, throttles UDP only

function evolution.collect()
  local by_planet = {}
  local enemy = game.forces.enemy
  for _, surface in pairs(game.surfaces) do
    local planet = surface.planet
    if planet then
      local value = enemy.get_evolution_factor(surface)
      if value > 0 then by_planet[planet.name] = math.floor(value * 10000 + 0.5) / 10000 end
    end
  end
  return { by_planet = by_planet }
end

function evolution.snapshot()
  local data = evolution.collect()
  last_sent = data.by_planet
  return data
end

local function changed(new)
  for name, value in pairs(new) do
    if last_sent[name] == nil or math.abs(value - last_sent[name]) >= STEP then return true end
  end
  for name in pairs(last_sent) do
    if new[name] == nil then return true end
  end
  return false
end

function evolution.refresh()
  if not config.enabled("evolution") then return end
  local data = evolution.collect()
  if changed(data.by_planet) then
    last_sent = data.by_planet
    transport.update_if_changed("evolution", data)
  end
end

return evolution
