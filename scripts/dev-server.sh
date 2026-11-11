#!/usr/bin/env bash
# Local headless Factorio server for developing the factorio-ha mod.
# Vanilla (base only) + factorio-ha, separate write-data dir under dev/ so it
# never touches your normal game. RCON on 127.0.0.1:27015 (password "dev"),
# Lua UDP enabled on 34198 (the mod sends to 127.0.0.1:34199).
#
#   scripts/dev-server.sh               # auto_pause off (game keeps running)
#   AUTO_PAUSE=true scripts/dev-server.sh
#   FACTORIO_BIN=/path/to/factorio scripts/dev-server.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEV="$ROOT/dev"
AUTO_PAUSE=${AUTO_PAUSE:-false}
if [ -z "${FACTORIO_BIN:-}" ]; then
  for c in "$HOME/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio" \
           "/Applications/factorio.app/Contents/MacOS/factorio"; do
    [ -x "$c" ] && FACTORIO_BIN=$c && break
  done
fi
[ -x "${FACTORIO_BIN:-}" ] || { echo "Factorio binary not found; set FACTORIO_BIN"; exit 1; }

mkdir -p "$DEV/write" "$DEV/mods" "$DEV/saves"
cat > "$DEV/config.ini" <<INI
[path]
read-data=__PATH__system-read-data__
write-data=$DEV/write
INI
ln -sfn "$ROOT/mod/factorio-ha" "$DEV/mods/factorio-ha"
cat > "$DEV/mods/mod-list.json" <<'JSON'
{"mods":[{"name":"base","enabled":true},{"name":"elevated-rails","enabled":false},
{"name":"quality","enabled":false},{"name":"space-age","enabled":false},
{"name":"factorio-ha","enabled":true}]}
JSON
cat > "$DEV/server-settings.json" <<JSON
{"name":"factorio-ha dev","description":"local dev server","tags":[],
 "visibility":{"public":false,"lan":false},"require_user_verification":false,
 "max_players":0,"game_password":"","allow_commands":"admins-only",
 "autosave_interval":10,"autosave_slots":2,"auto_pause":$AUTO_PAUSE,
 "only_admins_can_pause_the_game":true}
JSON

COMMON=(-c "$DEV/config.ini" --mod-directory "$DEV/mods")
if [ ! -f "$DEV/saves/dev.zip" ]; then
  "$FACTORIO_BIN" "${COMMON[@]}" --create "$DEV/saves/dev.zip"
fi
exec "$FACTORIO_BIN" "${COMMON[@]}" --start-server "$DEV/saves/dev.zip" \
  --server-settings "$DEV/server-settings.json" \
  --enable-lua-udp=34198 --rcon-port 27015 --rcon-password dev
