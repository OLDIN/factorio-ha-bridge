-- Capped initial fill (no game API, Lua 5.2 compatible; plain tables, lives in `storage`).
-- A queue of source names; each step visits at most `cap` items, keeping the found
-- list and a cursor between steps.

local fill = {}

function fill.new(names)
  local queue = {}
  for i, n in ipairs(names) do queue[i] = n end
  return { queue = queue, items = nil, pos = 0 }
end

function fill.is_done(f)
  return f.items == nil and #f.queue == 0
end

-- find(name) -> list of items; visit(item) is called at most cap times per step.
function fill.step(f, cap, find, visit)
  if f.items == nil then
    if #f.queue == 0 then return end
    f.items, f.pos = find(table.remove(f.queue, 1)) or {}, 0
  end
  local items, stop = f.items, math.min(#f.items, f.pos + cap)
  while f.pos < stop do
    f.pos = f.pos + 1
    visit(items[f.pos])
  end
  if f.pos >= #items then f.items, f.pos = nil, 0 end
end

return fill
