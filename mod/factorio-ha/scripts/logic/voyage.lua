-- Space platforms, pure logic (no game API, Lua 5.2 compatible): the direction of a flight,
-- departures and arrivals from state changes, and damage episodes. The damage state is plain
-- data and lives in `storage`.
--
-- A damage episode is per platform: every loss on the platform's surface joins the running
-- episode while it comes less than QUIET_TICKS after the latest one, whatever killed it.
-- An episode ends after QUIET_TICKS game ticks without losses (ticks: pausing ends nothing)
-- and is still shown for SHOW_TICKS after its last loss.

local voyage = {}

voyage.QUIET_TICKS = 3600  -- 60 s of game time
voyage.SHOW_TICKS = 36000  -- 10 min of game time

local FLYING = "on_the_path"

local function clamp01(v)
  if type(v) ~= "number" or v ~= v then return 0 end
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

-- Position along a space connection in the direction of travel. `distance` is 0 at the
-- connection's `from` and 1 at its `to`; a platform that last visited the `to` end flies back.
-- Returns {from, to, progress}, progress rounded to 0.01.
function voyage.route(conn_from, conn_to, distance, last_visited)
  local d = clamp01(distance)
  local from, to = conn_from, conn_to
  if last_visited ~= nil and last_visited == conn_to and conn_to ~= conn_from then
    from, to, d = conn_to, conn_from, 1 - d
  end
  return { from = from, to = to, progress = math.floor(d * 100 + 0.5) / 100 }
end

-- "departed" when a platform starts flying, "arrived" when it stops, else nil.
function voyage.transition(old_state, new_state)
  if new_state == FLYING and old_state ~= FLYING then return "departed" end
  if old_state == FLYING and new_state ~= FLYING then return "arrived" end
  return nil
end

function voyage.new()
  return { by_platform = {} }
end

-- Registers a loss on platform `index`. Returns true when it starts a new episode.
function voyage.on_loss(state, index, tick, name)
  local rec = state.by_platform[index]
  if rec and not rec.ended and tick - rec.last_tick < voyage.QUIET_TICKS then
    rec.last_tick = tick
    rec.losses[name] = (rec.losses[name] or 0) + 1
    return false
  end
  state.by_platform[index] = { since_tick = tick, last_tick = tick, losses = { [name] = 1 }, ended = false }
  return true
end

-- Ends episodes quiet for QUIET_TICKS (returned as {index, losses, duration_s}; duration from
-- the first to the last loss) and forgets ended ones SHOW_TICKS after their last loss.
function voyage.expire(state, now)
  local ended = {}
  local indices = {}
  for index in pairs(state.by_platform) do indices[#indices + 1] = index end
  table.sort(indices)
  for _, index in ipairs(indices) do
    local rec = state.by_platform[index]
    local quiet = now - rec.last_tick
    if not rec.ended and quiet >= voyage.QUIET_TICKS then
      rec.ended = true
      ended[#ended + 1] = {
        index = index, losses = rec.losses,
        duration_s = math.floor((rec.last_tick - rec.since_tick) / 60),
      }
    end
    if rec.ended and quiet >= voyage.SHOW_TICKS then state.by_platform[index] = nil end
  end
  return ended
end

-- The damage to show for a platform: {active, since_tick, losses} or nil.
function voyage.damage(state, index, now)
  local rec = state.by_platform[index]
  if not rec then return nil end
  if rec.ended and now - rec.last_tick > voyage.SHOW_TICKS then return nil end
  return { active = not rec.ended, since_tick = rec.since_tick, losses = rec.losses }
end

-- Forgets platforms that no longer exist; `alive` is a set of platform indices.
function voyage.prune(state, alive)
  for index in pairs(state.by_platform) do
    if not alive[index] then state.by_platform[index] = nil end
  end
end

return voyage
