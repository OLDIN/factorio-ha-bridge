-- Attack detection: losses are merged into attacks by surface, distance and time
-- (no game API, Lua 5.2 compatible). The state is plain data and lives in `storage`.
--
-- A loss is {tick, surface, planet, x, y, name}. An attack starts at its first loss;
-- later losses join it when they are on the same surface, within MERGE_RADIUS tiles of
-- the FIRST loss, and less than QUIET_TICKS after the attack's latest loss. An attack
-- ends once QUIET_TICKS game ticks pass without losses (ticks, so pausing never ends it).

local attacks = {}

attacks.MERGE_RADIUS = 100
attacks.QUIET_TICKS = 3600

local function round(v) return math.floor(v + 0.5) end

function attacks.new()
  return { list = {}, next_id = 1 }
end

local function describe(a)
  local px, py = round(a.x), round(a.y)
  return {
    planet = a.planet, surface = a.surface,
    position = { px, py },
    gps = "[gps=" .. px .. "," .. py .. "," .. a.surface .. "]",
  }
end

-- Registers a loss. Returns {planet, surface, position, gps} when it starts a new attack.
function attacks.on_loss(state, loss)
  local r2 = attacks.MERGE_RADIUS * attacks.MERGE_RADIUS
  local list = state.list
  for i = #list, 1, -1 do -- newest first; the list is short
    local a = list[i]
    if a.surface == loss.surface and loss.tick - a.last_tick < attacks.QUIET_TICKS then
      local dx, dy = loss.x - a.x, loss.y - a.y
      if dx * dx + dy * dy <= r2 then
        a.last_tick = loss.tick
        a.losses[loss.name] = (a.losses[loss.name] or 0) + 1
        return nil
      end
    end
  end
  local a = {
    id = state.next_id, planet = loss.planet, surface = loss.surface,
    x = loss.x, y = loss.y, since_tick = loss.tick, last_tick = loss.tick,
    losses = { [loss.name] = 1 },
  }
  state.next_id = state.next_id + 1
  list[#list + 1] = a
  return describe(a)
end

-- Ends attacks quiet for QUIET_TICKS. Returns a list of {planet, surface, position, gps,
-- duration_s, losses}; duration is from the first to the last loss.
function attacks.expire(state, now)
  local ended, keep = {}, {}
  for _, a in ipairs(state.list) do
    if now - a.last_tick >= attacks.QUIET_TICKS then
      local e = describe(a)
      e.duration_s = math.floor((a.last_tick - a.since_tick) / 60)
      e.losses = a.losses
      ended[#ended + 1] = e
    else
      keep[#keep + 1] = a
    end
  end
  if #ended > 0 then state.list = keep end
  return ended
end

function attacks.active(state)
  return #state.list > 0
end

-- The attack to show for a planet: the one with the most recent loss.
-- Returns {since_tick, position, gps, losses} or nil.
function attacks.current(state, planet)
  local best
  for _, a in ipairs(state.list) do
    if a.planet == planet and (not best or a.last_tick >= best.last_tick) then best = a end
  end
  if not best then return nil end
  local d = describe(best)
  return { since_tick = best.since_tick, position = d.position, gps = d.gps, losses = best.losses }
end

return attacks
