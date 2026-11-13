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

-- Up to `n` positions of stopped machines, lowest ids first (deterministic). A partial
-- selection of the n smallest ids: a group can hold hundreds of stopped machines, and sorting
-- them all to keep 3 was most of the cost of building the groups.
local function some_positions(state, idle, n, with_output_full)
  local best = {} -- ascending, at most n ids
  for id in pairs(idle) do
    local k = #best
    if (k < n or id < best[k]) and (with_output_full or state.machines[id].bucket ~= "output_full") then
      local i = k < n and k + 1 or k -- when full, the largest kept id gives way
      while i > 1 and best[i - 1] > id do
        best[i] = best[i - 1]
        i = i - 1
      end
      best[i] = id
    end
  end
  local at = {}
  for i, id in ipairs(best) do
    local p = idle[id]
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

-- Length of helpers.table_to_json(v) (compact; a table with keys 1..n or an empty one is an
-- array). Exact for plain data whose strings need no escaping (prototype names) and whose numbers
-- are integers, such as a group built by production.groups.
local function json_size(v)
  local t = type(v)
  if t == "string" then return #v + 2 end
  if t == "number" then
    if v == math.floor(v) then return #string.format("%d", v) end
    return #tostring(v)
  end
  if t == "boolean" then return v and 4 or 5 end
  local n = #v
  if n > 0 or next(v) == nil then
    local size = n > 0 and n + 1 or 2 -- brackets and n - 1 commas
    for i = 1, n do size = size + json_size(v[i]) end
    return size
  end
  local size = 1 -- "{", then "," or "}" after each field
  for key, x in pairs(v) do size = size + #key + 4 + json_size(x) end -- "key":x and a separator
  return size
end
production.json_size = json_size

-- Trims `data` ({by_planet = {planet = {groups = {...}}}}, as sent in `machines`) so that
-- encode(data) is at most max_bytes: drops groups one at a time, smallest stopped share first
-- (across all planets; ties: fewer machines, then planet and recipe name). Totals stay.
-- Returns the number of dropped groups and encode(data) of the result, ready to send.
-- Nothing big is encoded to measure: the category with empty group lists is encoded (small) and
-- the groups are measured with json_size, which gives the exact size of the whole. Dropping walks
-- that estimate down; the result is encoded once, and one more group is dropped (and encoded
-- again) only if that encoding still does not fit.
function production.trim_groups(data, max_bytes, encode, with_output_full)
  local list, entries = {}, {}
  for _, section in ipairs({ "by_planet", "by_platform" }) do -- 2c: platforms share the budget
    for place, entry in pairs(data[section] or {}) do
      entries[#entries + 1] = entry
      for _, g in ipairs(entry.groups) do
        list[#list + 1] = { section = section, planet = place, group = g, entry = entry,
                            share = idle_count(g, with_output_full) / g.total, size = json_size(g) }
      end
    end
  end
  local saved, left = {}, {}
  for i, entry in ipairs(entries) do saved[i], entry.groups = entry.groups, {} end
  local estimate = #encode(data) -- every "groups":[] counted already
  for i, entry in ipairs(entries) do
    entry.groups = saved[i]
    local k = #entry.groups
    left[entry] = k
    if k > 1 then estimate = estimate + k - 1 end -- commas between the groups
  end
  for _, item in ipairs(list) do estimate = estimate + item.size end

  local sorted = false
  local function sort()
    if sorted then return end
    sorted = true
    table.sort(list, function(a, b)
      if a.share ~= b.share then return a.share < b.share end
      if a.group.total ~= b.group.total then return a.group.total < b.group.total end
      if a.section ~= b.section then return a.section < b.section end
      if a.planet ~= b.planet then return a.planet < b.planet end
      return a.group.recipe < b.group.recipe
    end)
  end
  local drops = 0
  if estimate > max_bytes then
    sort()
    while drops < #list and estimate > max_bytes do
      drops = drops + 1
      local item = list[drops]
      left[item.entry] = left[item.entry] - 1
      estimate = estimate - item.size - (left[item.entry] > 0 and 1 or 0)
    end
  end
  local dropped = 0
  local function drop_to(n)
    while dropped < n do
      dropped = dropped + 1
      local item = list[dropped]
      local groups = item.entry.groups
      for i, g in ipairs(groups) do
        if g == item.group then table.remove(groups, i); break end
      end
    end
  end
  drop_to(drops)
  local json = encode(data)
  while dropped < #list and #json > max_bytes do -- the estimate was short
    sort()
    drop_to(dropped + 1)
    json = encode(data)
  end
  return dropped, json
end

return production
