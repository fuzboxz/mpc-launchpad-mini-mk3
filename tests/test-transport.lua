-- tests/test-transport.lua: the mixer transport strip (play / record / stop)
-- and its Shift layer (Shift+play = loop, Shift+record = overdub,
-- Shift+keys / Shift+user = undo / redo).
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

L.OnLoad()
L.HandleMIDICC(0, 19, 127) -- open the mixer

-- play STARTS (no toggle); while playing a second play press does nothing
L.HandleMIDINoteOn(0, 71, 100)
assert_eq(mock.count("Play"), 1, "Play")
mock.sequencer.IsPlaying = function()
	return true
end
mock.sequencer.Playing:set(true)
L.HandleMIDINoteOn(0, 71, 100)
assert_eq(mock.count("Play"), 1, "play does not toggle")
assert_eq(mock.count("Stop"), 0, "play never stops")

-- stop STOPS; stop while stopped locates zero
L.HandleMIDINoteOn(0, 73, 100)
assert_eq(mock.count("Stop"), 1, "Stop")
mock.sequencer.IsPlaying = function()
	return false
end
mock.sequencer.Playing:set(false)
L.HandleMIDINoteOn(0, 73, 100)
assert_eq(mock.count("Stop"), 1, "no double stop")
assert_eq(mock.count("JumpToBeginning"), 1, "stop-when-stopped locates zero")

-- record toggles (delegates to the MPC's REC button)
L.HandleMIDINoteOn(0, 72, 100)
assert_eq(mock.count("record.Press"), 1, "record button pressed to arm")
assert_eq(lastLog(), "LaunchpadMiniMK3: record: armed", "armed logged")
L.HandleMIDINoteOn(0, 72, 100)
assert_eq(mock.count("record.Press"), 2, "record button pressed to disarm")

-- LEDs: play green while playing, orange with loop on, record red while armed
mock.sequencer.Playing:set(true)
mock.sequencer.Loop:set(true)
assert_eq(mock.leds[71][2], 127, "play pad green while playing")
mock.sequencer.Playing:set(false)
mock.sequencer.Loop:set(true)
assert_eq(mock.leds[71][2], 60, "play pad orange while loop is on")
mock.sequencer.RecordState:set(1)
assert_eq(mock.leds[72][1], 127, "record pad red while RecordState is on")
assert_eq(mock.leds[73][1], 60, "stop pad grey (action)")

-- the removed pads (74-78) are dark and inert
assert_eq(mock.leds[74][1], 0, "pad 74 dark (removed)")
L.HandleMIDINoteOn(0, 74, 100)
assert_eq(mock.count("Play"), 1, "removed pad inert")
L.HandleMIDINoteOn(0, 75, 100)
assert_eq(mock.count("Stop"), 1, "removed pad inert")

L.OnUnload()
_G.print = realPrint
print("test-transport: PASS")
