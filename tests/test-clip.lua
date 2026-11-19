-- tests/test-clip.lua: clip-mode mapping + LED wire assertions.
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

L.OnLoad()
assert_eq(mock.count("SetColumns"), 1, "SetColumns")
assert_eq(mock.count("SetRows"), 1, "SetRows")
assert_eq(mock.count("Show"), 1, "Show")
assert_eq(mock.count("timer.Start"), 1, "timer.Start")
assert_eq(mock.count("AddNoteToScript"), 64, "grid notes registered")
assert_eq(mock.count("AddCCToScript"), 16, "edge CCs registered (7 scenes + 8 top + menu)")

-- initial grid paint: 64 pads
local painted = 0
for i = 11, 88 do
	if mock.leds[i] then
		painted = painted + 1
	end
end
assert(painted >= 64, "grid painted")

-- clip states: the mock's slots are State 2 (stopped) with colour 0xFF0000 ->
-- the top-left slot (clip row 0) shows the clip's own colour, solid
assert_eq(mock.leds[81][1], 127, "stopped clip shows its own colour (red)")

-- pad press -> TriggerClip(0,7) (bottom-left pad -> MPC row 7)
L.HandleMIDINoteOn(0, 11, 100)
assert_eq(mock.count("TriggerClip"), 1, "TriggerClip")
assert_eq(mock.find("TriggerClip")[1].args[1], 0, "TriggerClip col")
assert_eq(mock.find("TriggerClip")[1].args[2], 7, "TriggerClip row (bottom pad -> MPC row 7)")

-- scene press -> TriggerRow(0) (top scene button CC 89)
L.HandleMIDICC(0, 89, 127)
assert_eq(mock.count("TriggerRow"), 1, "TriggerRow")
assert_eq(mock.find("TriggerRow")[1].args[1], 0, "TriggerRow row")
-- bottom scene button (CC 29) -> row 6 (the 8th position is the mixer key)
L.HandleMIDICC(0, 29, 127)
assert_eq(mock.find("TriggerRow")[2].args[1], 6, "TriggerRow row 6")

-- a plain pad press selects AND triggers (SelectClip + TriggerClip together)
L.HandleMIDINoteOn(0, 12, 100)
assert_eq(mock.count("SelectClip"), 2, "SelectClip")
assert_eq(mock.count("TriggerClip"), 2, "plain press triggers")

-- window moves: up/down/left/right on the top row
L.HandleMIDICC(0, 93, 127)
assert_eq(mock.count("MoveLeft"), 1, "MoveLeft")
L.HandleMIDICC(0, 94, 127)
assert_eq(mock.count("MoveRight"), 1, "MoveRight")
L.HandleMIDICC(0, 91, 127)
assert_eq(mock.count("MoveUp"), 1, "MoveUp")
L.HandleMIDICC(0, 92, 127)
assert_eq(mock.count("MoveDown"), 1, "MoveDown")

-- LED budget: the LED messages carry the LPMiniMK3 colorspec header 00 20 29 02 0D 03
assert(mock.count("SendMIDISysex") >= 1, "sysex sent")
local ledSysex = 0
for _, c in ipairs(mock.find("SendMIDISysex")) do
	if #c.args[1] >= 6 and c.args[1]:sub(6, 6) == string.char(0x03) then
		assert_eq(c.args[1]:sub(1, 5), string.char(0x00, 0x20, 0x29, 0x02, 0x0D), "LPMiniMK3 LED sysex header")
		ledSysex = ledSysex + 1
	end
end
assert(ledSysex >= 1, "at least one LED colorspec message")

L.OnUnload()
assert_eq(mock.count("timer.Stop"), 1, "timer.Stop")
assert_eq(mock.count("Hide"), 1, "Hide")
-- every listener stopped: 192 slots + scene/track/sequencer + currentTrack.Index
assert(mock.count("stopListening") >= 228, "removeListeners stops all listeners")

print("test-clip: PASS")
