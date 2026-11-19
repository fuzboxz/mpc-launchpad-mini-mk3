#!/bin/sh
# minify-lua.sh — produce the deployable Lua artifact from the readable source.
#
# The MPC loads the whole script at startup; comments and indentation are dead
# weight on the device. This strips:
#   - full-line comments (lines whose first non-space characters are --)
#   - blank lines
#   - leading indentation
#   - trailing whitespace
#
# Safe because the script contains no long strings ([[ ]]): a line that starts
# with -- outside a long string is always a comment. Trailing comments after
# code are kept (they are inside the code line and harmless).
#
# Usage: tools/minify-lua.sh <source.lua> > <artifact.lua>
set -eu
[ $# -eq 1 ] || { echo "usage: $0 <source.lua>" >&2; exit 2; }
[ -f "$1" ] || { echo "minify-lua: no such file: $1" >&2; exit 1; }
sed -E 's/[[:space:]]+$//' "$1" \
    | grep -vE '^[[:space:]]*(--|$)' \
    | sed -E 's/^[[:space:]]+//'
