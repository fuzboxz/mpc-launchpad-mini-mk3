#!/bin/sh
# make-release.sh — build the artifacts and package the release zip.
#
# The zip is the release artifact. It contains the signed .ini + minified .lua
# (the two files that go into MPC Documents/Devices/LaunchpadMiniMK3/), the
# generated manual, the install guide and the README.
#
# Usage: MPC_BIN=/path/to/MPC tools/make-release.sh 0.1.0
set -eu
cd "$(dirname "$0")/.."
: "${MPC_BIN:?set MPC_BIN to your own MPC binary (see CONTRIBUTING.md)}"
version="${1:?usage: tools/make-release.sh <version, e.g. 0.1.0>}"

./script/build.sh

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
pkg="mpc-launchpad-mini-mk3"
mkdir -p "$stage/$pkg"
cp build/LaunchpadMiniMK3.ini build/LaunchpadMiniMK3.lua "$stage/$pkg/"
cp docs/MANUAL.md docs/INSTALL.md README.md "$stage/$pkg/"

out="$PWD/mpc-launchpad-mini-mk3-v$version.zip"
rm -f "$out"
(cd "$stage" && python3 -m zipfile -c "$out" "$pkg")

echo "release artifact: $out"
python3 -m zipfile -l "$out"
