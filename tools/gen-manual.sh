#!/bin/sh
# Regenerate docs/MANUAL.md from the controller script. Fails when the committed
# manual is stale so the reference can never drift from the code.
set -eu
cd "$(dirname "$0")/.."
if [ "${1:-}" = "--check" ]; then
	tmp="$(mktemp)"
	lua5.4 tools/gen-manual.lua script/LaunchpadMiniMK3.lua "$tmp" >/dev/null
	if ! diff -q docs/MANUAL.md "$tmp" >/dev/null 2>&1; then
		echo "gen-manual: docs/MANUAL.md is stale; run tools/gen-manual.sh" >&2
		rm -f "$tmp"
		exit 1
	fi
	rm -f "$tmp"
	echo "gen-manual: docs/MANUAL.md is up to date"
	exit 0
fi
lua5.4 tools/gen-manual.lua script/LaunchpadMiniMK3.lua docs/MANUAL.md
