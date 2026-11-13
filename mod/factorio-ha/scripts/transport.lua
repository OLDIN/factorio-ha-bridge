-- UDP transport: envelope, multi-part snapshots, change-only updates.
-- split() is pure (no game API) so it can be tested with plain Lua.

local transport = {}

local PROTOCOL = 1
-- macOS caps a UDP datagram at 9216 bytes; stay well below (Task 1 measurements).
transport.MAX_DATAGRAM = 8000
-- Room for the envelope ({"v":1,"type":"snapshot","tick":...,"part":..,"parts":..,"data":...}).
local ENVELOPE_RESERVE = 200

-- Session-local on purpose: only decides what the server sends over UDP (server-only),
-- so it cannot desync multiplayer and needs no `storage`.
local last_sent = {}
local send_failure_logged = false

-- Groups category names into parts whose summed sizes stay within max_bytes.
-- `sizes` is {category = encoded size of {"category":...}}; categories are never cut, and one
-- bigger than max_bytes becomes its own part. Returns parts (lists of names, sorted) and the
-- names of oversized categories. `warn(name, size)` is optional and called for each oversized one.
function transport.split(sizes, max_bytes, warn)
  local names = {}
  for name in pairs(sizes) do names[#names + 1] = name end
  table.sort(names)

  local parts, oversized = {}, {}
  local current, current_size = nil, 0
  for _, name in ipairs(names) do
    local size = sizes[name]
    if size > max_bytes then
      oversized[#oversized + 1] = name
      if warn then warn(name, size) end
      if current then parts[#parts + 1] = current end
      current, current_size = nil, 0
      parts[#parts + 1] = { name }
    else
      if current and current_size + size > max_bytes then
        parts[#parts + 1] = current
        current, current_size = nil, 0
      end
      current = current or {}
      current[#current + 1] = name
      current_size = current_size + size
    end
  end
  if current then parts[#parts + 1] = current end
  return parts, oversized
end

-- {"v":1,"type":<kind>,"tick":<tick><extra>,"data":<data_json>} built from strings: the data is
-- JSON already (every category is encoded exactly once), so it is not walked and encoded again.
-- `extra` is "" or more fields with a leading comma.
function transport.envelope(kind, tick, extra, data_json)
  return '{"v":' .. PROTOCOL .. ',"type":"' .. kind .. '","tick":' .. string.format("%d", tick)
    .. extra .. ',"data":' .. data_json .. "}"
end

-- {"a":<json>,"b":<json>} from category names and their encoded data.
function transport.join(names, json_by_name)
  local fields = {}
  for i, name in ipairs(names) do fields[i] = '"' .. name .. '":' .. json_by_name[name] end
  return "{" .. table.concat(fields, ",") .. "}"
end

local function send_json(json)
  local port = settings.global["factorio-ha-udp-port"].value
  -- for_player = 0: only the server sends, never the clients.
  local ok, err = pcall(helpers.send_udp, port, json, 0)
  if not ok and not send_failure_logged then
    send_failure_logged = true
    log("factorio-ha: UDP send failed (is the server started with --enable-lua-udp?): " .. tostring(err))
  end
end

function transport.send(msg)
  msg.v = PROTOCOL
  msg.tick = game.tick
  send_json(helpers.table_to_json(msg))
end

-- Category data is a table, or a string with its JSON already encoded (a module that has just
-- published it hands that over instead of collecting again).
local function encoded(data)
  if type(data) == "string" then return data end
  return helpers.table_to_json(data)
end

-- Full snapshot, split into parts that all carry the same tick. An empty
-- table still sends one part (it clears categories that were turned off).
function transport.send_snapshot(data_by_category)
  last_sent = {}
  local sizes = {}
  for name, data in pairs(data_by_category) do
    local json = encoded(data)
    last_sent[name] = json
    sizes[name] = #name + #json + 5 -- {"name":json}
  end
  local parts = transport.split(sizes, transport.MAX_DATAGRAM - ENVELOPE_RESERVE,
    function(name, size)
      log("factorio-ha: category '" .. name .. "' is " .. size .. " bytes, over the datagram limit; sent alone")
    end)
  if #parts == 0 then parts[1] = {} end
  for i, names in ipairs(parts) do
    send_json(transport.envelope("snapshot", game.tick, ',"part":' .. i .. ',"parts":' .. #parts,
      transport.join(names, last_sent)))
  end
end

-- Sends an `update` only when the category's JSON differs from the last one sent.
-- `data` is a table or its JSON (see send_snapshot).
function transport.update_if_changed(category, data)
  local json = encoded(data)
  if last_sent[category] == json then return false end
  last_sent[category] = json
  send_json(transport.envelope("update", game.tick, "", '{"' .. category .. '":' .. json .. "}"))
  return true
end

return transport
