-- Pure-logic tests for scripts/transport.lua (run via scripts/test-mod.sh).
package.path = "factorio-ha/?.lua;" .. package.path
local transport = require("scripts.transport")

-- Tiny encoder: categories here are {text = "..."}; size is what matters.
local function encode(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = '"' .. k .. '":{"text":"' .. t[k].text .. '"}' end
  return "{" .. table.concat(out, ",") .. "}"
end

local function blob(n) return { text = string.rep("x", n) } end

local function names(part)
  local n = {}
  for k in pairs(part) do n[#n + 1] = k end
  table.sort(n)
  return table.concat(n, ",")
end

-- three 3 KB categories, 8 KB limit -> two parts, none cut
do
  local parts = transport.split({ a = blob(3000), b = blob(3000), c = blob(3000) }, 8000, encode)
  assert(#parts == 2, "expected 2 parts, got " .. #parts)
  assert(names(parts[1]) == "a,b", names(parts[1]))
  assert(names(parts[2]) == "c", names(parts[2]))
  assert(parts[1].a.text == blob(3000).text)
end

-- one category over the limit -> its own part, reported as oversized
do
  local warned = {}
  local parts, oversized = transport.split(
    { a = blob(100), big = blob(9000), c = blob(100) }, 8000, encode,
    function(name, size) warned[#warned + 1] = name .. ":" .. size end)
  assert(#parts == 3, "expected 3 parts, got " .. #parts)
  assert(names(parts[2]) == "big", names(parts[2]))
  assert(#oversized == 1 and oversized[1] == "big")
  assert(#warned == 1 and warned[1]:match("^big:%d+$"))
end

-- empty input -> no parts
do
  local parts = transport.split({}, 8000, encode)
  assert(#parts == 0)
end

print("transport_test ok")
