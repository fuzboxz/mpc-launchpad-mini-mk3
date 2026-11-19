# Limitations

Inherited from the MPC 3.10.1 script API (see the Pro repo's docs/LIMITATIONS.md and
open-mpc/mpc-controllers docs/limitations.md for the evidence; the API surface is
identical for both Launchpads):

- No state dump: the script discovers the project through properties and polling;
  a cold start repaints from `clipProperties` + `clipMatrix` queries.
- `SetPosition` on Q-Links does not reach the edit-mode value — Q-Link changes are
  driven with `Twist` (rotation deltas); the flip/binary learning heuristic applies.
- No per-track MIDI input; no editing of non-current tracks.
- The controller port is a normal MIDI input and script mappings consume NOTHING
  (device-proven: notes leak to listening tracks even in session mode, where every
  note is script-bound). New tracks default to input "All" + omni + MIDI-triggered,
  so the script runs a track-input guard: All-default tracks are moved to "none"
  (set-then-readback verified, 2 s cadence, user-set ports never touched). To let a
  track hear the Launchpad on purpose, set its input to the LPMiniMK3 port by hand.
- `scriptVersion` must be `1.0` (single dot, known minor) or the loader silently skips
  the script — enforced by tools/check-ini.sh.
- Project-scoped native calls can abort hard while a dialog owns the UI; every action
  is guarded by the project/popup checks.

Mini-specific:

- Scene 8 has no button (position 19 is the mixer key).
- Pads are not velocity/pressure sensitive (fixed velocity, no aftertouch) — anything
  velocity-based from the Pro is gone by hardware.
- The automation-filter cycle and the projects/save button from the Pro have no
  Mini home (documented in MAPPING.md §2).
- Native (hardware-routed) tap tempo is not possible: no spare CC to re-route; the
  manual averager is the only tap path.
- Not yet device-tested: the wire facts in docs/LAYOUT.md §8 (edge-button CC vs note,
  port name, empty-slot record behaviour) are host-verified only.
