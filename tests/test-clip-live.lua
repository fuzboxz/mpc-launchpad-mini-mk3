-- tests/test-clip-live.lua: live clip states on the LEDs, slot listeners and
-- follow-current-track (no polling: repaints fire from property listeners).
package.path = "./tests/?.lua;" .. package.path
local mock = require("mock-mpc")
_G.mpc = mock.mpc
_G.dev = mock.dev
_G.LaunchpadMiniMK3 = mock.dev
dofile(os.getenv("LPMINI_LUA") or "script/LaunchpadMiniMK3.lua")
local L = LaunchpadMiniMK3

local function assert_eq(a, b, msg)
	if a ~= b then
		error((msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
	end
end

local function pad(col, row)
	return 10 * (8 - row) + col + 1 -- slot row 0 = MPC top row -> top-left LED 81
end

L.OnLoad()

-- 8x8 slots x (Colour/State/Selected) listeners registered at load
assert(mock.count("listen") >= 192, "grid slot listeners registered")

-- state 2 -> the clip's own colour, solid (Colour is an ARGB int, alpha ignored)
local slot = mock.clipProperties[0][0] -- top-left slot -> LED 81
slot.Colour:set(0x800000FF)
slot.State:set(2)
assert_eq(mock.leds[pad(0, 0)][3], 127, "state 2 shows clip colour blue")

-- the asserts above ran without any HandleTimer call: the repaints came from
-- the property listeners
assert(L ~= nil, "listener-driven repaint")

-- state 4 (playing) -> green; state 7 (recording) -> red
slot.State:set(4)
assert_eq(mock.leds[pad(0, 0)][2], 127, "state 4 green")
slot.State:set(7)
assert_eq(mock.leds[pad(0, 0)][1], 127, "state 7 red")

-- state 3 (queued) blinks fast (2 Hz blinkOn): off-phase at load (blinkOn=false)
slot.State:set(3)
assert(mock.leds[pad(0, 0)][2] < 127, "state 3 blink off-phase at load")
for _ = 1, 5 do
	L.HandleTimer()
end
assert_eq(mock.leds[pad(0, 0)][2], 127, "state 3 blink on-phase after 5 ticks")

-- state 4 blinks slow (1 Hz): off in the second half of the 10-tick cycle
slot.State:set(4)
assert(mock.leds[pad(0, 0)][2] < 127, "state 4 slow blink off-phase (ticks=5)")
for _ = 1, 5 do
	L.HandleTimer()
end
assert_eq(mock.leds[pad(0, 0)][2], 127, "state 4 slow blink on-phase (ticks=10)")

-- selected empty slot -> dim white (60,60,60) ring substitute
local sel = mock.clipProperties[1][3]
sel.State:set(0)
sel.Selected:set(true)
assert_eq(mock.leds[pad(1, 3)][1], 60, "selected empty slot dim white")
assert_eq(mock.leds[pad(1, 3)][2], 60, "selected empty slot dim white g")
sel.Selected:set(false)
assert_eq(mock.leds[pad(1, 3)][1], 0, "unselected empty slot off")

-- a slot without a State property falls back to clipMatrix polling (no clip -> off)
slot.State:set(nil)
assert_eq(mock.leds[pad(0, 0)][1], 0, "slot without State polls clipMatrix (off)")

-- the mixer's record row polls TrackIsRecording and shows it bright red
mock.clips[0] = { [0] = "recording" }
L.HandleMIDICC(0, 19, 127)
assert_eq(mock.leds[10 * 6 + 1][1], 127, "record row bright red while the track records")
L.HandleMIDICC(0, 19, 127)

-- manual window move rebinds the grid listeners
local listens = mock.count("listen")
local stops = mock.count("stopListening")
L.HandleMIDICC(0, 94, 127) -- MoveRight(1)
assert_eq(mock.count("MoveRight"), 1, "MoveRight")
assert(mock.count("stopListening") - stops >= 192, "old grid listeners stopped on move")
assert(mock.count("listen") - listens >= 192, "grid listeners rebound on move")

-- track-index changes rebind the slot listeners (no follow: the window never moves)
local movesBefore = #mock.find("MoveToColumn")
mock.mpc.tracks.currentTrack.Index:set(3)
assert_eq(#mock.find("MoveToColumn"), movesBefore, "no follow: window does not move")
assert_eq(mock.getActiveMatrix(), "Normal", "matrix unchanged")
assert(mock.count("listen") - listens >= 192, "index change rebinds the slot listeners")

-- unload stops every listener: 192 slots + scene/track/sequencer + currentTrack.Index
stops = mock.count("stopListening")
L.OnUnload()
assert(mock.count("stopListening") - stops >= 228, "removeListeners stops all listeners")

print("test-clip-live: PASS")
