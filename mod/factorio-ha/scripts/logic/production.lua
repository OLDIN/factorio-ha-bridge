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

-- Machines of `g` that stand: "output full" counts only when the line rule says so (saturated
-- malls and buffers are not a problem for most players).
local function idle_count(g, with_output_full)
  return g.no_input + g.no_power + (with_output_full and g.output_full or 0)
end

-- Sum of the stopped buckets over every group of a location (the planet-level counters).
function production.buckets(state, location)
  local out = { no_input = 0, output_full = 0, no_power = 0 }
  local loc = state.locations[location]
  if not loc then return out end
  for _, g in pairs(loc.groups) do
    out.no_input = out.no_input + g.no_input
    out.output_full = out.output_full + g.output_full
    out.no_power = out.no_power + g.no_power
  end
  return out
end

-- Up to `n` positions of stopped machines (lowest ids first, deterministic).
local function some_positions(state, idle, n, with_output_full)
  local ids = {}
  for id in pairs(idle) do
    if with_output_full or state.machines[id].bucket ~= "output_full" then ids[#ids + 1] = id end
  end
  table.sort(ids)
  local at = {}
  for i = 1, math.min(n, #ids) do
    local p = idle[ids[i]]
    at[i] = { p[1], p[2] }
  end
  return at
end

function production.groups(state, location, min_share, max_groups, max_positions, with_output_full)
  local loc = state.locations[location]
  local list = {}
  if not loc then return list end
  for key, g in pairs(loc.groups) do
    local idle = idle_count(g, with_output_full)
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
      at = some_positions(state, g.idle, max_positions, with_output_full),
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
                 stuck = idle_count(g, true) }
  end
  return out
end

-- Trims `data` ({by_planet = {planet = {groups = {...}}}}, as sent in `machines`) so that
-- encode(data) is at most max_bytes: drops groups one at a time, smallest stopped share first
-- (across all planets; ties: fewer machines, then planet and recipe name). Totals stay.
-- Returns the number of dropped groups.
-- The size of every candidate group is measured once (encode of the group alone + 1 for its
-- comma) and subtracted along the drop order; the whole category is then encoded once to
-- verify, and one more group is dropped (and verified again) only if the estimate was short.
function production.trim_groups(data, max_bytes, encode, with_output_full)
  local size = #encode(data)
  if size <= max_bytes then return 0 end
  local list = {}
  for planet, entry in pairs(data.by_planet) do
    for _, g in ipairs(entry.groups) do
      list[#list + 1] = { planet = planet, group = g,
                          share = idle_count(g, with_output_full) / g.total }
    end
  end
  table.sort(list, function(a, b)
    if a.share ~= b.share then return a.share < b.share end
    if a.group.total ~= b.group.total then return a.group.total < b.group.total end
    if a.planet ~= b.planet then return a.planet < b.planet end
    return a.group.recipe < b.group.recipe
  end)
  local drops, estimate = 0, size
  while drops < #list and estimate > max_bytes do
    drops = drops + 1
    estimate = estimate - (#encode(list[drops].group) + 1)
  end
  local dropped = 0
  local function drop_to(n)
    while dropped < n do
      dropped = dropped + 1
      local item = list[dropped]
      local groups = data.by_planet[item.planet].groups
      for i, g in ipairs(groups) do
        if g == item.group then table.remove(groups, i); break end
      end
    end
  end
  drop_to(drops)
  while dropped < #list and #encode(data) > max_bytes do
    drop_to(dropped + 1)
  end
  return dropped
end

return production
