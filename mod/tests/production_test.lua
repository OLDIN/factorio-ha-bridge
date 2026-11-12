-- Pure-logic tests for scripts/logic/production.lua.
package.path = "factorio-ha/?.lua;" .. package.path
local production = require("scripts.logic.production")

-- status -> bucket
do
  local cases = {
    no_ingredients = "no_input", full_output = "output_full", frozen = "no_power",
    no_minable_resources = "depleted", disabled_by_control_behavior = "off",
    launching_rocket = "working", working = "working", normal = "working",
    fluid_ingredient_shortage = "no_input", waiting_for_space_in_destination = "output_full",
    low_power = "no_power", no_fuel = "no_power", marked_for_deconstruction = "off",
    whatever = "other",
  }
  for status, want in pairs(cases) do
    assert(production.bucket(status) == want, status .. " -> " .. tostring(production.bucket(status)))
  end
  assert(production.BUCKETS.no_power == "no_power")
end

local function add(s, from, to, loc, key, bucket)
  for id = from, to do production.set(s, id, loc, key, bucket, { id, 40 }) end
end

-- 10 machines, 4 idle
do
  local s = production.new()
  add(s, 1, 6, "nauvis", "iron-plate", "working")
  add(s, 7, 10, "nauvis", "iron-plate", "no_input")
  local g = production.groups(s, "nauvis", 0.1, 20, 3)
  assert(#g == 1)
  assert(g[1].recipe == "iron-plate" and g[1].total == 10 and g[1].working == 6)
  assert(g[1].no_input == 4 and g[1].output_full == 0 and g[1].no_power == 0)
  assert(#g[1].at == 3, "at " .. #g[1].at)
  for _, p in ipairs(g[1].at) do assert(p[1] >= 7 and p[1] <= 10, "at lists only idle machines") end
  -- nothing idle -> no groups
  for id = 7, 10 do production.set(s, id, "nauvis", "iron-plate", "working", { id, 40 }) end
  assert(#production.groups(s, "nauvis", 0.1, 20, 3) == 0)
  assert(#production.groups(s, "vulcanus", 0.1, 20, 3) == 0)
end

-- threshold (float-safe) and off/other do not count as idle
do
  local s = production.new()
  add(s, 1, 27, "nauvis", "a", "working")
  add(s, 28, 30, "nauvis", "a", "no_power")
  assert(#production.groups(s, "nauvis", 0.1, 20, 3) == 1, "10% exactly passes")
  assert(#production.groups(s, "nauvis", 0.11, 20, 3) == 0)
  local s2 = production.new()
  add(s2, 1, 5, "nauvis", "b", "off")
  add(s2, 6, 10, "nauvis", "b", "other")
  assert(#production.groups(s2, "nauvis", 0.1, 20, 3) == 0)
end

-- move between groups and removal
do
  local s = production.new()
  add(s, 1, 10, "nauvis", "iron-plate", "no_input")
  production.set(s, 1, "nauvis", "copper-plate", "working", { 1, 1 })
  local g = production.groups(s, "nauvis", 0.1, 20, 3)
  local by = {}
  for _, x in ipairs(g) do by[x.recipe] = x end
  assert(by["iron-plate"].total == 9 and by["iron-plate"].no_input == 9)
  assert(production.summary(s, "nauvis").total == 10)
  production.remove(s, 2)
  assert(production.summary(s, "nauvis").total == 9)
  production.remove(s, 2)
  production.remove(s, 999)
  assert(production.summary(s, "nauvis").total == 9)
  g = production.groups(s, "nauvis", 0.1, 20, 3)
  for _, x in ipairs(g) do
    if x.recipe == "iron-plate" then assert(x.total == 8 and x.no_input == 8) end
  end
  -- relocate to another planet
  production.set(s, 3, "gleba", "iron-plate", "working", { 0, 0 })
  assert(production.summary(s, "gleba").total == 1 and production.summary(s, "nauvis").total == 8)
  -- bucket change within a group
  production.set(s, 4, "nauvis", "iron-plate", "working", { 4, 40 })
  assert(production.summary(s, "nauvis").working == 2)
  -- removing everything leaves no stray entries
  for id = 1, 10 do production.remove(s, id) end
  assert(production.summary(s, "nauvis").total == 0 and next(production.resources(s, "nauvis")) == nil)
end

-- group limit: highest idle share wins
do
  local s = production.new()
  local id = 0
  for i = 1, 25 do
    for j = 1, 10 do
      id = id + 1
      production.set(s, id, "nauvis", "r" .. i, j <= i / 3 + 1 and "output_full" or "working", { id, 0 })
    end
  end
  local g = production.groups(s, "nauvis", 0.1, 20, 3)
  assert(#g == 20, #g)
  local min_share = 1
  for _, x in ipairs(g) do min_share = math.min(min_share, x.output_full / x.total) end
  local dropped = 0
  local kept = {}
  for _, x in ipairs(g) do kept[x.recipe] = true end
  for i = 1, 25 do
    if not kept["r" .. i] then dropped = math.max(dropped, (math.floor(i / 3 + 1)) / 10) end
  end
  assert(dropped <= min_share, "dropped groups have a lower or equal share")
  assert(production.summary(s, "nauvis").total == 250)
end

-- summary counts groups below the threshold too
do
  local s = production.new()
  add(s, 1, 50, "nauvis", "x", "working")
  production.set(s, 51, "nauvis", "x", "no_input", { 1, 1 })
  add(s, 52, 60, "nauvis", "y", "working")
  assert(#production.groups(s, "nauvis", 0.1, 20, 3) == 0)
  local sm = production.summary(s, "nauvis")
  assert(sm.total == 60 and sm.working == 59)
end

-- drills by resource
do
  local s = production.new()
  add(s, 1, 6, "nauvis", "iron-ore", "working")
  add(s, 7, 8, "nauvis", "iron-ore", "depleted")
  production.set(s, 9, "nauvis", "iron-ore", "output_full", { 0, 0 })
  production.set(s, 10, "nauvis", "iron-ore", "no_power", { 0, 0 })
  production.set(s, 11, "nauvis", "iron-ore", "no_input", { 0, 0 })
  production.set(s, 12, "nauvis", "iron-ore", "off", { 0, 0 })
  production.set(s, 13, "nauvis", "coal", "working", { 0, 0 })
  local r = production.resources(s, "nauvis")
  local i = r["iron-ore"]
  assert(i.total == 12 and i.working == 6 and i.depleted == 2 and i.stuck == 3, "iron-ore counters")
  assert(r.coal.total == 1 and r.coal.working == 1 and r.coal.depleted == 0 and r.coal.stuck == 0)
  assert(next(production.resources(s, "gleba")) == nil)
end

-- payload size: 10 planets x 20 groups with long recipe names
do
  local function encode(v)
    local t = type(v)
    if t == "table" then
      if #v > 0 or next(v) == nil then
        local out = {}
        for _, x in ipairs(v) do out[#out + 1] = encode(x) end
        return "[" .. table.concat(out, ",") .. "]"
      end
      local out = {}
      for k, x in pairs(v) do out[#out + 1] = '"' .. k .. '":' .. encode(x) end
      return "{" .. table.concat(out, ",") .. "}"
    elseif t == "string" then return '"' .. v .. '"'
    else return tostring(v) end
  end
  local s = production.new()
  local id = 0
  local by_planet = {}
  for p = 1, 10 do
    local planet = "planet-with-long-name-" .. p
    for r = 1, 20 do
      for j = 1, 10 do
        id = id + 1
        production.set(s, id, planet, "some-quite-long-recipe-name-number-" .. r,
          j <= 3 and "no_input" or "working", { -123456.5 + id, 98765.5 })
      end
    end
    local sm = production.summary(s, planet)
    by_planet[planet] = { total = sm.total, working = sm.working,
                          groups = production.groups(s, planet, 0.1, 20, 3) }
  end
  -- One planet is the unit that must fit a UDP packet (8000 bytes); the whole
  -- 10-planet payload cannot (200 groups x ~200 bytes), so the sender splits per planet.
  local biggest = 0
  for planet, entry in pairs(by_planet) do
    local json = encode({ machines = { by_planet = { [planet] = entry } } })
    biggest = math.max(biggest, #json)
    assert(#entry.groups == 20)
  end
  assert(biggest < 8000, "per-planet payload " .. biggest .. " bytes")
end

print("production_test ok")
