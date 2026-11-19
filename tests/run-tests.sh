#!/bin/sh
# Run the host-side tests: Lua syntax, selene lint (if present), mock harness.
set -eu
cd "$(dirname "$0")/.."

echo "== luac -p =="
luac5.4 -p script/LaunchpadMiniMK3.lua
echo "luac: OK"

echo "== check-ini (loader regression gate) =="
tools/check-ini.sh script/LaunchpadMiniMK3.ini.in template

echo "== generated manual =="
tools/gen-manual.sh --check

SELENE="${SELENE:-$(command -v selene || true)}"
if [ -n "$SELENE" ] && [ -x "$SELENE" ]; then
  echo "== selene =="
  "$SELENE" script/LaunchpadMiniMK3.lua || true
fi

for t in tests/test-*.lua; do
  echo "== $t =="
  lua5.4 "$t"
done

# The shipped artifact is the minified Lua: the whole suite must pass on it too.
echo "== minified artifact (the deployed form) =="
MIN_ARTIFACT="$(mktemp)"
tools/minify-lua.sh script/LaunchpadMiniMK3.lua > "$MIN_ARTIFACT"
luac5.4 -p "$MIN_ARTIFACT"
for t in tests/test-*.lua; do
  LPMINI_LUA="$MIN_ARTIFACT" lua5.4 "$t" >/dev/null
done
rm -f "$MIN_ARTIFACT"
echo "minified artifact: OK"

echo "ALL TESTS PASS"
