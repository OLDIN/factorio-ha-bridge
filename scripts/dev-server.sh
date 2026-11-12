#!/usr/bin/env bash
# Local headless Factorio server for developing the factorio-ha mod.
# Vanilla (base only) + factorio-ha, separate write-data dir under dev/ so it
# never touches your normal game. RCON only on 127.0.0.1:27015 (password "dev"),
# Lua UDP enabled on 34198 (the mod sends to 127.0.0.1:34199).
#
#   scripts/dev-server.sh               # auto_pause off (game keeps running)
#   AUTO_PAUSE=true scripts/dev-server.sh
#   FACTORIO_BIN=/path/to/factorio scripts/dev-server.sh
#   SPACE_AGE=true scripts/dev-server.sh   # enable space-age, quality, elevated-rails
#   MODS_FROM=<dir> scripts/dev-server.sh  # also symlink and enable the .zip mods in <dir>
#                                          # (skipping those disabled in <dir>/mod-list.json)
#                                          # (factorio-ha*.zip is skipped; the repo mod is used)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEV="$ROOT/dev"
AUTO_PAUSE=${AUTO_PAUSE:-false}
SPACE_AGE=${SPACE_AGE:-false}
MODS_FROM=${MODS_FROM:-}
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
# Rebuild the mods dir from scratch so toggling the env vars is idempotent.
find "$DEV/mods" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
ln -sfn "$ROOT/mod/factorio-ha" "$DEV/mods/factorio-ha"
MODS_JSON=$(python3 - "$SPACE_AGE" "$MODS_FROM" "$DEV/mods" <<'PY'
import json, os, sys, zipfile
space_age, src, dst = sys.argv[1] == "true", sys.argv[2], sys.argv[3]
extra = []
disabled = set()
if src and os.path.exists(os.path.join(src, "mod-list.json")):
    # honour the user's own enabled/disabled choices (some mods fail on a newer Factorio)
    listed = json.load(open(os.path.join(src, "mod-list.json")))["mods"]
    disabled = {m["name"] for m in listed if not m["enabled"]}
if src:
    for f in sorted(os.listdir(src)):
        if not f.endswith(".zip") or f.startswith("factorio-ha"):
            continue
        z = zipfile.ZipFile(os.path.join(src, f))
        info = min((n for n in z.namelist() if n.endswith("info.json")), key=len)
        name = json.loads(z.read(info))["name"]
        if name in disabled:
            continue
        os.symlink(os.path.join(src, f), os.path.join(dst, f))
        extra.append(name)
mods = [{"name": "base", "enabled": True}]
mods += [{"name": n, "enabled": space_age} for n in ("elevated-rails", "quality", "space-age")]
mods += [{"name": n, "enabled": True} for n in extra + ["factorio-ha"]]
print(json.dumps({"mods": mods}))
PY
)
printf '%s\n' "$MODS_JSON" > "$DEV/mods/mod-list.json"
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
  --bind 127.0.0.1 --enable-lua-udp=34198 \
  --rcon-bind 127.0.0.1:27015 --rcon-password dev
