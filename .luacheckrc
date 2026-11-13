-- luacheck for the mod code (CI: `luacheck mod/factorio-ha`). Factorio runs Lua 5.2.
-- The point is mostly globals: a mod that sets or reads an undeclared global by accident
-- keeps state outside `storage`, which desyncs multiplayer.
std = "lua52"
max_line_length = false

-- Factorio runtime API (control stage) and data stage (settings.lua).
read_globals = {
  "game", "script", "defines", "helpers", "settings", "prototypes", "rcon", "commands",
  "log", "localised_print", "serpent", "table_size", "data", "mods",
}
-- The only global the mod writes into.
globals = { "storage" }
