-- Pure-logic tests for scripts/config.lua with a fake `storage` global.
package.path = "factorio-ha/?.lua;" .. package.path
storage = {}
local config = require("scripts.config")

assert(config.enabled("players") == false)
assert(config.any_enabled() == false)

local ok, changed = config.apply({ v = 1, categories = { players = true } })
assert(ok and changed and config.enabled("players") and config.any_enabled())

ok, changed = config.apply({ v = 1, categories = { players = true } })
assert(ok and not changed, "same config must not be 'changed'")

ok, changed = config.apply({ v = 1, categories = { players = true, planets = true, bogus = true } })
assert(ok and changed and config.enabled("planets") and not config.enabled("bogus"))

ok, changed = config.apply({ v = 1, categories = {} })
assert(ok and changed and not config.any_enabled())

ok, changed = config.apply({ v = 2 })
assert(not ok and not changed)
ok = config.apply("junk")
assert(not ok)

ok, changed = config.apply({ v = 1, categories = { machines = true, drills = true } })
assert(ok and changed and config.enabled("machines") and config.enabled("drills"))
assert(not config.enabled("players"))

-- line rule from HA: "output full" counts as stopped only when asked for
assert(config.line_output_full() == false)
ok, changed = config.apply({ v = 1, categories = { machines = true }, lines = { output_full = true } })
assert(ok and changed and config.line_output_full(), "flag on is a change")
ok, changed = config.apply({ v = 1, categories = { machines = true }, lines = { output_full = true } })
assert(ok and not changed)
ok, changed = config.apply({ v = 1, categories = { machines = true } })
assert(ok and changed and not config.line_output_full(), "a missing flag means off")
ok, changed = config.apply({ v = 1, categories = { machines = true }, lines = { output_full = "yes" } })
assert(ok and not changed and not config.line_output_full(), "only true turns it on")

print("config_test ok")

-- 2c: platforms is a category
do
  local ok2, changed2 = config.apply({ v = 1, categories = { platforms = true } })
  assert(ok2 and changed2 and config.enabled("platforms"))
  print("config platforms ok")
end
