-- Pure-logic tests for scripts/transport.lua (run via scripts/test-mod.sh).
package.path = "factorio-ha/?.lua;" .. package.path
local transport = require("scripts.transport")

local function list(names) return table.concat(names, ",") end

-- three 3 KB categories, 8 KB limit -> two parts, none cut
do
  local parts = transport.split({ a = 3000, b = 3000, c = 3000 }, 8000)
  assert(#parts == 2, "expected 2 parts, got " .. #parts)
  assert(list(parts[1]) == "a,b", list(parts[1]))
  assert(list(parts[2]) == "c", list(parts[2]))
end

-- one category over the limit -> its own part, reported as oversized
do
  local warned = {}
  local parts, oversized = transport.split({ a = 100, big = 9000, c = 100 }, 8000,
    function(name, size) warned[#warned + 1] = name .. ":" .. size end)
  assert(#parts == 3, "expected 3 parts, got " .. #parts)
  assert(list(parts[1]) == "a" and list(parts[2]) == "big" and list(parts[3]) == "c")
  assert(#oversized == 1 and oversized[1] == "big")
  assert(#warned == 1 and warned[1] == "big:9000")
end

-- empty input -> no parts
do
  local parts = transport.split({}, 8000)
  assert(#parts == 0)
end

-- the envelope is assembled from JSON that is already encoded
do
  local json = { a = '{"x":1}', b = "[]" }
  assert(transport.join({ "a", "b" }, json) == '{"a":{"x":1},"b":[]}')
  assert(transport.join({}, json) == "{}", "an empty snapshot still carries an object")
  assert(transport.envelope("snapshot", 123456789, ',"part":1,"parts":2', '{"a":{"x":1}}')
    == '{"v":1,"type":"snapshot","tick":123456789,"part":1,"parts":2,"data":{"a":{"x":1}}}')
  assert(transport.envelope("update", 7, "", "{}") == '{"v":1,"type":"update","tick":7,"data":{}}')
end

-- snapshot and update encode each category once and send the same JSON
do
  local encodes, sent = 0, {}
  helpers = {
    table_to_json = function(t) encodes = encodes + 1; return '{"n":' .. t.n .. "}" end,
    send_udp = function(_, json) sent[#sent + 1] = json end,
  }
  settings = { global = { ["factorio-ha-udp-port"] = { value = 1 } } }
  game = { tick = 60 }
  transport.send_snapshot({ a = { n = 1 }, b = '{"n":2}' })
  assert(encodes == 1, "a table is encoded once, a string not at all: " .. encodes)
  assert(#sent == 1 and sent[1] == '{"v":1,"type":"snapshot","tick":60,"part":1,"parts":1,"data":{"a":{"n":1},"b":{"n":2}}}', sent[1])
  assert(transport.update_if_changed("a", { n = 1 }) == false, "unchanged after the snapshot")
  assert(transport.update_if_changed("b", '{"n":3}') == true)
  assert(sent[2] == '{"v":1,"type":"update","tick":60,"data":{"b":{"n":3}}}', sent[2])
  assert(encodes == 2, "update encodes the data once: " .. encodes)
  transport.send_snapshot({})
  assert(sent[3] == '{"v":1,"type":"snapshot","tick":60,"part":1,"parts":1,"data":{}}', sent[3])
end

print("transport_test ok")
