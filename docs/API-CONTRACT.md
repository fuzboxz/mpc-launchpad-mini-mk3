# API contract

The MPC-side API surface is identical to the Pro sibling — see
`mpc-launchpad-pro-mk3/docs/API-CONTRACT.md` (upstream:
open-mpc/mpc-controllers examples/mpc-launchpad-pro-mk3). This file records only the
differences that matter for the Mini port:

- The device side changes: sysex header `00 20 29 02 0D` (not `0E`), 81-spec LED cap
  (not 106), mode/layout/feedback readbacks instead of the Pro's layout-select echo,
  and edge CC set {19,29,39,49,59,69,79,89,91..99} (no CC 1-8/10-80/90/101-108).
- New MPC-side calls used beyond the Pro set: `clipMatrix.TrackIsRecording(globalCol)`
  (record-row LEDs) — degrade-guarded like everything else.
- Everything else (aperture, clipProperties listeners, track properties, sequencer,
  controlSurface buttons, mappings.pads routing, qlinks) is used exactly as on the Pro.
