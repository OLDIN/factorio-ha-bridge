-- Pure-logic tests for scripts/logic/fill.lua.
package.path = "factorio-ha/?.lua;" .. package.path
local fill = require("scripts.logic.fill")

local function run(names, lists, cap)
  local f = fill.new(names)
  local seen, steps = {}, 0
  local function find(name) return lists[name] or {} end
  local function visit(item) seen[#seen + 1] = item end
  while not fill.is_done(f) do
    fill.step(f, cap, find, visit)
    steps = steps + 1
    assert(steps < 100, "runaway")
  end
  return seen, steps
end

-- 450 items, cap 200: 3 steps, each item once
do
  local list = {}
  for i = 1, 450 do list[i] = i end
  local seen, steps = run({ "a" }, { a = list }, 200)
  assert(steps == 3, "steps " .. steps)
  assert(#seen == 450)
  for i = 1, 450 do assert(seen[i] == i) end
end

-- empty surface list: done immediately, nothing visited
do
  local f = fill.new({})
  assert(fill.is_done(f))
  local called = false
  fill.step(f, 200, function() called = true; return {} end, function() called = true end)
  assert(not called)
end

-- several surfaces; empty surface; cap never exceeded per step
do
  local lists = { a = { 1, 2, 3 }, b = {}, c = { 4, 5 } }
  local f = fill.new({ "a", "b", "c" })
  local total = 0
  while not fill.is_done(f) do
    local n = 0
    fill.step(f, 2, function(name) return lists[name] end, function() n = n + 1 end)
    assert(n <= 2)
    total = total + n
  end
  assert(total == 5)
end

print("fill_test ok")
