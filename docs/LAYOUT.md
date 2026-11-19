# Launchpad Mini MK3 Layout & Protocol (Programmer Mode)

Sources: the official Novation documents (user-supplied links, 2026-11):

- Programmer's Reference Manual: `fael-downloads-prod.focusrite.com/.../Launchpad Mini - Programmers Reference Manual.pdf` (v1.0, 23 pp)
- User Guide v2: `fael-downloads-prod.focusrite.com/.../launchpad_mini_user_guide_v2-pdf-en.pdf`

Cross-checked against the community reference implementation
`obeezzy/lpminimk3` (whose layout tables mirror the official diagrams).

## 1. Interfaces

Two USB MIDI interfaces (programmer's reference p.6):

- **LPMiniMK3 DAW In/Out** — Session-mode surface for DAWs. Not used by this script.
- **LPMiniMK3 MIDI In/Out** — Custom-mode MIDI, external lighting, **Programmer mode**. This is the port the `.ini` binds (`input=`/`output=`).

Device-verified (3.10.1.12): the JUCE port name is `Launchpad Mini MK3 LPMiniMK3 MIDI In`
(full `/proc/asound/seq/clients` name; the loader needs the ` In` suffix — without it the
loader silently skips the script). The `.ini` binds this one port for both directions.

## 2. SysEx header

All device sysex: `F0 00 20 29 02 0D ... F7` (product byte **0x0D**; the Pro MK3 uses 0x0E).
The script passes payloads without F0/F7 to `SendMIDISysex`.

## 3. Programmer-mode layout (reference p.10 + p.13 examples)

- **Grid 8x8**: notes 11-88, bottom-left first — `note = 10*(rowFromBottom) + col + 11`.
  Identical to the Launchpad Pro MK3 programmer-mode grid (reference example: "lower left
  pad = note 11 = 0Bh", "upper left pad = note 81 = 51h").
- **Top row (round buttons, left to right)**: CC 91-98 = ▲ ▼ ◀ ▶ Session Drums Keys User
  (decimal 91-98 = 5Bh-62h in the diagram; OCR of the official diagram shows the CC labels).
  **Device-verified: the Novation logo (the 99th position in the layout tables) is NOT a
  button — no message arrives for it.** It exists in the numbering for LED purposes only.
- **Right column (round buttons, top to bottom)**: CC 89, 79, 69, 59, 49, 39, 29, 19 =
  scene launch 1-7 + the 8th position (Stop/Solo/Mute in Ableton's mapping) = this
  script's MIXER menu key.
- "All buttons and pads accept either Note or Control Change messages. The indicated type
  [CC for the edge buttons, Note for the pads] is which is sent by the device on the MIDI
  interface when the corresponding button or pad is pressed." — the script registers
  notes 11-88 + CC {19,29,...,89, 91..99} with `AddNoteToScript`/`AddCCToScript`.
- Pads are **not velocity/pressure sensitive** (fixed press velocity, no aftertouch);
  Note Off is Note On with velocity 0.

## 4. LED protocol (reference pp.9-14)

- Channels as MIDI events: ch1 (90h/B0h) static palette, ch2 (91h/B1h) flashing,
  ch3 (92h/B2h) pulsing; palette index in velocity/value. The script does not use these.
- **LED sysex**: `F0 00 20 29 02 0D 03 <colourspec>... F7`, colourspec =
  `<type> <led> <data>`; types 0 = static palette (1 byte), 1 = flash (2 bytes),
  2 = pulse (1 byte), 3 = RGB (3 bytes 0-127). **Up to 81 colourspecs per message**
  (= the whole surface: 64 pads + 9 top + 8 right). LED indices = the programmer-mode
  numbers above, regardless of layout. The script flushes in <=81-spec chunks.
- Blinking is timer-driven (2 Hz / 1 Hz repaints), not the flash/pulse channels —
  same approach as the Pro script (RGB pads have no blink channel in the sysex we use).

## 5. Mode / layout control (reference pp.7-8)

- `0E <mode>`: 0 = Live mode, 1 = Programmer mode (dedicated switch; disables the
  device's Setup entry while programmer mode is active — return to Live to restore).
- `00 <layout>`: 00 Session (DAW mode only), 04-06 Custom 1-3, 0D DAW faders, 7F Programmer.
- `0A <internal> <external>`: LED feedback config (internal = press-lighting).
- Readbacks (`0E` / `00` / `0A` alone) reply with the current state; the script
  captures them on load and restores on unload.
- Entering Live mode (`0E 00`) lands on Session/Custom 2, so the script re-issues
  `00 <priorLayout>` after it.

## 6. Extra surface control (available, partly unused)

- Text scrolling (`07h`): non-destructive overlay; available but unused.
- Brightness (`08h`), LED sleep (`09h`): unused.
- DAW mode (`10h`), DAW state clear (`12h`), DAW faders (`01h`), session button colour
  (`14h`): unused (programmer mode only).

## 7. Device inquiry

Reply: `F0 7E 00 06 02 00 20 29 13 01 00 00 <4 version bytes> F7` (family 0x13,
model 0x01, app). Parsed for a log line only.

## 8. Open questions (device observations 2026-11-19, MPC 3.10.1.12, Mini fw 0.4.6.7)

1. ~~The exact JUCE port name~~ — RESOLVED: `Launchpad Mini MK3 LPMiniMK3 MIDI In` (§1).
2. Do the edge buttons send **CC** on press (per the diagram's indicated type) or notes?
   The script maps CC 19-99; if a unit sends notes instead, probe mode (Shift+Drums)
   will show it immediately and only the dispatch tables need a key change.
   (Surface responses and `programmer mode` entry were observed; per-control probe
   still pending a session with the device in hand.)
3. Fixed pad velocity value (any value > 0 works with this script).
4. Whether the default internal LED feedback is on in Programmer mode (the script
   forces internal off / external on at entry and restores the readback state on unload).
5. Whether triggering an empty slot on an armed track starts a clip recording
   (the mixer's record row relies on it; falls back gracefully — logs `track record`).
6. Mode/layout readback replies were not observed before the Programmer-mode switch
   (none arrived, or they were eaten by the host sysex-string limitation below), so
   unload restores the Live + Custom 1 defaults instead of the exact prior layout.
7. **Host limitation**: the MPC host wraps each incoming sysex in a Lua string literal;
   a payload containing 0x27 (`'`), 0x5C or a newline byte produces a sol2 syntax error
   before `HandleMIDISysex` runs (~1/min with the Mini attached). Harmless noise; the
   replies the script needs (device inquiry, `0D 0E/00/0A` readbacks) contain none of
   those bytes and parse fine.
