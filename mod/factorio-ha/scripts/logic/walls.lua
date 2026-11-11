-- Damaged-wall registry (no game API, Lua 5.2 compatible): a scanner registry plus
-- incremental per-planet counts and id sets, so reading counts/positions is O(planets)
-- and a repair check walks the walls in portions. Plain tables, lives in `storage`.
-- item = {id, entity, planet}

local scanner = require("scripts.logic.scanner")

local walls = {}

function walls.new()
  return { reg = scanner.new(), counts = {}, ids = {} }
end

function walls.is_registry(w)
  return type(w) == "table" and w.reg ~= nil
end

function walls.count(w, planet)
  return w.counts[planet] or 0
end

function walls.total(w)
  return scanner.count(w.reg)
end

-- Returns true if the wall was new. O(1).
function walls.add(w, id, entity, planet)
  if scanner.get(w.reg, id) then return false end
  scanner.add(w.reg, id, { id = id, entity = entity, planet = planet })
  w.counts[planet] = (w.counts[planet] or 0) + 1
  local ids = w.ids[planet]
  if not ids then ids = {}; w.ids[planet] = ids end
  ids[id] = true
  return true
end

function walls.remove(w, id)
  local item = scanner.remove(w.reg, id)
  if not item then return false end
  local n = (w.counts[item.planet] or 1) - 1
  local ids = w.ids[item.planet]
  if ids then ids[id] = nil end
  if n <= 0 then
    w.counts[item.planet], w.ids[item.planet] = nil, nil
  else
    w.counts[item.planet] = n
  end
  return true
end

-- Up to `limit` ids of damaged walls on a planet (arbitrary order).
function walls.some_ids(w, planet, limit)
  local out = {}
  for id in pairs(w.ids[planet] or {}) do
    if #out >= limit then break end
    out[#out + 1] = id
  end
  return out
end

function walls.entity(w, id)
  local item = scanner.get(w.reg, id)
  return item and item.entity
end

-- One portion of the repair check: visits up to `batch` walls and drops those for which
-- is_done(entity) is true. Returns the number removed.
function walls.step(w, batch, is_done)
  local removed = 0
  for _, item in ipairs(scanner.next_batch(w.reg, batch)) do
    if is_done(item.entity) then
      walls.remove(w, item.id)
      removed = removed + 1
    end
  end
  return removed
end

return walls
