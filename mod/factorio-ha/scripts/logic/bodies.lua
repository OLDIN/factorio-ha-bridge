-- Pure logic for solar-system bodies (no game API, testable with plain Lua).

local bodies = {}

-- locations: list of {name, x, y, origin_x, origin_y}. Returns {name = parent_name | nil}:
-- the body whose position equals this body's origin within `tolerance`. Callers must
-- pass only non-hidden bodies: the hidden `star` sits at (0,0), the origin of every planet.
function bodies.find_parents(locations, tolerance)
  local parents = {}
  for _, body in ipairs(locations) do
    for _, other in ipairs(locations) do
      if other.name ~= body.name
        and math.abs(other.x - body.origin_x) <= tolerance
        and math.abs(other.y - body.origin_y) <= tolerance then
        parents[body.name] = other.name
        break
      end
    end
  end
  return parents
end

-- "locked" | "unlocked" | "built"
function bodies.state(unlocked, has_buildings)
  if not unlocked then return "locked" end
  if has_buildings then return "built" end
  return "unlocked"
end

return bodies
