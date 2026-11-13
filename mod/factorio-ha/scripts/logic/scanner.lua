-- Generic round-robin registry for chunked scanning (no game API, Lua 5.2 compatible).
-- Items are handed out in batches; one lap visits every live item exactly once.
-- Plain tables only, so a registry can live in Factorio's `storage`.

local scanner = {}

function scanner.new()
  -- ids: the live ids in lap order; positions before `cursor` are visited in this lap, the rest
  -- are not. Removal fills its hole at once (see remove), so there is nothing to compact.
  -- `dead` counts `false` holes left by older versions: such a registry is compacted once.
  return { ids = {}, pos = {}, items = {}, cursor = 1, count = 0, dead = 0 }
end

function scanner.count(reg)
  return reg.count
end

function scanner.get(reg, id)
  return reg.items[id]
end

-- Drops the `false` holes of a registry saved by an older version, keeping the lap position.
local function compact(reg)
  local ids, pos, cursor = {}, {}, nil
  for i, id in ipairs(reg.ids) do -- ipairs walks over false, stops at nil
    if i == reg.cursor then cursor = #ids + 1 end
    if id ~= false then
      ids[#ids + 1] = id
      pos[id] = #ids
    end
  end
  reg.ids, reg.pos, reg.dead = ids, pos, 0
  reg.cursor = cursor or #ids + 1
end

-- Adds an item, or replaces the item of a known id (no duplicate slot).
function scanner.add(reg, id, item)
  if reg.pos[id] == nil then
    if reg.dead > 0 then compact(reg) end
    local n = #reg.ids + 1
    reg.ids[n] = id
    reg.pos[id] = n
    reg.count = reg.count + 1
  end
  reg.items[id] = item
end

local function move(reg, from, to)
  if from == to then return end
  local id = reg.ids[from]
  reg.ids[to] = id
  reg.pos[id] = to
end

-- Returns the removed item, or nil if the id was unknown. O(1): the hole is filled so that
-- the lap stays intact. A hole among the visited ids takes the last visited id, whose place
-- takes the last id (not visited yet) and the cursor steps back onto it; a hole among the
-- ids not visited yet takes the last id.
function scanner.remove(reg, id)
  if reg.pos[id] == nil then return nil end
  if reg.dead > 0 then compact(reg) end
  local p, last = reg.pos[id], #reg.ids
  local item = reg.items[id]
  if p < reg.cursor then
    local visited = reg.cursor - 1
    move(reg, visited, p)
    move(reg, last, visited)
    reg.cursor = visited
  else
    move(reg, last, p)
  end
  reg.ids[last] = nil
  reg.pos[id] = nil
  reg.items[id] = nil
  reg.count = reg.count - 1
  return item
end

-- Up to n items from the cursor; never crosses the end of a lap, so the call after
-- the lap's last batch starts a fresh lap from the first item.
function scanner.next_batch(reg, n)
  if reg.dead > 0 then compact(reg) end
  if reg.cursor > #reg.ids then reg.cursor = 1 end
  local batch = {}
  local ids, items = reg.ids, reg.items
  local cursor, stop = reg.cursor, math.min(#ids, reg.cursor + n - 1)
  for i = cursor, stop do batch[#batch + 1] = items[ids[i]] end
  reg.cursor = stop + 1
  return batch
end

return scanner
