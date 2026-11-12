-- Pure-logic tests for scripts/logic/voyage.lua (space platforms: route, transitions, damage).
package.path = "factorio-ha/?.lua;" .. package.path
local voyage = require("scripts.logic.voyage")

local function same_route(r, from, to, progress)
  assert(r.from == from, "from: " .. tostring(r.from))
  assert(r.to == to, "to: " .. tostring(r.to))
  assert(math.abs(r.progress - progress) < 1e-9, "progress: " .. tostring(r.progress))
end

-- route: the travel direction comes from the last visited location
same_route(voyage.route("nauvis", "aquilo", 0.3, "nauvis"), "nauvis", "aquilo", 0.3)
same_route(voyage.route("nauvis", "aquilo", 0.3, "aquilo"), "aquilo", "nauvis", 0.7)
same_route(voyage.route("nauvis", "aquilo", 0.3, nil), "nauvis", "aquilo", 0.3)
same_route(voyage.route("nauvis", "aquilo", 0.3, "gleba"), "nauvis", "aquilo", 0.3)
same_route(voyage.route("nauvis", "aquilo", 0.123456, "nauvis"), "nauvis", "aquilo", 0.12)
same_route(voyage.route("nauvis", "aquilo", 1.2, "nauvis"), "nauvis", "aquilo", 1)
same_route(voyage.route("nauvis", "aquilo", -0.1, "nauvis"), "nauvis", "aquilo", 0)
same_route(voyage.route("nauvis", "aquilo", nil, "nauvis"), "nauvis", "aquilo", 0)

-- transitions
assert(voyage.transition("waiting_for_departure", "on_the_path") == "departed")
assert(voyage.transition("on_the_path", "waiting_for_departure") == "arrived")
assert(voyage.transition("on_the_path", "on_the_path") == nil)
assert(voyage.transition("no_schedule", "paused") == nil)

-- one platform, one damage episode: merged while losses come less than QUIET_TICKS apart
do
  assert(voyage.QUIET_TICKS == 3600 and voyage.SHOW_TICKS == 36000)
  local s = voyage.new()
  assert(voyage.damage(s, 3, 0) == nil)
  assert(voyage.on_loss(s, 3, 100, "transport-belt") == true)
  assert(voyage.on_loss(s, 3, 3000, "transport-belt") == false)
  local d = voyage.damage(s, 3, 3000)
  assert(d.active == true and d.since_tick == 100 and d.losses["transport-belt"] == 2)
  -- the game is paused: the same tick twice ends nothing
  assert(#voyage.expire(s, 3000) == 0)
  assert(#voyage.expire(s, 3000) == 0)
  assert(#voyage.expire(s, 6599) == 0)
  local ended = voyage.expire(s, 6600)
  assert(#ended == 1)
  assert(ended[1].index == 3 and ended[1].losses["transport-belt"] == 2 and ended[1].duration_s == 48)
  assert(#voyage.expire(s, 6700) == 0) -- an ended episode ends once
  d = voyage.damage(s, 3, 6600)
  assert(d.active == false and d.losses["transport-belt"] == 2)
  assert(voyage.damage(s, 3, 39000) ~= nil) -- shown for SHOW_TICKS after the last loss
  assert(#voyage.expire(s, 39000) == 0)       -- dropping it is not an event
  assert(voyage.damage(s, 3, 39000) == nil)
end

-- a loss after an ended episode starts a new one, counted from zero
do
  local s = voyage.new()
  voyage.on_loss(s, 3, 0, "transport-belt")
  voyage.on_loss(s, 3, 10, "transport-belt")
  voyage.expire(s, 4000)
  assert(voyage.on_loss(s, 3, 5000, "solar-panel") == true)
  local d = voyage.damage(s, 3, 5000)
  assert(d.active == true and d.since_tick == 5000 and d.losses["solar-panel"] == 1 and d.losses["transport-belt"] == nil)
end

-- platforms are independent
do
  local s = voyage.new()
  assert(voyage.on_loss(s, 3, 0, "a") == true)
  assert(voyage.on_loss(s, 5, 10, "b") == true)
  assert(voyage.damage(s, 3, 10).losses.a == 1 and voyage.damage(s, 5, 10).losses.b == 1)
end

-- prune drops platforms that are gone, active or not
do
  local s = voyage.new()
  voyage.on_loss(s, 3, 0, "a")
  voyage.on_loss(s, 5, 0, "b")
  voyage.prune(s, { [5] = true })
  assert(voyage.damage(s, 3, 1) == nil and voyage.damage(s, 5, 1) ~= nil)
  assert(#voyage.expire(s, 99999) == 1) -- only platform 5 ends
end

print("voyage ok")
