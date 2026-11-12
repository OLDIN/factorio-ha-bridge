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
  local g = production.groups(s, "nauvis", 0.1, 20, 3, true)
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

-- trim_groups: drop the groups with the smallest stopped share until the encoding fits
do
  local function encode(v)  -- tiny deterministic stand-in for helpers.table_to_json
    local function enc(x)
      if type(x) ~= "table" then return tostring(x) end
      if #x > 0 then  -- JSON-like array: elements joined by commas, no keys
        local items = {}
        for i, v in ipairs(x) do items[i] = enc(v) end
        return "[" .. table.concat(items, ",") .. "]"
      end
      local keys = {}
      for k in pairs(x) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      local out = {}
      for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. enc(x[k]) end
      return "{" .. table.concat(out, ",") .. "}"
    end
    return enc(v)
  end
  local function grp(name, total, idle)
    return { recipe = name, total = total, working = total - idle, no_input = idle,
             output_full = 0, no_power = 0, at = {} }
  end
  local function build()
    return { by_planet = {
      nauvis = { total = 100, working = 50, groups = { grp("a", 10, 9), grp("b", 10, 2), grp("c", 10, 5) } },
      gleba = { total = 20, working = 10, groups = { grp("d", 10, 3), grp("e", 10, 8) } },
    } }
  end
  local full = build()
  local size = #encode(full)
  assert(production.trim_groups(full, size, encode) == 0, "fits: nothing dropped")
  assert(#full.by_planet.nauvis.groups == 3)

  local d = build()
  local dropped = production.trim_groups(d, size - 1, encode)
  assert(dropped == 1, dropped)
  assert(#d.by_planet.nauvis.groups == 2 and d.by_planet.nauvis.groups[1].recipe == "a"
    and d.by_planet.nauvis.groups[2].recipe == "c", "b (share 0.2) is the smallest")
  assert(#d.by_planet.gleba.groups == 2)

  d = build()
  assert(production.trim_groups(d, 1, encode) == 5, "impossible limit: all groups go, then stop")
  assert(#d.by_planet.nauvis.groups == 0 and #d.by_planet.gleba.groups == 0)
  assert(d.by_planet.nauvis.total == 100, "totals stay")

  d = build()  -- two drops: b (0.2) then d (0.3)
  local limit = #encode(d) - 1
  local e = build()
  production.trim_groups(e, limit, encode)
  local after_one = #encode(e)
  production.trim_groups(d, after_one - 1, encode)
  assert(#d.by_planet.nauvis.groups == 2 and #d.by_planet.gleba.groups == 1
    and d.by_planet.gleba.groups[1].recipe == "e")
  -- large input: same result as dropping one group at a time, with only a few encodes
  do
    local function big()
      local by_planet = {}
      for pi = 1, 10 do
        local groups = {}
        for gi = 1, 20 do
          groups[gi] = grp("r" .. pi .. "_" .. gi, 10 + gi, (gi * 7 + pi) % (10 + gi) + 1)
          groups[gi].at = { { gi, pi }, { gi, pi + 1 } }
        end
        by_planet["p" .. pi] = { total = 500, working = 100, groups = groups }
      end
      return { by_planet = by_planet }
    end
    local function naive(data, max_bytes)  -- the previous one-by-one algorithm
      local list = {}
      for planet, entry in pairs(data.by_planet) do
        for _, g in ipairs(entry.groups) do
          list[#list + 1] = { planet = planet, group = g, share = (g.no_input + g.output_full + g.no_power) / g.total }
        end
      end
      table.sort(list, function(a, b)
        if a.share ~= b.share then return a.share < b.share end
        if a.group.total ~= b.group.total then return a.group.total < b.group.total end
        if a.planet ~= b.planet then return a.planet < b.planet end
        return a.group.recipe < b.group.recipe
      end)
      local dropped = 0
      if #encode(data) <= max_bytes then return 0 end
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
    local total = #encode(big())
    for _, limit in ipairs({ total, total - 1, total * 3 // 4, total // 2, total // 10, 1 }) do
      local want, got = big(), big()
      local n_want = naive(want, limit)
      local calls = 0
      local n_got = production.trim_groups(got, limit, function(v) calls = calls + 1; return encode(v) end)
      assert(n_got == n_want, "limit " .. limit .. ": dropped " .. n_got .. " want " .. n_want)
      assert(encode(got) == encode(want), "limit " .. limit .. ": same remaining groups")
      -- 1 initial + per-group sizes (<= 200) + a few verifications
      assert(calls <= 200 + 5, "limit " .. limit .. ": " .. calls .. " encodes")
    end
    -- encodes of the whole category stay constant (group sizes are measured on single groups)
    local whole = 0
    local data = big()
    production.trim_groups(data, total // 2, function(v)
      if v.by_planet then whole = whole + 1 end
      return encode(v)
    end)
    assert(whole <= 4, "whole-category encodes: " .. whole)
  end
end

-- "output full" is not "stopped" unless the line rule says so (saturated malls and buffers)
do
  local s = production.new()
  add(s, 1, 3, "nauvis", "barrel", "output_full")          -- a mall: everything full
  add(s, 4, 9, "nauvis", "iron-plate", "working")
  add(s, 10, 11, "nauvis", "iron-plate", "output_full")
  add(s, 12, 13, "nauvis", "iron-plate", "no_input")
  local off = production.groups(s, "nauvis", 0.1, 20, 3, false)
  assert(#off == 1 and off[1].recipe == "iron-plate", "only the starving group without the flag")
  assert(#off[1].at == 2 and off[1].at[1][1] == 12 and off[1].at[2][1] == 13, "positions of starving machines only")
  assert(off[1].output_full == 2, "the counters stay facts")
  local on = production.groups(s, "nauvis", 0.1, 20, 3, true)
  assert(#on == 2 and on[1].recipe == "barrel", "with the flag the full mall is the worst")
  assert(#on[2].at == 3, "with the flag full machines are positions too")
  local b = production.buckets(s, "nauvis")
  assert(b.no_input == 2 and b.output_full == 5 and b.no_power == 0, "planet counters cover all groups")
  local none = production.buckets(s, "vulcanus")
  assert(none.no_input == 0 and none.output_full == 0 and none.no_power == 0)
end

-- trimming drops the least stopped first by the same rule
do
  local function grp(recipe, total, no_input, output_full)
    return { recipe = recipe, total = total, working = total - no_input - output_full,
             no_input = no_input, output_full = output_full, no_power = 0, at = {} }
  end
  local function data()
    return { by_planet = { nauvis = { total = 30, working = 10, groups = {
      grp("full-mall", 10, 0, 10), grp("starving", 10, 5, 0), grp("half", 10, 2, 0) } } } }
  end
  -- 100 bytes per group in the whole category, 99 per group alone (+1 for the comma)
  local function size(d)
    return string.rep("x", d.by_planet and #d.by_planet.nauvis.groups * 100 or 99)
  end
  local d = data()
  production.trim_groups(d, 100, size, false)
  assert(#d.by_planet.nauvis.groups == 1 and d.by_planet.nauvis.groups[1].recipe == "starving", "without the flag a full group is dropped first")
  d = data()
  production.trim_groups(d, 100, size, true)
  assert(d.by_planet.nauvis.groups[1].recipe == "full-mall", "with the flag the full group is the most stopped")
end

print("production_test ok")
