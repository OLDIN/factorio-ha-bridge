-- Tests for scripts/planets.lua with a stubbed game API (run via scripts/test-mod.sh).
package.path = "factorio-ha/?.lua;" .. package.path

local searches = {} -- surface name -> count_entities_filtered calls
local buildings = {} -- surface name -> player entities on it

local function new_surface(name, index)
  return { name = name, index = index, count_entities_filtered = function(filter)
    assert(filter.force == "player" and filter.limit == 1, "one player entity is enough")
    searches[name] = (searches[name] or 0) + 1
    return math.min(buildings[name] or 0, filter.limit)
  end }
end

local function body()
  return { hidden = false, type = "planet", position = { x = 1, y = 2 },
           distance = 10, orientation = 0.1, magnitude = 1 }
end

prototypes = {
  space_location = { nauvis = body(), gleba = body(), vulcanus = body() },
  technology = {},
}
local surfaces = { nauvis = new_surface("nauvis", 1), gleba = new_surface("gleba", 2) }
game = {
  forces = { player = { is_space_location_unlocked = function() return true end } },
  get_surface = function(name) return surfaces[name] end,
}

storage = {}

local planets = require("scripts.planets")
local production = require("scripts.logic.production")

local function states()
  local out = {}
  for _, b in ipairs(planets.collect().bodies) do out[b.name] = b.state end
  return out
end

-- the search for a player entity runs over the surface's chunks (milliseconds on a big base):
-- a planet seen with buildings is not searched again in this session
do
  buildings.nauvis = 5000
  local s = states()
  assert(s.nauvis == "built" and s.gleba == "unlocked" and s.vulcanus == "unlocked", "first states")
  assert(searches.nauvis == 1 and searches.gleba == 1, "each surface searched once")
  assert(searches.vulcanus == nil, "no surface, no search")

  s = states()
  assert(s.nauvis == "built", "still built")
  assert(searches.nauvis == 1, "a built planet is not searched again: " .. searches.nauvis)
  assert(searches.gleba == 2, "a planet without buildings is searched every time")

  buildings.gleba = 1 -- the first building on gleba
  assert(states().gleba == "built")
  assert(states().gleba == "built" and searches.gleba == 3, "gleba stops being searched once built")

  -- the surface is deleted and created again: a new index, nothing built on it yet
  surfaces.nauvis, buildings.nauvis = new_surface("nauvis", 7), 0
  assert(states().nauvis == "unlocked", "a recreated surface is searched again")
  assert(searches.nauvis == 2)
end

-- a machine or drill in the registry proves buildings: no search at all
do
  surfaces.vulcanus = new_surface("vulcanus", 9) -- no player entity found by a search either
  storage.machines = { machines = production.new(), drills = production.new() }
  production.set(storage.machines.drills, 1, "vulcanus", "tungsten-ore", "working", nil)
  assert(states().vulcanus == "built", "built from the registry")
  assert(searches.vulcanus == nil, "the surface was not searched")
  storage.machines = nil -- categories off: the search is the fallback
  surfaces.gleba, buildings.gleba = new_surface("gleba", 10), 0
  assert(states().gleba == "unlocked" and searches.gleba == 4, "searched without a registry")
end

-- warm() runs in on_load, where `game` does not exist: prototypes only
do
  package.loaded["scripts.planets"] = nil
  local fresh = require("scripts.planets")
  local saved = game
  game = nil
  fresh.warm()
  game = saved
  prototypes.technology = setmetatable({}, { __pairs = function() error("prototypes read again") end })
  assert(#fresh.collect().bodies == 3, "collect uses what warm() built")
end

print("planets_test ok")
