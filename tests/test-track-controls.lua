-- tests/test-track-controls.lua: volume/pan/sends fader menus from the mixer.
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

local function assert_near(a, b, msg)
	if math.abs(a - b) > 1e-6 then
		error((msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
	end
end

-- MPC fader curve: dB = 40*log10(gain) + 6; -inf is gain 0.
local function db_gain(db)
	if db <= -60 then
		return 0
	end
	return 10 ^ ((db - 6) / 40)
end

local function mixNote(row, col)
	return 10 * (8 - row) + col + 1
end

L.OnLoad()

-- Volume menu: open the mixer, press the volume pad (row 0, col 0).
L.HandleMIDICC(0, 19, 127)
L.HandleMIDINoteOn(0, mixNote(0, 0), 100)
-- The fader menu owns the grid: the menu key shows available (not white).
assert_eq(mock.leds[19][1], 60, "menu key available while the fader menu owns the grid")
-- Up/down arrows take the menu colour (cyan) while a menu is open.
assert_eq(mock.leds[91][2], 127, "up lit in menu (cyan/magenta channel)")
-- Grid pad col 0, top row (note 81) -> track 0 volume +6 dB.
L.HandleMIDINoteOn(0, 81, 100)
assert_near(mock.tracks[0].Volume.value, db_gain(6), "volume top row = +6 dB")
-- The fader fills from the bottom: the bottom pad (note 11) is lit cyan.
assert_eq(mock.leds[11][1], 0, "fader bottom red")
assert_eq(mock.leds[11][2], 127, "fader bottom green")
assert_eq(mock.leds[11][3], 127, "fader bottom blue")
-- Grid pad col 0, bottom row (note 11) -> track 0 volume -inf.
L.HandleMIDINoteOn(0, 11, 100)
assert_near(mock.tracks[0].Volume.value, 0, "volume bottom row = -inf")
-- Up (CC 91) nudges one dB step: -inf -> -30 dB.
L.HandleMIDICC(0, 91, 127)
assert_near(mock.tracks[0].Volume.value, db_gain(-30), "volume up -> -30 dB")
-- Down (CC 92) nudges back to -inf.
L.HandleMIDICC(0, 92, 127)
assert_near(mock.tracks[0].Volume.value, 0, "volume down -> -inf")
-- Up clamps at +6 dB.
for _ = 1, 10 do
	L.HandleMIDICC(0, 91, 127)
end
assert_near(mock.tracks[0].Volume.value, db_gain(6), "volume clamped at +6 dB")

-- Pan menu: open the mixer again (the volume menu closed it? no: the menu owns
-- the grid, but the menu pads live on the mixer; reopen the mixer to reach them).
L.HandleMIDICC(0, 19, 127) -- volume menu off (pages exit)
L.HandleMIDICC(0, 19, 127) -- mixer on
L.HandleMIDINoteOn(0, mixNote(0, 1), 100) -- pan
L.HandleMIDINoteOn(0, 81, 100) -- top row -> pan full left (1.0)
assert_near(mock.tracks[0].Pan.value, 1.0, "pan top row = full left")
L.HandleMIDINoteOn(0, 11, 100) -- bottom row -> pan near full right
L.HandleMIDINoteOn(0, 11, 100) -- double-tap -> the true 0.0 minimum
assert_near(mock.tracks[0].Pan.value, 0.0, "pan bottom double-tap = full right")
L.HandleMIDICC(0, 91, 127) -- nudge +1/8
assert_near(mock.tracks[0].Pan.value, 0.125, "pan up nudge")

-- Sends menu: the single send pad enters the menu; left/right cycle sends 1-4.
L.HandleMIDICC(0, 19, 127) -- pan menu off
L.HandleMIDICC(0, 19, 127) -- mixer on
L.HandleMIDINoteOn(0, mixNote(0, 2), 100) -- send menu (send 1)
L.HandleMIDINoteOn(0, 81, 100) -- track 0 send 1 = 1.0
assert_near(mock.tracks[0].Send1.value, 1.0, "send 1 top row")
L.HandleMIDICC(0, 94, 127) -- right: next send (2), no window move
assert_eq(mock.count("MoveRight"), 0, "right cycles the send, not the window")
L.HandleMIDINoteOn(0, 81, 100)
assert_near(mock.tracks[0].Send2.value, 1.0, "send 2 after cycling")
assert_eq(mock.tracks[0].Send1.value, 1.0, "send 1 untouched")
L.HandleMIDICC(0, 93, 127) -- left: previous send (1)
L.HandleMIDINoteOn(0, 11, 100) -- send 1 bottom
assert_eq(mock.tracks[0].Send1.value, 0.125, "back on send 1")

-- Double-tap the bottom pad reaches the true 0.0 minimum (on send 2).
L.HandleMIDICC(0, 94, 127) -- back to send 2
L.HandleMIDINoteOn(0, 11, 100)
L.HandleMIDINoteOn(0, 11, 100)
assert_eq(mock.tracks[0].Send2.value, 0.0, "double-tap bottom = 0.0")

L.OnUnload()
print("test-track-controls: PASS")
