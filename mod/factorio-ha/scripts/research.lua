-- `research` category and the `research_finished` event.

local transport = require("scripts.transport")
local config = require("scripts.config")

local research = {}

local QUEUE_MAX = 5
local PROGRESS_STEP = 0.01

-- Last values sent (session-local; only throttles server-side UDP).
local last_name, last_level, last_progress, last_queue

local function unlocks_of(tech)
  local names = {}
  for _, effect in pairs(tech.prototype.effects or {}) do
    if effect.type == "unlock-space-location" and effect.space_location then
      local proto = prototypes.space_location[effect.space_location]
      if proto and not proto.hidden then names[#names + 1] = effect.space_location end
    end
  end
  table.sort(names)
  return names
end

local function queue_names(force)
  local names = {}
  for _, tech in ipairs(force.research_queue or {}) do
    if #names >= QUEUE_MAX then break end
    names[#names + 1] = tech.name
  end
  return names
end

function research.collect()
  local force = game.forces.player
  local data = { queue = queue_names(force) }
  local tech = force.current_research
  if tech then
    data.current = {
      name = tech.name,
      level = tech.level,
      progress = math.floor(force.research_progress * 1000 + 0.5) / 1000,
      unlocks = unlocks_of(tech),
    }
  end
  return data
end

local function remember(data)
  local c = data.current
  last_name, last_level, last_progress = c and c.name, c and c.level, c and c.progress
  last_queue = table.concat(data.queue, ",")
end

-- Snapshot path: collect and remember what was sent.
function research.snapshot()
  local data = research.collect()
  remember(data)
  return data
end

-- force=true: structural change (finished/started), send if anything differs.
-- Otherwise (periodic): send only on structural change or progress moved >= PROGRESS_STEP.
function research.refresh(force_send)
  if not config.enabled("research") then return end
  local data = research.collect()
  local c = data.current
  local structural = (c and c.name) ~= last_name or (c and c.level) ~= last_level
    or table.concat(data.queue, ",") ~= last_queue
  local moved = c and last_progress and math.abs(c.progress - last_progress) >= PROGRESS_STEP
  if structural or moved or (force_send and c and c.progress ~= last_progress) then
    remember(data)
    transport.update_if_changed("research", data)
  end
end

function research.on_finished(event)
  local tech = event.research
  if config.enabled("research") and tech then
    transport.send({ type = "event", event = "research_finished", data = { name = tech.name, level = tech.level } })
  end
  research.refresh(true)
end

return research
