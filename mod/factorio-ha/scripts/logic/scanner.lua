-- Generic round-robin registry for chunked scanning (no game API, Lua 5.2 compatible).
-- Items are handed out in batches; one lap visits every live item exactly once.
-- Plain tables only, so a registry can live in Factorio's `storage`.

local scanner = {}

function scanner.new()
  -- ids: insertion-ordered ids, `false` marks a removed slot (compacted at lap start)
  return { ids = {}, pos = {}, items = {}, cursor = 1, count = 0, dead = 0 }
end

function scanner.count(reg)
  return reg.count
end

function scanner.get(reg, id)
  return reg.items[id]
end

-- Adds an item, or replaces the item of a known id (no duplicate slot).
function scanner.add(reg, id, item)
  if reg.pos[id] == nil then
    local n = #reg.ids + 1
    reg.ids[n] = id
    reg.pos[id] = n
    reg.count = reg.count + 1
  end
  reg.items[id] = item
end

-- Returns the removed item, or nil if the id was unknown.
function scanner.remove(reg, id)
  local p = reg.pos[id]
  if p == nil then return nil end
  local item = reg.items[id]
  reg.ids[p] = false
  reg.pos[id] = nil
  reg.items[id] = nil
  reg.count = reg.count - 1
  reg.dead = reg.dead + 1
  return item
end

local function compact(reg)
  local ids, pos = {}, {}
  for _, id in ipairs(reg.ids) do
    if id ~= false then
      ids[#ids + 1] = id
      pos[id] = #ids
    end
  end
  reg.ids, reg.pos, reg.dead = ids, pos, 0
end

-- Up to n items from the cursor; never crosses the end of a lap, so the call after
-- the lap's last batch starts a fresh lap from the first item.
function scanner.next_batch(reg, n)
  if reg.cursor > #reg.ids then
    if reg.dead > 0 then compact(reg) end
    reg.cursor = 1
  end
  local batch = {}
  local ids = reg.ids
  while #batch < n and reg.cursor <= #ids do
    local id = ids[reg.cursor]
    reg.cursor = reg.cursor + 1
    if id ~= false then batch[#batch + 1] = reg.items[id] end
  end
  return batch
end

return scanner
