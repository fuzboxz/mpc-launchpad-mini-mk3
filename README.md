# mpc-launchpad-mini-mk3

A Novation Launchpad Mini MK3 controller script for Akai MPC 3.10.1 (Gen2, MPC Live III).

A port of [mpc-launchpad-pro-mk3](https://github.com/fuzboxz/mpc-launchpad-pro-mk3)
(the sibling project for the Launchpad Pro MK3) to the Mini's smaller surface: the same
MPC-side engine (aperture clip window, live clip states, fader/Q-Link pages, pads mode),
rebuilt around the Mini's one edge column, one edge row and — in place of the Pro's four
edge rows — a full-surface **mixer menu** on the grid.

## Status

Host-tested (the full mock suite passes, including the minified artifact); **not yet
device-tested** — see docs/DEVICE-TEST-PLAN.md and the open questions in docs/LAYOUT.md §8.

Implemented: clip mode (launch/select, live LEDs, window scrolling, follow-current-track),
scene launch, the MIXER menu (record/stop/mute/solo/arm/select per track — all exposed at
the same time — plus transport and page strips),
volume/pan/sends fader menus, tempo/swing digit pages, tap tempo, Q-Link page, MPC pads
mode (drum quadrant / 64-pads by track type), Pad Perform, quantize, plugin presets,
undo/redo, loop/overdub, metronome, probe mode, firmware probe, programmer-mode
entry/restore with state capture.

## The surface

```
top row:  91 Up   92 Down   93 Left   94 Right   95 Session
          96 Drums (pads mode; repeat: 16<->64 pads)   97 Keys (play Pad Perform
          from the grid)   98 User (Q-Link page)
grid:     8x8 clip window (pad = launch + select)
right:    89..29 Scenes 1-7      19 MIXER menu (bottom-right corner)
```

The **MIXER menu** (bottom-right corner, where Ableton puts Stop/Solo/Mute) turns the
whole grid into a track view — one column per track, lined up with the clip grid:

```
row 0   volume  pan  send  tempo  swing  qlink  tap  click
row 1   play  record  stop                                              ← transport strip
row 2   RECORD  per track (bright red = recording, dim red = armed;
        press = arm + trigger the first empty slot / stop the recording)
row 3   stop clips    per track
row 4   MUTE          per track (orange)
row 5   SOLO          per track (yellow)
row 6   ARM           per track (red)
row 7   SELECT        per track (track colour, white = current)
```

There is **no Shift** — the Novation logo is not a button on the Mini MK3, so
every control has exactly one plain function.

## Docs

- `docs/MANUAL.md` — the generated control reference (from the script itself)
- `docs/LAYOUT.md` — the Mini's wire protocol, with sources and open questions
- `docs/MAPPING.md` — the design decisions behind the mapping
- `docs/INSTALL.md` — build, sign, install, verify
- `docs/DEVICE-TEST-PLAN.md` — what to verify on hardware
- `docs/LIMITATIONS.md` — what the MPC script API cannot do (inherited from the Pro repo)

## Develop

```sh
./tests/run-tests.sh          # syntax + ini gate + 14 mock tests + minified artifact
tools/gen-manual.sh           # regenerate docs/MANUAL.md after editing ACTIONS/MIXER
git config core.hooksPath .githooks   # once per clone: ini + syntax gate
```

Licence: same as the Pro repo (documentation CC-BY-4.0; code MIT).
