#!/bin/sh
# Build the deployable controller script into build/:
#   build/LaunchpadMiniMK3.lua — minified artifact (comments/indentation stripped)
#   build/LaunchpadMiniMK3.ini — signed ini; its checksum covers the artifact
# The checksum is sha256(lua_bytes || salt); the salt is read from the owner's own
# MPC binary at run time. Set MPC_BIN to your own MPC binary (see CONTRIBUTING.md).
set -eu
cd "$(dirname "$0")"
: "${MPC_BIN:?set MPC_BIN to your own MPC binary (see CONTRIBUTING.md)}"
mkdir -p ../build
../tools/minify-lua.sh LaunchpadMiniMK3.lua > ../build/LaunchpadMiniMK3.lua
if command -v luac5.4 >/dev/null 2>&1; then
	luac5.4 -p ../build/LaunchpadMiniMK3.lua
else
	echo "build.sh: warning: luac5.4 not found; skipped the syntax check" >&2
fi
cp LaunchpadMiniMK3.ini.in ../build/LaunchpadMiniMK3.ini
python3 ../tools/sign_script.py "$MPC_BIN" ../build/LaunchpadMiniMK3.lua ../build/LaunchpadMiniMK3.ini >/dev/null
../tools/check-ini.sh LaunchpadMiniMK3.ini.in template
../tools/check-ini.sh ../build/LaunchpadMiniMK3.ini artifact
wc -c ../build/LaunchpadMiniMK3.lua LaunchpadMiniMK3.lua | sed '$d'
grep '^checksum=' ../build/LaunchpadMiniMK3.ini
