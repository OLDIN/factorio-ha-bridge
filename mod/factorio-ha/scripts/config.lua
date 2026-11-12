-- Category configuration delivered by the relay (stored in `storage`, synced for all peers).

local config = {}

config.CATEGORIES = { "players", "planets", "defense", "evolution", "research" }

local function stored()
  return (storage.config and storage.config.categories) or {}
end

function config.enabled(name)
  return stored()[name] == true
end

function config.any_enabled()
  for _, on in pairs(stored()) do
    if on then return true end
  end
  return false
end

function config.init()
  storage.config = storage.config or { categories = {} }
end

-- Apply a parsed {v=1, categories={name=bool}}. Returns ok, changed.
function config.apply(parsed)
  if type(parsed) ~= "table" or parsed.v ~= 1 then return false, false end
  local wanted = type(parsed.categories) == "table" and parsed.categories or {}
  local old = stored()
  local new, changed = {}, false
  for _, name in ipairs(config.CATEGORIES) do
    new[name] = wanted[name] == true
    if new[name] ~= (old[name] == true) then changed = true end
  end
  storage.config = { categories = new }
  return true, changed
end

return config
