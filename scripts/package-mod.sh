#!/usr/bin/env bash
# Build dist/factorio-ha_<version>.zip with the top folder factorio-ha_<version>/.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/mod/factorio-ha"
VERSION=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$SRC/info.json")
NAME="factorio-ha_$VERSION"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$ROOT/dist" "$STAGE/$NAME"
cp -R "$SRC/." "$STAGE/$NAME/"
rm -f "$ROOT/dist/$NAME.zip"
(cd "$STAGE" && zip -qr -X "$ROOT/dist/$NAME.zip" "$NAME" -x '*.DS_Store')
echo "$ROOT/dist/$NAME.zip"
