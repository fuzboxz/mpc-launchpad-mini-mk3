# Contributing / development notes

This file holds the local development and testing details that are **not** part of the
deliverable. The main docs describe the controller script; this file describes how to
reproduce the work on a development machine.

## Port lineage

Ported from [mpc-launchpad-pro-mk3](https://github.com/fuzboxz/mpc-launchpad-pro-mk3)
(commit pinned as the submodule in open-mpc/mpc-controllers at port time). The MPC-side
engine is shared; the device side and the surface mapping are new (docs/MAPPING.md).

## Reference checkouts (not committed)

- `mpc-controllers` docs + examples (ForceLink, the Pro repo): `<mpc-controllers-checkout>`
- Novation Launchpad Mini [MK3] Programmer's Reference Manual + User Guide v2
  (user-supplied focusrite.com links, kept out of the repo — see docs/LAYOUT.md)
- Community cross-check: `obeezzy/lpminimk3` (Python; mirrors the official diagrams)
- Extracted MPC 3.10.0.49 / 3.10.1 binaries and the shipped MPK mini IV pairs: `<kit-dir>`

## Signing

The checksum is `sha256(lua_bytes || 36-char salt)`. The salt is XOR-obfuscated in the
MPC binary; read it from your own copy, never publish it.

- `MPC_BIN=<kit-dir>/MPC-3.10.0.49-gen2 ./script/build.sh`
  (the owner's extracted 3.10.0.49 Gen2 binary; its salt is accepted unchanged by
  3.10.1.8 and 3.10.1.12 — device-verified 2026-11-19 against the XL3 load and the
  .12 stock mpkMiniMkIV checksum).
- `tools/verify_salt.py` checks the salt against the shipped MPK mini IV pairs under
  `<kit-dir>` (override with `XZT_DIR`).
- `tools/test-sign.sh` runs the signer tests; set `XZT_DIR` to your extracted kit dir.

## Tests

- `./tests/run-tests.sh` — `luac5.4 -p`, the ini regression gate (`tools/check-ini.sh`),
  `selene` (if present), the 14 mock tests, and the same suite against the minified
  artifact (`LPMINI_LUA=<artifact>`).
- `tools/gen-manual.sh` regenerates `docs/MANUAL.md` from the script's `ACTIONS` /
  `MIXER` tables; `tools/gen-manual.sh --check` (run by `tests/run-tests.sh`) fails when
  the committed manual is stale. Edit the script, then regenerate — never edit the manual.
- **Enable the pre-commit gate once per clone:**
  `git config core.hooksPath .githooks` — it blocks `.ini` regressions that the
  MPC loader refuses silently (no log, no load) and lua syntax errors. The same
  gate also runs inside `script/build.sh` and `tests/run-tests.sh`.

## Device

- SSH: `ssh root@<device-ip>` (passwordless key on this machine).
- Device path: `<user-root>/MPC Documents/Devices/LaunchpadMiniMK3/`.
- Restart MPC: `systemctl restart acvs` (closes the open project).
- Journal: `journalctl -u acvs -o cat --no-pager | grep LaunchpadMiniMK3`.

## Device .ini constraints (MPC 3.10.1)

- `scriptVersion` must be a single-dot `MAJOR.MINOR` value (`1.0`, like Akai's reference
  script); semver or unknown minors are silently skipped. Device-verified on the Pro.
- The loader matches `input=`/`output=` against connected port names and runs the
  script's chunk only when a port matches; keep one exact JUCE port name per line
  (`Launchpad Mini MK3 LPMiniMK3 MIDI` — verify on hardware, docs/LAYOUT.md §8.2).
