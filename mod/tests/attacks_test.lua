-- Pure-logic tests for scripts/logic/attacks.lua and the AFK helper in scripts/players.lua.
package.path = "factorio-ha/?.lua;" .. package.path
local attacks = require("scripts.logic.attacks")

local function loss(tick, x, y, name, surface)
  return { tick = tick, surface = surface or "nauvis", planet = surface or "nauvis", x = x, y = y, name = name or "stone-wall" }
end

-- 1000 losses within 30 s and radius 50: one started, one ended with summed losses
do
  local s = attacks.new()
  local started = 0
  for i = 0, 999 do
    local r = attacks.on_loss(s, loss(i * 1.8, 100 + (i % 50), 200 - (i % 40), i % 4 == 0 and "gun-turret" or "stone-wall"))
    if r then
      started = started + 1
      assert(r.planet == "nauvis" and r.surface == "nauvis")
      assert(r.position[1] == 100 and r.position[2] == 200)
      assert(r.gps == "[gps=100,200,nauvis]")
    end
  end
  assert(started == 1)
  local cur = attacks.current(s, "nauvis")
  assert(cur.since_tick == 0 and cur.losses["gun-turret"] == 250 and cur.losses["stone-wall"] == 750)
  assert(#attacks.expire(s, 1798 + 3599) == 0)
  local ended = attacks.expire(s, 1798 + 3700)
  assert(#ended == 1)
  assert(ended[1].losses["gun-turret"] == 250 and ended[1].losses["stone-wall"] == 750)
  assert(ended[1].duration_s == math.floor(999 * 1.8 / 60))
  assert(ended[1].gps == "[gps=100,200,nauvis]" and ended[1].planet == "nauvis")
  assert(attacks.current(s, "nauvis") == nil)
  assert(#attacks.expire(s, 99999) == 0)
end

-- a loss 150 tiles from the first one is a separate attack; both end on their own
do
  local s = attacks.new()
  assert(attacks.on_loss(s, loss(0, 0, 0)))
  assert(attacks.on_loss(s, loss(10, 100, 0)) == nil) -- exactly 100: same attack
  local second = attacks.on_loss(s, loss(20, 150, 0))
  assert(second and second.position[1] == 150)
  assert(attacks.on_loss(s, loss(30, 5, 5)) == nil) -- still merges into the first
  -- the planet shows the attack with the most recent loss (the first one, merged at tick 30)
  assert(attacks.current(s, "nauvis").since_tick == 0)
  local ended = attacks.expire(s, 30 + 3600)
  assert(#ended == 2)
end

-- distance is measured from the FIRST loss, not from the previous one
do
  local s = attacks.new()
  assert(attacks.on_loss(s, loss(0, 0, 0)))
  assert(attacks.on_loss(s, loss(1, 80, 0)) == nil)
  assert(attacks.on_loss(s, loss(2, 160, 0))) -- 80 from the previous, 160 from the first
end

-- another surface is never merged
do
  local s = attacks.new()
  assert(attacks.on_loss(s, loss(0, 0, 0, "stone-wall", "nauvis")))
  assert(attacks.on_loss(s, loss(1, 0, 0, "stone-wall", "gleba")))
end

-- a gap of 3599 ticks keeps the attack, 3600 starts a new one
do
  local s = attacks.new()
  assert(attacks.on_loss(s, loss(0, 0, 0)))
  assert(attacks.on_loss(s, loss(3599, 0, 0)) == nil)
  assert(attacks.on_loss(s, loss(3599 + 3599, 0, 0)) == nil)
  local s2 = attacks.new()
  assert(attacks.on_loss(s2, loss(0, 0, 0)))
  assert(attacks.on_loss(s2, loss(3600, 0, 0)))
  local ended = attacks.expire(s2, 3600)
  assert(#ended == 1 and ended[1].losses["stone-wall"] == 1) -- the first one ended, the second runs
  assert(attacks.current(s2, "nauvis").since_tick == 3600)
end

-- game paused: ticks do not advance, so expire never ends the attack
do
  local s = attacks.new()
  assert(attacks.on_loss(s, loss(100, 0, 0)))
  for _ = 1, 1000 do assert(#attacks.expire(s, 100) == 0) end
  assert(#attacks.expire(s, 100 + 3599) == 0)
  assert(#attacks.expire(s, 100 + 3600) == 1)
end

-- state is plain data: survives a deep copy (what save/load does to `storage`)
do
  local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = copy(x) end
    return t
  end
  local s = attacks.new()
  attacks.on_loss(s, loss(0, 0, 0))
  s = copy(s)
  assert(attacks.on_loss(s, loss(5, 3, 3)) == nil)
  assert(#attacks.expire(s, 5 + 3600) == 1)
end

-- AFK minutes and the player_died payload (no game API needed)
do
  local players = require("scripts.players")
  local afk = players.afk_minutes({
    { name = "alice", afk_time = 0 },
    { name = "bob", afk_time = 3599 },
    { name = "guest", afk_time = 3600 * 4 + 10 },
  })
  assert(afk.guest == 4 and afk.alice == nil and afk.bob == nil)
  local d = players.death_data({ name = "alice" }, "gleba", "gleba", { name = "small-biter" })
  assert(d.player == "alice" and d.planet == "gleba" and d.surface == "gleba" and d.cause == "small-biter")
  d = players.death_data({ name = "alice" }, nil, "platform-1", nil)
  assert(d.planet == nil and d.cause == nil)
end

print("attacks tests passed")
