-- tests/test-undo-redo.lua: mixer click/tap, tempo/swing pages, and the degrade
-- paths. (Undo/redo and quantize were shift-only and left the surface with the
-- shift layer — the logo is not a button.)
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

local logs = {}
local realPrint = print
_G.print = function(msg)
	logs[#logs + 1] = tostring(msg)
end
local function lastLog()
	return logs[#logs] or ""
end

local function mixNote(row, col)
	return 10 * (8 - row) + col + 1
end

L.OnLoad()
L.HandleMIDICC(0, 19, 127) -- open the mixer

-- click / metronome toggle (row 0 col 7)
L.HandleMIDINoteOn(0, mixNote(0, 7), 100)
assert_eq(mock.count("SetMetronomeEnabled"), 1, "metronome on")
assert_eq(mock.find("SetMetronomeEnabled")[1].args[1], true, "metronome enabled")
mock.sequencer.MetronomeEnabled:set(true) -- mirror the state
L.HandleMIDINoteOn(0, mixNote(0, 7), 100)
assert_eq(mock.count("SetMetronomeEnabled"), 2, "metronome off")
assert_eq(mock.find("SetMetronomeEnabled")[2].args[1], false, "metronome disabled")
mock.sequencer.MetronomeEnabled:set(false)

-- tap tempo (row 0 col 6): manual averager; two taps 500 ms apart set 120 BPM
mock.setNow(0)
L.HandleMIDINoteOn(0, mixNote(0, 6), 100)
assert_eq(lastLog(), "LaunchpadMiniMK3: tap tempo: first tap", "tap tempo first tap")
mock.setNow(500)
L.HandleMIDINoteOn(0, mixNote(0, 6), 100)
assert_eq(mock.count("SetBPM"), 1, "tap tempo SetBPM")
assert_eq(mock.find("SetBPM")[1].args[1], 120, "tap tempo 120 BPM")
mock.setNow(5000)
L.HandleMIDINoteOn(0, mixNote(0, 6), 100) -- gap > 2 s resets the sequence
mock.setNow(5499)
L.HandleMIDINoteOn(0, mixNote(0, 6), 100)
assert_eq(mock.find("SetBPM")[2].args[1], 120, "tap tempo rounds to int BPM")

-- tempo page (row 0 col 3): up/down change BPM, holding accelerates
L.HandleMIDINoteOn(0, mixNote(0, 3), 100)
assert_eq(lastLog(), "LaunchpadMiniMK3: tempo page: 120 BPM", "tempo page on")
-- the grid draws the BPM left-aligned: 120 = "1" (col 0, blue), "2" (cols 1-3, orange), "0" (cols 4-7, white)
assert_eq(mock.leds[81][3], 127, "tempo digit 1 blue")
assert_eq(mock.leds[82][1], 127, "tempo digit 2 orange")
assert_eq(mock.leds[85][1], 127, "tempo digit 0 white")
L.HandleMIDICC(0, 91, 127) -- up: +1 BPM
assert_eq(mock.find("SetBPM")[3].args[1], 121, "tempo up")
L.HandleMIDICC(0, 92, 127) -- down: -1 BPM
assert_eq(mock.find("SetBPM")[4].args[1], 120, "tempo down")
-- holding up auto-repeats (accelerating after a short delay)
L.HandleMIDICC(0, 91, 127)
local before = mock.count("SetBPM")
for _ = 1, 20 do
	L.HandleTimer()
end
assert(mock.count("SetBPM") > before + 1, "tempo hold auto-repeats")
L.HandleMIDICC(0, 91, 0)
L.HandleMIDICC(0, 19, 127) -- menu key: pages off
assert_eq(lastLog(), "LaunchpadMiniMK3: pages off", "tempo page off via the menu key")

-- swing page (row 0 col 4; reopen the mixer first)
L.HandleMIDICC(0, 19, 127)
L.HandleMIDINoteOn(0, mixNote(0, 4), 100)
assert_eq(lastLog(), "LaunchpadMiniMK3: swing page: 50%", "swing page opens")
L.HandleMIDICC(0, 91, 127) -- up
assert_eq(lastLog(), "LaunchpadMiniMK3: swing: 51%", "swing up")
L.HandleMIDICC(0, 92, 127) -- down
assert_eq(lastLog(), "LaunchpadMiniMK3: swing: 50%", "swing down")
L.HandleMIDICC(0, 19, 127) -- exit swing page via the menu key
assert_eq(lastLog(), "LaunchpadMiniMK3: pages off", "swing page off via the menu key")

-- scene buttons stay plain launchers (no shift labels anymore)
L.HandleMIDICC(0, 19, 127) -- mixer back on for the click below
L.HandleMIDICC(0, 59, 127)
assert_eq(mock.count("TriggerRow"), 1, "scene 4 plain = TriggerRow(3)")

-- Degrade: a missing sequencer leaves the click inert, logs once, no crash.
mock.mpc.sequencer = nil
L.HandleMIDINoteOn(0, mixNote(0, 7), 100)
assert_eq(
	lastLog(),
	"LaunchpadMiniMK3: metronome unavailable: sequencer.SetMetronomeEnabled missing",
	"metronome degrade log"
)

L.OnUnload()
_G.print = realPrint
print("test-undo-redo: PASS")
