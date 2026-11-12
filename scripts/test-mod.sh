#!/usr/bin/env bash
# Run the pure-Lua mod tests (mod/tests/*_test.lua); stops at the first failure.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LUA=${LUA:-$(command -v lua || echo /opt/homebrew/bin/lua)}
cd "$ROOT/mod"
for t in tests/*_test.lua; do
  echo "== $t"
  "$LUA" "$t"
done
echo "all mod tests passed"
