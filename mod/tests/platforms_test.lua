-- Tests for scripts/platforms.lua with a stubbed game API (run via scripts/test-mod.sh).
package.path = "factorio-ha/?.lua;" .. package.path

local STATE = { waiting_for_starter_pack = 0, starter_pack_requested = 1, starter_pack_on_the_way = 2, on_the_path = 3,
                waiting_for_departure = 4, no_schedule = 5, no_path = 6, paused = 7 }
defines = { space_platform_state = STATE, entity_status = {}, target_type = { entity = 1 } }
script = { register_on_object_destroyed = function() end }
helpers = { table_to_json = function() return "{}" end }
storage = {}

local transport = require("scripts.transport")
local config = require("scripts.config")
local platforms = require("scripts.platforms")

-- Stubbed world ---------------------------------------------------------------------------
local sent, updates
transport.send = function(msg) sent[#sent + 1] = msg end
transport.update_if_changed = function(category, data) updates[#updates + 1] = { category = category, data = data } end

local function loc(name) return { name = name } end

local function platform(index, name, state, fields)
  local p = { valid = true, index = index, name = name, state = STATE[state], scheduled_for_deletion = 0,
              force = { name = "player" } }
  for k, v in pairs(fields or {}) do p[k] = v end
  p.surface = { name = "platform-" .. index, valid = true, platform = p }
  return p
end

local list
local function world(...)
  list = {}
  for _, p in ipairs({ ... }) do list[p.index] = p end
  game = { tick = 0, forces = { player = { platforms = list } } }
end

local function reset(enabled)
  storage = {}
  config.apply({ v = 1, categories = { platforms = enabled ~= false, defense = true } })
  sent, updates = {}, {}
end

local function events(name)
  local out = {}
  for _, m in ipairs(sent) do
    if m.type == "event" and m.event == name then out[#out + 1] = m.data end
  end
  return out
end

local function belt(p, fields)
  local e = { valid = true, name = "transport-belt", type = "transport-belt", force = { name = "player" }, surface = p.surface }
  for k, v in pairs(fields or {}) do e[k] = v end
  return e
end

-- collect: where each platform is or flies, sorted by index; deleted / invalid ones are skipped
do
  reset()
  local hauler = platform(3, "Hauler 2", "on_the_path", {
    space_connection = { from = loc("gleba"), to = loc("fulgora") }, distance = 0.38,
    last_visited_space_location = loc("fulgora") })
  local science = platform(1, "Science", "no_schedule", { space_location = loc("nauvis") })
  local doomed = platform(2, "Doomed", "no_schedule", { space_location = loc("nauvis"), scheduled_for_deletion = 60 })
  local gone = platform(4, "Gone", "no_schedule", { space_location = loc("nauvis"), valid = false })
  world(hauler, science, doomed, gone)
  local data = platforms.collect()
  assert(#data.list == 2)
  local a, b = data.list[1], data.list[2]
  assert(a.index == 1 and a.name == "Science" and a.state == "no_schedule" and a.location == "nauvis" and a.route == nil)
  assert(b.index == 3 and b.state == "on_the_path" and b.location == nil)
  assert(b.route.from == "fulgora" and b.route.to == "gleba" and math.abs(b.route.progress - 0.62) < 1e-9)
  assert(b.damage == nil)
end

-- a platform without last_visited_space_location in the API keeps the connection's own ends
do
  reset()
  local p = platform(7, "Old", "on_the_path", { space_connection = { from = loc("nauvis"), to = loc("vulcanus") }, distance = 0.25 })
  setmetatable(p, { __index = function(_, k)
    if k == "last_visited_space_location" then error("LuaSpacePlatform doesn't contain key last_visited_space_location") end
  end })
  world(p)
  local r = platforms.collect().list[1].route
  assert(r.from == "nauvis" and r.to == "vulcanus" and r.progress == 0.25)
end

-- state changes: departed and arrived events, then the category is pushed
do
  reset()
  local p = platform(3, "Hauler 2", "on_the_path", {
    space_connection = { from = loc("fulgora"), to = loc("gleba") }, distance = 0, last_visited_space_location = loc("fulgora") })
  world(p)
  platforms.on_state_changed({ platform = p, old_state = STATE.waiting_for_departure })
  local d = events("platform_departed")
  assert(#d == 1 and d[1].index == 3 and d[1].name == "Hauler 2" and d[1].from == "fulgora" and d[1].to == "gleba")
  assert(#updates == 1 and updates[1].category == "platforms")

  p.state, p.space_connection, p.distance, p.space_location = STATE.waiting_for_departure, nil, nil, loc("gleba")
  platforms.on_state_changed({ platform = p, old_state = STATE.on_the_path })
  local a = events("platform_arrived")
  assert(#a == 1 and a[1].index == 3 and a[1].location == "gleba")

  platforms.on_state_changed({ platform = p, old_state = STATE.no_schedule })
  assert(#events("platform_departed") == 1 and #events("platform_arrived") == 1)

  reset(false)
  platforms.on_state_changed({ platform = p, old_state = STATE.on_the_path })
  assert(#sent == 0 and #updates == 0)
end

-- losses on a platform surface (any killer) make a damage episode; others do not
do
  reset()
  local p = platform(3, "Hauler 2", "no_schedule", { space_location = loc("gleba") })
  world(p)
  platforms.on_entity_died({ entity = belt(p) }) -- no killer force: asteroids count too
  game.tick = 600
  platforms.on_entity_died({ entity = belt(p), force = { name = "enemy" } })
  platforms.on_entity_died({ entity = belt(p, { type = "character", name = "character" }) })
  platforms.on_entity_died({ entity = belt(p, { force = { name = "neutral" } }) })
  platforms.on_entity_died({ entity = belt(p, { surface = { name = "nauvis", valid = true, platform = nil } }) })
  local dmg = platforms.collect().list[1].damage
  assert(dmg.active == true and dmg.since_tick == 0 and dmg.losses["transport-belt"] == 2)
  assert(#updates >= 1) -- the start of an episode is pushed at once

  game.tick = 600 + 3599
  platforms.tick()
  assert(#events("platform_damaged") == 0)
  game.tick = 600 + 3600
  platforms.tick()
  local e = events("platform_damaged")
  assert(#e == 1 and e[1].index == 3 and e[1].name == "Hauler 2" and e[1].losses["transport-belt"] == 2 and e[1].duration_s == 10)
  assert(platforms.collect().list[1].damage.active == false)
  game.tick = 600 + 36001
  platforms.tick()
  assert(platforms.collect().list[1].damage == nil and #events("platform_damaged") == 1)
end

-- a platform deleted mid-episode: no event, its record is dropped
do
  reset()
  local p = platform(3, "Hauler 2", "no_schedule", { space_location = loc("gleba") })
  world(p)
  platforms.on_entity_died({ entity = belt(p) })
  world()
  game.tick = 5000
  platforms.tick()
  assert(#events("platform_damaged") == 0)
  world(p)
  assert(platforms.collect().list[1].damage == nil)
end

-- disabled: deaths are ignored and the damage state is dropped
do
  reset()
  local p = platform(3, "Hauler 2", "no_schedule", { space_location = loc("gleba") })
  world(p)
  platforms.on_entity_died({ entity = belt(p) })
  config.apply({ v = 1, categories = {} })
  platforms.tick()
  assert(storage.platform_damage == nil)
  platforms.on_entity_died({ entity = belt(p) })
  assert(storage.platform_damage == nil)
end

print("platforms ok")
