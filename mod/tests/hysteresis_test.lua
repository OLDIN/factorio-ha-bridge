-- Pure-logic tests for scripts/logic/hysteresis.lua.
package.path = "factorio-ha/?.lua;" .. package.path
local hysteresis = require("scripts.logic.hysteresis")

-- active for 599 ticks: nothing; at 600: raised; once only
do
  local s = {}
  assert(hysteresis.update(s, "p", true, 0, 600) == nil)
  assert(hysteresis.update(s, "p", true, 599, 600) == nil)
  assert(hysteresis.update(s, "p", true, 600, 600) == "raised")
  assert(hysteresis.update(s, "p", true, 610, 600) == nil)
  assert(hysteresis.update(s, "p", true, 5000, 600) == nil)
end

-- inactive for 600 ticks after raised: cleared once
do
  local s = {}
  hysteresis.update(s, "p", true, 0, 600)
  assert(hysteresis.update(s, "p", true, 600, 600) == "raised")
  assert(hysteresis.update(s, "p", false, 700, 600) == nil)
  assert(hysteresis.update(s, "p", false, 1299, 600) == nil)
  assert(hysteresis.update(s, "p", false, 1300, 600) == "cleared")
  assert(hysteresis.update(s, "p", false, 1400, 600) == nil)
end

-- a flicker restarts the timer
do
  local s = {}
  hysteresis.update(s, "p", true, 0, 600)
  hysteresis.update(s, "p", false, 300, 600)
  assert(hysteresis.update(s, "p", true, 400, 600) == nil)
  assert(hysteresis.update(s, "p", true, 999, 600) == nil)
  assert(hysteresis.update(s, "p", true, 1000, 600) == "raised")
end

-- never raised: no "cleared"; keys are independent
do
  local s = {}
  assert(hysteresis.update(s, "a", false, 0, 600) == nil)
  assert(hysteresis.update(s, "a", false, 5000, 600) == nil)
  hysteresis.update(s, "b", true, 0, 600)
  assert(hysteresis.update(s, "a", true, 100, 600) == nil)
  assert(hysteresis.update(s, "b", true, 600, 600) == "raised")
end

print("hysteresis_test ok")
