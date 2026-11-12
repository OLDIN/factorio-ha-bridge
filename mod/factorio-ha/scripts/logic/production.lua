-- Production groups (no game API, Lua 5.2 compatible; plain tables, lives in `storage`).
-- Machines/drills are registered by id into a group (location, key): key is a recipe
-- name for machines and a resource name for drills. All counters are incremental.

local production = {}

local function map(bucket, names)
  local t = {}
  for _, n in ipairs(names) do t[n] = bucket end
  return t
end

production.BUCKETS = {}
for _, part in ipairs({
  map("working", { "working", "normal", "preparing_rocket_for_launch",
                   "waiting_to_launch_rocket", "launching_rocket" }),
  map("no_input", { "no_ingredients", "item_ingredient_shortage", "fluid_ingredient_shortage",
                    "no_input_fluid", "missing_required_fluid" }),
  map("output_full", { "full_output", "waiting_for_space_in_destination",
                       "not_enough_space_in_output", "waiting_for_space_in_platform_hub" }),
  map("no_power", { "no_power", "low_power", "no_fuel", "frozen" }),
  map("depleted", { "no_minable_resources" }),
  map("off", { "disabled_by_control_behavior", "disabled_by_script", "disabled",
               "marked_for_deconstruction" }),
}) do
  for k, v in pairs(part) do production.BUCKETS[k] = v end
end

function production.bucket(name)
  return production.BUCKETS[name] or "other"
end

local COUNTERS = { "working", "no_input", "output_full", "no_power", "depleted", "off", "other" }

function production.new()
  return { machines = {}, locations = {} }
end

local function new_group()
  local g = { total = 0, idle = {} }
  for _, c in ipairs(COUNTERS) do g[c] = 0 end
  return g
end

local function leave(state, id)
  local m = state.machines[id]
  if not m then return end
  local loc = state.locations[m.location]
  local g = loc.groups[m.key]
  g.total = g.total - 1
  g[m.bucket] = g[m.bucket] - 1
  g.idle[id] = nil
  loc.total = loc.total - 1
  if m.bucket == "working" then loc.working = loc.working - 1 end
  if g.total == 0 then loc.groups[m.key] = nil end
  if loc.total == 0 then state.locations[m.location] = nil end
  state.machines[id] = nil
end

function production.set(state, id, location, key, bucket, position)
  leave(state, id)
  local loc = state.locations[location]
  if not loc then
    loc = { total = 0, working = 0, groups = {} }
    state.locations[location] = loc
  end
  local g = loc.groups[key]
  if not g then
    g = new_group()
    loc.groups[key] = g
  end
  g.total = g.total + 1
  g[bucket] = (g[bucket] or 0) + 1
  loc.total = loc.total + 1
  if bucket == "working" then loc.working = loc.working + 1 end
  if bucket == "no_input" or bucket == "output_full" or bucket == "no_power" then
    g.idle[id] = position
  end
  state.machines[id] = { location = location, key = key, bucket = bucket }
end

function production.remove(state, id)
  leave(state, id)
end

function production.summary(state, location)
  local loc = state.locations[location]
  if not loc then return { total = 0, working = 0 } end
  return { total = loc.total, working = loc.working }
end

local function idle_count(g)
  return g.no_input + g.output_full + g.no_power
end

-- Up to `n` positions of idle machines (lowest ids first, deterministic).
local function some_positions(idle, n)
  local ids = {}
  for id in pairs(idle) do ids[#ids + 1] = id end
  table.sort(ids)
  local at = {}
  for i = 1, math.min(n, #ids) do
    local p = idle[ids[i]]
    at[i] = { p[1], p[2] }
  end
  return at
end

function production.groups(state, location, min_share, max_groups, max_positions)
  local loc = state.locations[location]
  local list = {}
  if not loc then return list end
  for key, g in pairs(loc.groups) do
    local idle = idle_count(g)
    -- epsilon guards against float error such as 0.1 * 30
    if idle > 0 and idle >= min_share * g.total - 1e-9 then
      list[#list + 1] = { key = key, share = idle / g.total, g = g }
    end
  end
  table.sort(list, function(a, b)
    if a.share ~= b.share then return a.share > b.share end
    return a.key < b.key
  end)
  local out = {}
  for i = 1, math.min(max_groups, #list) do
    local g = list[i].g
    out[i] = {
      recipe = list[i].key, total = g.total, working = g.working,
      no_input = g.no_input, output_full = g.output_full, no_power = g.no_power,
      at = some_positions(g.idle, max_positions),
    }
  end
  return out
end

function production.resources(state, location)
  local out = {}
  local loc = state.locations[location]
  if not loc then return out end
  for key, g in pairs(loc.groups) do
    out[key] = { total = g.total, working = g.working, depleted = g.depleted,
                 stuck = idle_count(g) }
  end
  return out
end

-- Trims `data` ({by_planet = {planet = {groups = {...}}}}, as sent in `machines`) so that
-- encode(data) is at most max_bytes: drops groups one at a time, smallest stopped share first
-- (across all planets; ties: fewer machines, then planet and recipe name). Totals stay.
-- Returns the number of dropped groups.
function production.trim_groups(data, max_bytes, encode)
  if #encode(data) <= max_bytes then return 0 end
  local list = {}
  for planet, entry in pairs(data.by_planet) do
    for _, g in ipairs(entry.groups) do
      list[#list + 1] = { planet = planet, group = g,
                          share = (g.no_input + g.output_full + g.no_power) / g.total }
    end
  end
  table.sort(list, function(a, b)
    if a.share ~= b.share then return a.share < b.share end
    if a.group.total ~= b.group.total then return a.group.total < b.group.total end
    if a.planet ~= b.planet then return a.planet < b.planet end
    return a.group.recipe < b.group.recipe
  end)
  local dropped = 0
  for _, item in ipairs(list) do
    local groups = data.by_planet[item.planet].groups
    for i, g in ipairs(groups) do
      if g == item.group then table.remove(groups, i); break end
    end
    dropped = dropped + 1
    if #encode(data) <= max_bytes then break end
  end
  return dropped
end

return production
