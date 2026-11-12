-- `planets` category: all non-hidden space locations with their state.

local transport = require("scripts.transport")
local config = require("scripts.config")
local bodies = require("scripts.logic.bodies")

local planets = {}

local PARENT_TOLERANCE = 0.01

local function round4(v)
  return math.floor(v * 10000 + 0.5) / 10000
end

-- Prototype-derived data never changes within a session; computed lazily, session-local.
local static -- list of {name, kind, x, y, distance, orientation, magnitude, parent, unlocked_by}

local function build_static()
  local list, locations = {}, {}
  for name, proto in pairs(prototypes.space_location) do
    if not proto.hidden then
      local pos, origin = proto.position, proto.origin
      list[#list + 1] = {
        name = name,
        kind = proto.type,
        x = pos.x or pos[1],
        y = pos.y or pos[2],
        distance = proto.distance,
        orientation = proto.orientation,
        magnitude = proto.magnitude,
      }
      locations[#locations + 1] = {
        name = name, x = pos.x or pos[1], y = pos.y or pos[2],
        origin_x = origin and (origin.x or origin[1]) or 0,
        origin_y = origin and (origin.y or origin[2]) or 0,
      }
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  local parents = bodies.find_parents(locations, PARENT_TOLERANCE)

  -- First technology with an unlock-space-location effect for the body.
  local unlocked_by = {}
  for tech_name, tech in pairs(prototypes.technology) do
    for _, effect in pairs(tech.effects or {}) do
      if effect.type == "unlock-space-location" and effect.space_location
        and (unlocked_by[effect.space_location] == nil or tech_name < unlocked_by[effect.space_location]) then
        unlocked_by[effect.space_location] = tech_name
      end
    end
  end
  for _, body in ipairs(list) do
    body.parent = parents[body.name]
    body.unlocked_by = unlocked_by[body.name]
  end
  return list
end

local function has_buildings(name)
  local surface = game.get_surface(name)
  if not surface then return false end
  return surface.count_entities_filtered({ force = "player", limit = 1 }) > 0
end

function planets.collect()
  static = static or build_static()
  local force = game.forces.player
  local out = {}
  for _, body in ipairs(static) do
    local unlocked = force.is_space_location_unlocked(body.name)
    -- Space locations without a surface (secretas, edge, shattered planet) are only locked/unlocked.
    local built = unlocked and body.kind == "planet" and has_buildings(body.name)
    out[#out + 1] = {
      name = body.name, kind = body.kind, x = round4(body.x), y = round4(body.y),
      distance = round4(body.distance), orientation = round4(body.orientation), magnitude = round4(body.magnitude),
      parent = body.parent, state = bodies.state(unlocked, built), unlocked_by = body.unlocked_by,
    }
  end
  return { bodies = out }
end

function planets.refresh()
  if not config.enabled("planets") then return end
  transport.update_if_changed("planets", planets.collect())
end

return planets
