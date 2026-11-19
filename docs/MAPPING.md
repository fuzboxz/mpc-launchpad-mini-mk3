# Mapping design (Pro MK3 -> Mini MK3)

The Mini has 8 round buttons on top, 8 down the right, and no left/bottom edge rows.
This note records where every Pro function went.

## 0. No shift layer

The Novation logo looked like a ninth top-row button on paper (the community
layout tables list it), but on the real hardware it is not a button: nothing
arrives on CC 99. All shift functionality was removed — every control has
exactly one plain function. Former shift actions (loop, overdub, undo/redo,
quantize, plugin presets, step-seq view, follow toggle, probe mode, page-by-8,
track nav, select-without-launch) are currently unmapped.

## 1. What maps 1:1

- **Grid**: programmer-mode note numbering is identical (11-88, bottom-left first),
  so the whole clip-mode engine (aperture window, live clip states via listeners,
  blink phases, follow mode, pads mode quadrant) ports unchanged.
- **Scenes**: the Pro's right column (CC 89-19) is physically the same column on the
  Mini — but the bottom position (CC 19, where Ableton puts Stop/Solo/Mute) becomes
  the MIXER menu key, so scenes 1-7 map to CC 89..29 and scene 8 has no button.
- ****: the Pro had a dedicated  (CC 90); the Mini's top row is full, so
  **hold the logo (CC 99)** = . A quick logo tap with no shift action logs the
  status line (the Pro's logo function).

## 2. The MIXER menu (the big change)

The Pro spread track functions over two bottom rows (CC 1-8 hold + CC 101-108 track)
and a left column (transport/edit). The Mini replaces all of that with one menu that
owns the whole grid — requested design: **mute, solo, stop, select, record and arm all
exposed at the same time**, one row per function, columns aligned with the clip window:

- row 7 select, row 6 arm, row 5 solo, row 4 mute, row 3 stop clips, row 2 record.
- every row idles in its own tint so the rows identify themselves without labels:
  arm dark red, solo dark yellow, mute dark orange, stop grey, record dark blue
  (record goes dim red armed, bright red while the track records), select = the
  track's colour with white on the current track.
- row 2 (record) is stateful per track: `clipMatrix.TrackIsRecording(col)` → bright red;
  armed-but-idle → dim red. Press = stop that track's recording, or start one
  (select + `SetRecArm(true)` + `TriggerClip` on the first empty slot in the window).
- two fixed strips carry the rest: row 0 pages/utilities, row 1 transport
  (play / record / stop only; undo/redo on Keys/User, loop on
  play, overdub on record).
  The strips are GLOBAL (not per-track), so they light with or without tracks —
  their pads idle in dim tints (volume cyan, pan magenta, send follows its colour,
  tempo white, swing yellow, Q-link blue; transport is state-driven: green playing,
  orange loop/overdub, red record/armed ops, cyan click) so bright always means on.
- exit paths: the menu key (19) toggles; it also closes any open page first (one-key
  surfaces need one obvious exit); Session (95) returns to the clip grid.

### Pro -> Mini function table

| Pro control | Mini home |
| --- | --- |
| grid 11-88 clip window | grid 11-88 (unchanged) |
| right column scenes 89-19 | CC 89..29 (7 scenes; position 19 = menu key) |
| CC 90  | hold logo (CC 99) |
| CC 91/92 window left/right | ◀/▶ (CC 93/94) |
| CC 80/70 window up/down | ▲/▼ (CC 91/92) |
| CC 101-108 track select | mixer row 7 |
| CC 1/2/3 arm/mute/solo (hold + track) | mixer rows 6/4/5 (one press per track) |
| CC 8 stop clip (hold + track) | mixer row 3 |
| CC 4/5/6 volume/pan/sends | mixer row 0 cols 0-2 (◀/▶ cycles sends) |
| CC 7 Q-Link page | User (CC 98) + mixer row 0 col 5 |
| CC 10 record /  overdub | mixer row 1 col 1 (record = overdub) |
| CC 20 play /  loop | mixer row 1 col 0 (play = loop; dedicated Stop on col 2, stop-again = locate zero) |
| CC 40 quantize | scene 4 (CC 59) |
| CC 50/60 duplicate/clear (hold) | dropped from the surface in the simplification pass; the dead engine was removed in the state-machine audit (the dispatch chain must stay single-owner) |
| CC 30  automation filter | dropped (documented; API kept) |
| CC 93 session | Session (CC 95) |
| CC 94 note/pads | Drums (CC 96) |
| CC 95 chord/Pad Perform | Keys (CC 97) |
| CC 97 sequencer | scene 7 (CC 29) |
| CC 98 projects/save | dropped (stub on the Pro too) |
| CC 94/95 presets | scene 5/6 (CC 49/39) |
| CC 6 native tap | dropped (no spare CC; the manual averager remains) |
| logo status /  probe | tap logo / Drums |

## 3. Send cycling

The Pro cycled sends by re-pressing CC 6 while its menu was open. On the Mini the mixer
strip is replaced by the fader bars, so the cycle moved to **◀/▶ while the sends menu is
open** (they are unused there — the window arrows make no sense in a fader menu).

## 4. Page exit

Every grid-owning page (fader menus, tempo, swing, Q-Link, mixer) exits via the menu
key (CC 19) — first press closes the page, next press reopens the mixer — or Session
straight back to the clip grid. ▲/▼ keep their per-page meaning (nudge / BPM / swing /
Q-Link page) and never move the window while a page is open.

## 5. Pads-mode layout cycle and the Keys page

Without a shift layer the 64-pad layout needed its own entry point: **Drums
cycles** — first press enters pads mode with the layout the track type suggests
(drum track: the 4x4 quadrant; melodic: the 64-pad grid), the next press flips
to the other layout, the third leaves. The drums LED is white for the quadrant
and cyan for the 64-pad grid. **Keys** plays the current track's pads from the grid, track-type aware: a
drum track gets the 4x4 quadrant playing the kit PLAINLY (Pad Perform is never
engaged — its chord/scale transform remaps a kit's pads and most go silent,
two device reports), a melodic track gets the quadrant plus the MPC's Pad
Perform page (chords/scales from the 16 pads). Keys again leaves: Pad Perform
toggled off only if we engaged it, pads mode off, MPC back on Main.

The virtual padPerform press opens the Pad Perform DIALOG on 3.10.1 — not just
the mode. While any dialog is open, the popup guard blocks every other button
on the surface (the "session/drum/keys/user all dead" report). The script
closes that dialog right after each padPerform press (`ui.popups.CloseCurrentPopup`,
gated on the popup reading exactly "Pad Perform" — a user's own dialog is never
dismissed), so the chords stay while every button keeps working.

## 6. MIDI routing model and the track-input guard

Device-proven on 3.10.1.12 (readback probe in the journal): the controller
port feeds the MPC's MIDI engine UNCONDITIONALLY — script mappings are
additive dispatch and consume nothing (the leak showed in plain session
mode). Every new drum track defaults to MIDI-triggered input **"All Inputs"
(sentinel 2147483645 = -3), channel omni** — so any channel-0 note from this
controller sounds those tracks in EVERY surface mode. The stock MPK hides the
same exposure by transmitting pads on channel 9, where nothing listens; the
Launchpad cannot change its programmer-mode channel.

The guard (`guardTrackInputs`, 2 s cadence + after the routing probe) moves
tracks on the All default to the "none" input, discovered once by
set-then-readback and cached:

- tracks you point at a specific port (a keyboard, another controller) are
  never touched — only the readback-All default is rewritten;
- newly added tracks are guarded within 2 s;
- the MPC's own hardware pads are unaffected (they trigger internally, not
  through the track MIDI input);
- journal lines: `midi guard: input 'none' sentinel is N` and
  `midi guard: track [i] input All -> none`.

If you WANT a track to play this controller's notes on purpose, set that
track's input to the LPMiniMK3 port by hand — the guard will not touch it.

## 7. Q-Link page: assigned parameters only

The Q-Link implementation is identical to the Pro repo's (ported verbatim:
Twist-driven positions, SetValue fallback, flip learning, fixed column map).
What differs on a fresh project is the MPC's **factory-default Q-Link pages**:
they are global sequencer selectors (SEQUENCE TEMPO, CURRENT TRACK, TIME
DIVISION, TRACK LEVEL, SEQUENCE LENGTH, REC ARM, SWING, PLAYHEAD — read from
the device journal), not fader parameters. Driving `CURRENT TRACK` from a
fader pad selects a track; `SEQUENCE LENGTH` slams to thousands of bars;
`SEQUENCE TEMPO` to 513 BPM. Any implementation that drives those qlinks has
those effects — the Pro behaves the same on the same project; it just usually
meets user-assigned pages.

The Mini therefore treats those seven targets as blocked: their columns stay
dark and their pads are inert. Everything you assign yourself in the MPC's
Q-Link edit mode (program/plugin parameters, TRACK LEVEL) shows and drives
normally — that is the Pro experience, minus the factory-default footguns.
`docs/MANUAL.md` says "Q-Link page"; assign a page of parameters on the MPC
and the grid becomes the fader bank for it.

## 8. State machine invariants (the audit)

Two device reports were the same bug class — an "enter X forgot to close Y"
overlap (a page surviving under pads mode; pads notes staying routed while the
Q-Link page owned the grid, so pads kept PLAYING through it). The 2024 code
audit centralized the state machine and added an exhaustive regression test
(`tests/test-state-matrix.lua`, 9 predecessors x 7 openers) that fails on any
of these invariants:

- **INV1 single owner** — at most one grid-owning state is active (mixer, fader
  menu, tempo, swing, Q-Link, pads mode); `keysPage` only exists with pads
  mode; the routed-notes count matches the layout.
- **INV2 routing** — outside pads mode no note stays routed to (virtual) pads;
  every `AddNoteToMpcPad`/`AddNoteToVirtualPad` is balanced by its removal.
- **INV3 dispatch** — a pad press performs exactly its owner's action, never
  another page's effect (no TriggerClip under a page, no Twist/SetMute/...).
- **INV4 frozen window** — the arrows never move the clip window while a page
  or pads mode owns the grid (the mixer is the documented exception).
- **INV5 escape** — Session always returns to the clean clip state.

The structural rules that make the class hard to reintroduce:

1. Every pads-mode exit funnels through `exitPadsMode()` — the only place that
   returns the note bindings AND closes the Pad Perform page.
2. Every page opener calls `closeGridStates()` (or `closeAllPages()`); there is
   exactly ONE "close everything" list in the file, not seven hand-rolled ones.
3. `HandleMIDINoteOn`'s dispatch is a single-owner if-chain; new branches must
   not be reachable while another page owns the grid.
4. OnLoad/OnUnload reset the complete flag set; `STATE()` (exported on the
   script) snapshots the machine for the tests and for on-device diagnosis.

## 9. Historical: probe mode fix

The Pro's probe mode swallowed every CC including , so it could not be exited
(device quirk inherited from the dispatch order). The Mini keeps the logo live during
probe and lets  actions through: **Drums toggles probe off**.
