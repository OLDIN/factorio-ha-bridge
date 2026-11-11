-- Pure-logic tests for scripts/logic/bodies.lua.
package.path = "factorio-ha/?.lua;" .. package.path
local bodies = require("scripts.logic.bodies")

local parents = bodies.find_parents({
  { name = "fulgora", x = 10, y = -20, origin_x = 0, origin_y = 0 },
  { name = "cerys", x = 11, y = -21, origin_x = 10.005, origin_y = -20 },
  { name = "frozeta", x = 5, y = 5, origin_x = 0, origin_y = 0 },
  { name = "stray", x = 7, y = 7, origin_x = 99, origin_y = 99 },
}, 0.01)
assert(parents.cerys == "fulgora", "moon matches planet position within tolerance")
assert(parents.frozeta == nil, "origin (0,0) matches nothing")
assert(parents.fulgora == nil)
assert(parents.stray == nil, "unmatched origin has no parent")

-- a body is never its own parent
local self_p = bodies.find_parents({ { name = "a", x = 1, y = 1, origin_x = 1, origin_y = 1 } }, 0.01)
assert(self_p.a == nil)

-- just outside tolerance
local far = bodies.find_parents({
  { name = "p", x = 10, y = 10, origin_x = 0, origin_y = 0 },
  { name = "m", x = 0, y = 0, origin_x = 10.02, origin_y = 10 },
}, 0.01)
assert(far.m == nil)

assert(bodies.state(false, false) == "locked")
assert(bodies.state(false, true) == "locked")
assert(bodies.state(true, false) == "unlocked")
assert(bodies.state(true, true) == "built")

print("bodies_test ok")
