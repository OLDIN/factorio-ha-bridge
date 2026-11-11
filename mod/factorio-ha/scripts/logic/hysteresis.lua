-- Hold-time hysteresis for raise/clear events (no game API, Lua 5.2 compatible).
-- state: plain table (lives in `storage`); one entry per key.

local hysteresis = {}

-- active: current raw condition. Returns "raised" once the condition has held for
-- hold_ticks, "cleared" once it has been absent for hold_ticks after a raise, else nil.
function hysteresis.update(state, key, active, tick, hold_ticks)
  local s = state[key]
  if not s then
    s = { active = active, since = tick, raised = false }
    state[key] = s
  elseif s.active ~= active then
    s.active, s.since = active, tick
  end
  local held = tick - s.since >= hold_ticks
  if active and held and not s.raised then
    s.raised = true
    return "raised"
  elseif not active and held and s.raised then
    s.raised = false
    return "cleared"
  end
  return nil
end

return hysteresis
