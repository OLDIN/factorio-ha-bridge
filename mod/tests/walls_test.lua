-- Pure-logic tests for scripts/logic/walls.lua.
package.path = "factorio-ha/?.lua;" .. package.path
local walls = require("scripts.logic.walls")

local w = walls.new()
assert(walls.add(w, 1, { hp = 1 }, "nauvis"))
assert(not walls.add(w, 1, { hp = 1 }, "nauvis"), "duplicate add")
for i = 2, 10 do walls.add(w, i, { hp = 1 }, i <= 7 and "nauvis" or "gleba") end
assert(walls.count(w, "nauvis") == 7 and walls.count(w, "gleba") == 3 and walls.total(w) == 10)
assert(#walls.some_ids(w, "nauvis", 5) == 5 and #walls.some_ids(w, "gleba", 5) == 3)
assert(#walls.some_ids(w, "vulcanus", 5) == 0)

for i = 1, 10 do walls.remove(w, i) end
assert(walls.total(w) == 0 and walls.count(w, "nauvis") == 0 and #walls.some_ids(w, "gleba", 5) == 0)
assert(w.counts.nauvis == nil and w.ids.gleba == nil, "empty planet entries dropped")
assert(not walls.remove(w, 1), "unknown id")

-- step: done entities are removed, others stay, whole lap visits each once
local w2 = walls.new()
for i = 1, 25 do walls.add(w2, i, { id = i, fixed = i % 5 == 0 }, "nauvis") end
local visits = {}
local total_removed = 0
for _ = 1, 3 do
  total_removed = total_removed + walls.step(w2, 10, function(e)
    visits[e.id] = (visits[e.id] or 0) + 1
    return e.fixed
  end)
end
for i = 1, 25 do assert(visits[i] == 1, "visit " .. i) end
assert(total_removed == 5 and walls.total(w2) == 20 and walls.count(w2, "nauvis") == 20)
assert(walls.entity(w2, 1).id == 1 and walls.entity(w2, 5) == nil)
assert(walls.is_registry(w2) and not walls.is_registry({ nauvis = { n = 1, set = {} } }))

print("walls_test ok")
