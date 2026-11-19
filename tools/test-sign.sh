#!/usr/bin/env bash
# Self-test for the MPC script signer (tools/sign_script.py, tools/verify_salt.py).
#
# Requires the owner's local artifacts (never committed):
#   $XZT_DIR/MPC-3.10.0.49          owner's 3.10.0.49 Gen2 binary (salt source)
#   $XZT_DIR/mpk3100.{lua,ini}      shipped 3.10.0.49 mpkMiniMkIV pair
#   $XZT_DIR/mpkMiniMkIV.{lua,ini}  shipped 3.10.1.8 mpkMiniMkIV pair
# Set XZT_DIR to your extracted kit dir (see CONTRIBUTING.md); MPC_BIN overrides
# the binary path.
#
# The salt itself is never printed or written to disk by these tools.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${XZT_DIR:?set XZT_DIR to your extracted kit dir (see CONTRIBUTING.md)}"
MPC_BIN="${MPC_BIN:-$XZT_DIR/MPC-3.10.0.49}"

fail() {
    echo "test-sign: FAIL: $*" >&2
    exit 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ -f "$MPC_BIN" ] || fail "MPC binary not found: $MPC_BIN (set MPC_BIN or XZT_DIR)"

echo "== 1/2: verify_salt.py against shipped checksum pairs =="
python3 "$SCRIPT_DIR/verify_salt.py" "$MPC_BIN"

echo "== 2/2: sign_script.py signs a tiny test .lua and rewrites the .ini =="
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/tiny.lua" <<'EOF'
-- signer self-test payload (not a real controller script)
return { onLoad = function() end, onMidi = function() end }
EOF

cat > "$tmpdir/tiny.ini" <<'EOF'
[info]
device=Signer Self Test
manufacturer=Test
script=tiny.lua
scriptVersion=1.0
EOF

# Sign without an .ini first: the tool must print just the digest.
digest="$(python3 "$SCRIPT_DIR/sign_script.py" "$MPC_BIN" "$tmpdir/tiny.lua")"
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "digest not printed as 64 hex chars"

# Sign again with the .ini: checksum= must be appended and match the digest.
python3 "$SCRIPT_DIR/sign_script.py" "$MPC_BIN" "$tmpdir/tiny.lua" "$tmpdir/tiny.ini" >/dev/null
grep -qx "checksum=$digest" "$tmpdir/tiny.ini" || {
    cat "$tmpdir/tiny.ini" >&2
    fail "checksum= line missing or wrong after first .ini sign"
}
[ "$(grep -c '^checksum=' "$tmpdir/tiny.ini")" -eq 1 ] || fail "duplicate checksum= lines"

# Rewrite path: a stale checksum must be replaced, not duplicated or kept.
sed -i "s/^checksum=.*/checksum=0000000000000000000000000000000000000000000000000000000000000000/" "$tmpdir/tiny.ini"
digest2="$(python3 "$SCRIPT_DIR/sign_script.py" "$MPC_BIN" "$tmpdir/tiny.lua" "$tmpdir/tiny.ini")"
grep -qx "checksum=$digest2" "$tmpdir/tiny.ini" || fail "stale checksum= line not rewritten"
grep -q "^checksum=0\{64\}$" "$tmpdir/tiny.ini" && fail "stale checksum still present"

echo "test-sign: PASS"
