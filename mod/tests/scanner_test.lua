-- Pure-logic tests for scripts/logic/scanner.lua.
package.path = "factorio-ha/?.lua;" .. package.path
local scanner = require("scripts.logic.scanner")

local function fill(n)
  local reg = scanner.new()
  for i = 1, n do scanner.add(reg, i, { id = i }) end
  return reg
end

-- 25 items, n = 10: a full circle in 3 calls, each item exactly once
do
  local reg = fill(25)
  local seen, sizes = {}, {}
  for call = 1, 3 do
    local batch = scanner.next_batch(reg, 10)
    sizes[call] = #batch
    for _, item in ipairs(batch) do seen[item.id] = (seen[item.id] or 0) + 1 end
  end
  assert(sizes[1] == 10 and sizes[2] == 10 and sizes[3] == 5, "batch sizes " .. table.concat(sizes, ","))
  for i = 1, 25 do assert(seen[i] == 1, "item " .. i .. " seen " .. tostring(seen[i])) end
  -- the next call starts a new circle
  assert(scanner.next_batch(reg, 10)[1].id == 1, "circle restarts")
end

-- removal in the middle of a circle: no duplicates, no skips of survivors
do
  local reg = fill(25)
  local seen = {}
  local function take(n)
    for _, item in ipairs(scanner.next_batch(reg, n)) do seen[item.id] = (seen[item.id] or 0) + 1 end
  end
  take(10)
  scanner.remove(reg, 3)  -- already visited
  scanner.remove(reg, 20) -- not yet visited
  take(10)
  take(10)
  for i = 1, 25 do
    if i == 20 then
      assert(seen[i] == nil, "removed unvisited item is never returned")
    else
      assert(seen[i] == 1, "item " .. i .. " seen " .. tostring(seen[i]))
    end
  end
  assert(scanner.count(reg) == 23)
end

-- add during a circle is seen once; re-add of an id does not duplicate
do
  local reg = fill(5)
  scanner.add(reg, 99, { id = 99 })
  scanner.add(reg, 99, { id = 99 })
  assert(scanner.count(reg) == 6)
  local seen = {}
  for _ = 1, 3 do
    for _, item in ipairs(scanner.next_batch(reg, 2)) do seen[item.id] = (seen[item.id] or 0) + 1 end
  end
  assert(seen[99] == 1)
end

-- empty registry and removing an unknown id are harmless
do
  local reg = scanner.new()
  assert(#scanner.next_batch(reg, 10) == 0)
  assert(scanner.remove(reg, 1) == nil)
  scanner.add(reg, 1, "a")
  assert(scanner.remove(reg, 1) == "a")
  assert(#scanner.next_batch(reg, 10) == 0)
  assert(scanner.count(reg) == 0)
end

-- heavy churn compacts and keeps the invariant
do
  local reg = fill(100)
  for i = 1, 90 do scanner.remove(reg, i) end
  local seen, total = {}, 0
  for _ = 1, 2 do
    for _, item in ipairs(scanner.next_batch(reg, 5)) do
      seen[item.id] = (seen[item.id] or 0) + 1
      total = total + 1
    end
  end
  assert(total == 10, "10 survivors, got " .. total)
  for i = 91, 100 do assert(seen[i] == 1) end
end

print("scanner_test ok")
