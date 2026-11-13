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

-- random churn between batches: every item live for a whole lap is visited exactly once in it,
-- an item added during a lap at most once, a removed item never again; no holes are left
do
  math.randomseed(20261113)
  local reg = scanner.new()
  local live, ids, next_id = {}, {}, 0
  local function add()
    next_id = next_id + 1
    scanner.add(reg, next_id, { id = next_id })
    live[next_id] = true
    ids[#ids + 1] = next_id
  end
  local function remove_random()
    if #ids == 0 then return end
    local i = math.random(#ids)
    local id = ids[i]
    ids[i] = ids[#ids]
    ids[#ids] = nil
    live[id] = nil
    assert(scanner.remove(reg, id).id == id)
  end
  for _ = 1, 300 do add() end
  local laps = 0
  while laps < 40 do
    -- a lap starts when the cursor is past the end
    assert(reg.cursor > #reg.ids or laps == 0)
    local at_start, removed, seen = {}, {}, {}
    for id in pairs(live) do at_start[id] = true end
    repeat
      for _, item in ipairs(scanner.next_batch(reg, math.random(1, 25))) do
        assert(live[item.id], "a removed item came back: " .. item.id)
        seen[item.id] = (seen[item.id] or 0) + 1
        assert(seen[item.id] == 1, "visited twice in a lap: " .. item.id)
      end
      -- churn in the middle of the lap (an add after its end would extend it, by design)
      if reg.cursor <= #reg.ids then
        for _ = 1, math.random(0, 4) do
          local r = math.random()
          if r < 0.45 then
            local before = {}
            for id in pairs(live) do before[id] = true end
            remove_random()
            for id in pairs(before) do if not live[id] then removed[id] = true end end
          elseif r < 0.8 then
            add()
          end
        end
      end
      assert(#reg.ids == scanner.count(reg) and reg.dead == 0, "no holes")
    until reg.cursor > #reg.ids
    for id in pairs(at_start) do
      if not removed[id] then assert(seen[id] == 1, "lap " .. laps .. ": item " .. id .. " skipped") end
    end
    laps = laps + 1
  end
end

-- a registry saved by an older version (false holes) is compacted once, mid-lap position kept
do
  local reg = { ids = { 1, false, 3, false, 5, 6 }, pos = { [1] = 1, [3] = 3, [5] = 5, [6] = 6 },
                items = { [1] = { id = 1 }, [3] = { id = 3 }, [5] = { id = 5 }, [6] = { id = 6 } },
                cursor = 4, count = 4, dead = 2 } -- 1 and 3 visited, 5 and 6 not
  local got = {}
  for _, item in ipairs(scanner.next_batch(reg, 10)) do got[#got + 1] = item.id end
  assert(table.concat(got, ",") == "5,6", table.concat(got, ","))
  assert(reg.dead == 0 and #reg.ids == 4)
  got = {}
  for _, item in ipairs(scanner.next_batch(reg, 10)) do got[#got + 1] = item.id end
  assert(table.concat(got, ",") == "1,3,5,6", "the next lap has everything")
  -- removal from an old registry compacts first as well
  reg = { ids = { 1, false, 3 }, pos = { [1] = 1, [3] = 3 }, items = { [1] = {}, [3] = {} },
          cursor = 2, count = 2, dead = 1 }
  scanner.remove(reg, 1)
  assert(#reg.ids == 1 and reg.ids[1] == 3 and reg.cursor == 1 and reg.pos[3] == 1)
end

print("scanner_test ok")
