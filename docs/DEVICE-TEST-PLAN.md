# Device test plan (MPC Live III Gen2, MPC 3.10.1.8, Launchpad Mini MK3)

Run after installing (docs/INSTALL.md). Record every deviation in docs/LAYOUT.md §8
and docs/REVIEW-style notes; fix the script, re-run the host suite, rebuild.

## 0. Boot / loader

| # | Step | Expect |
| --- | --- | --- |
| 0.1 | Plug the Mini in, restart MPC (`systemctl restart acvs`) | journal: `LaunchpadMiniMK3: loaded` |
| 0.2 | Journal after ~1 s | `prior mode 0x00`, `prior layout 0x0X`, `programmer mode`, `firmware: x.y.z.w` |
| 0.3 | Surface state | grid shows the clip window (no text scroll anymore) |
| 0.4 | Top row | ▲▼◀▶ white, Session white, Drums available, Keys available, User available, logo dim |

If 0.1 shows nothing: the `.ini` port name is wrong (LAYOUT §8.2) — check
`journalctl -u acvs | grep -i mini` for the JUCE enumeration and fix `input=`/`output=`.

## 1. Programmer-mode wire facts (the critical unknowns)

| # | Step | Expect |
| --- | --- | --- |
| 1.1 | Press a grid pad | clip launches; **if nothing happens**, check the journal for `unmapped` lines (probe mode is gone with the shift layer) |
| 1.2 | Press ▲ (top row) | journal `MoveUp(1)`; **if unmapped CC 91**, the edge buttons send notes not CCs (LAYOUT §8.1) — swap the dispatch keys |
| 1.3 | Press each edge button in probe mode | journal lines `PROBE cc=<n>` for CC 19-99; LEDs light white |
| 1.4 | Press a scene button (89..29) | `TriggerRow(0..6)`; scene LEDs reflect row states |
| 1.5 | Mixer key (19) | mixer opens (grid = track view, menu key white) |

## 2. Mixer menu

| # | Step | Expect |
| --- | --- | --- |
| 2.0 | Row identity at a glance | record row idles DARK BLUE, stop grey, mute dark orange, solo dark yellow, arm dark red, select = track colour |
| 2.2 | Record row (row 2) on an idle track | selects + arms + `TriggerClip` on the first empty slot; **clip recording starts** (LAYOUT §8.5) — if not, note what the MPC does instead |
| 2.3 | While recording | record-row pad bright red; press again stops (`StopClipsOnTrack`) |
| 2.4 | Mute/solo rows | orange/yellow LEDs follow the track state live (listener-driven) |
| 2.5 | Select row | white on the current track; other columns in their track colour; columns follow the window (◀▶ while the mixer is open moves the window) |
| 2.6 | Transport strip | play STARTS (no toggle, green while playing); stop stops (again = locate zero, `Locate zero` in the journal); record delegates to the MPC REC state machine |
| 2.7 | Tap tempo pad x4 | `tap tempo: NNN BPM` lines; BPM follows |
| 2.8 | Duplicate/clear | single-shot: arming closes the mixer, menu key red; origin+target / target pad consumes; 19 cancels |

## 3. Pages

| # | Step | Expect |
| --- | --- | --- |
| 3.1 | Volume/pan/send pads | full-grid fader bars; ▲▼ nudge (±1 row / ±1/8); ◀▶ cycle sends 1-4 while the sends menu is open |
| 3.2 | Tempo page | BPM digits on the grid; ▲▼ ±1 with hold-to-accelerate |
| 3.3 | Swing page | swing % digits, 50-75 |
| 3.4 | User (CC 98) | Q-Link page; ▲▼ flip pages |
| 3.5 | Exit paths | 19 closes any page then reopens the mixer; 95 = clip grid |

## 4. Modes

| # | Step | Expect |
| --- | --- | --- |
| 4.1 | Drums (96) on a drum track | pads mode: bottom-left 4x4 quadrant mirrors MPC pad colours; grid pads inert; scene column still works |
| 4.2 | Drums pressed again | flips to the 64-pad grid (all 64 virtual pads bound; drums LED cyan); third press exits |
| 4.3 | Drums on a melodic track | enters the 64-pad grid directly (`track type ... -> pads64` in the journal); second press = quadrant |
| 4.4 | Keys (97) on a DRUM track | quadrant plays the kit plainly — NO Pad Perform (no chord transform, no dialog, no screen change); grid pads don't launch clips; journal `keys page: kit play (drum track)`; repeat leaves (bindings restored, kit triggers normally from the MPC pads) |
| 4.5 | Keys (97) on a MELODIC track | quadrant plays Pad Perform chords; journal `keys page: pad perform chords (...)` then `pad perform dialog closed`; NO dialog stays open; session/drums/user buttons stay live WHILE the page is open; repeat leaves (`pad perform off`, `pad perform dialog closed`, Main screen) |
| 4.6 | Keys round trip after-effects | after leaving: clip grid works (pad press = TriggerClip), MPC's own pads trigger the kit normally, no popup on screen |
| 4.7 | Logo position | not a button: pressing it sends nothing (no CC 99 arrives) |
| 4.8 | Scene buttons | plain TriggerRow only (0-6) |

### 4b. MIDI guard (the double-feed fix)

| # | Step | Expected |
|---|------|----------|
| 4b.1 | Fresh project, drum tracks (input defaults to All) | journal within ~2 s: `midi guard: track [n] input All -> none` (once per track, then silent) |
| 4b.2 | Press grid pads in SESSION mode | clips launch; NO drum sounds from other tracks (the original bug: pads double-fed every All-input track) |
| 4b.3 | Add a NEW track | guarded within 2 s (journal line for the new index) |
| 4b.4 | Point a track's input at a specific port by hand (MPC UI) | the guard NEVER touches it again (no journal line for that track); the setting survives |

### 4c. Q-Link page (CC 98 / mixer Q-Link pad)

| # | Step | Expected |
|---|------|----------|
| 4c.1 | Enter on a fresh project (factory qlink pages) | journal `qlink page (N assigned)` — only safe targets; the factory globals (CURRENT TRACK, SEQUENCE LENGTH, REC ARM, PLAYHEAD, TIME DIVISION, SEQUENCE TEMPO, SWING) are DARK columns with inert pads |
| 4c.2 | Press pads in a blocked column | nothing happens — no track switches, no sequence-length/tempo changes |
| 4c.3 | Assign a real parameter in the MPC's Q-Link edit mode (filter/level) | its column lights and drives from the grid |
| 4c.4 | Up/down arrows | flip Q-Link page 1 <-> 2 (journal `qlink page 2`); press User again to leave |

## 5. Teardown

| # | Step | Expect |
| --- | --- | --- |
| 5.1 | Remove the script / unload | journal `restored live mode`, `unloaded`; surface dark |
| 5.2 | Device after unload | back in Live mode, prior layout (Drums/Keys/User as before); Session button responds normally (Setup entry works again) |
| 5.3 | Press a pad on the standalone device | stock behaviour (no stuck programmer mode) |
