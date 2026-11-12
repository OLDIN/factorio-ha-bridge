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

-- Split {category = data} into parts whose encoded size stays within max_bytes.
-- Categories are never cut; one bigger than max_bytes becomes its own part.
-- Returns parts (list of {category = data}) and the names of oversized categories.
-- `warn(name, size)` is optional and called for each oversized category.
function transport.split(categories, max_bytes, encode, warn)
  local names = {}
  for name in pairs(categories) do names[#names + 1] = name end
  table.sort(names)

  local parts, oversized = {}, {}
  local current, current_size = nil, 0
  for _, name in ipairs(names) do
    local size = #encode({ [name] = categories[name] })
    if size > max_bytes then
      oversized[#oversized + 1] = name
      if warn then warn(name, size) end
      if current then parts[#parts + 1] = current end
      current, current_size = nil, 0
      parts[#parts + 1] = { [name] = categories[name] }
    else
      if current and current_size + size > max_bytes then
        parts[#parts + 1] = current
        current, current_size = nil, 0
      end
      current = current or {}
      current[name] = categories[name]
      current_size = current_size + size
    end
  end
  if current then parts[#parts + 1] = current end
  return parts, oversized
end

function transport.send(msg)
  msg.v = PROTOCOL
  msg.tick = game.tick
  local port = settings.global["factorio-ha-udp-port"].value
  -- for_player = 0: only the server sends, never the clients.
  local ok, err = pcall(helpers.send_udp, port, helpers.table_to_json(msg), 0)
  if not ok and not send_failure_logged then
    send_failure_logged = true
    log("factorio-ha: UDP send failed (is the server started with --enable-lua-udp?): " .. tostring(err))
  end
end

-- Full snapshot, split into parts that all carry the same tick. An empty
-- table still sends one part (it clears categories that were turned off).
function transport.send_snapshot(data_by_category)
  last_sent = {}
  for name, data in pairs(data_by_category) do
    last_sent[name] = helpers.table_to_json(data)
  end
  local parts = transport.split(data_by_category, transport.MAX_DATAGRAM - ENVELOPE_RESERVE,
    helpers.table_to_json,
    function(name, size)
      log("factorio-ha: category '" .. name .. "' is " .. size .. " bytes, over the datagram limit; sent alone")
    end)
  if #parts == 0 then parts[1] = {} end
  for i, part in ipairs(parts) do
    transport.send({ type = "snapshot", part = i, parts = #parts, data = part })
  end
end

-- Sends an `update` only when the category's JSON differs from the last one sent.
function transport.update_if_changed(category, data)
  local json = helpers.table_to_json(data)
  if last_sent[category] == json then return false end
  last_sent[category] = json
  transport.send({ type = "update", data = { [category] = data } })
  return true
end

return transport
