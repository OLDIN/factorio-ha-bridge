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

print("config_test ok")
