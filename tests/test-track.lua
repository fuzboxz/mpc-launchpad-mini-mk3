-- tests/test-track.lua: the MIXER menu's per-track rows (select/arm/solo/mute/stop).
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

-- open the mixer (bottom-right corner CC 19)
L.HandleMIDICC(0, 19, 127)
assert_eq(mock.count("TriggerClip"), 0, "menu key does not trigger clips")

-- bottom row (notes 11-18) selects the track under each grid column
L.HandleMIDINoteOn(0, 11, 100)
assert_eq(mock.count("SelectTrack"), 1, "SelectTrack")
assert_eq(mock.count("SetCurrentTrack"), 1, "track select sets the real current track")
assert_eq(mock.find("SelectTrack")[1].args[1], 0, "track 0")

-- row 6 (notes 21-28) record-arms the column's track
L.HandleMIDINoteOn(0, 21, 100)
assert_eq(mock.count("SetRecArm"), 1, "SetRecArm")
assert_eq(mock.find("SetRecArm")[1].args[1], 0, "arm track 0")
assert_eq(mock.find("SetRecArm")[1].args[2], true, "arm value true")

-- row 5 (notes 31-38) solos
L.HandleMIDINoteOn(0, 32, 100)
assert_eq(mock.count("SetSolo"), 1, "SetSolo")
assert_eq(mock.find("SetSolo")[1].args[1], 1, "solo track 1")

-- row 4 (notes 41-48) mutes
L.HandleMIDINoteOn(0, 43, 100)
assert_eq(mock.count("SetMute"), 1, "SetMute")
assert_eq(mock.find("SetMute")[1].args[1], 2, "mute track 2")

-- row 3 (notes 51-58) stops the track's clips
L.HandleMIDINoteOn(0, 54, 100)
assert_eq(mock.count("StopClipsOnTrack"), 1, "StopClipsOnTrack")
assert_eq(mock.find("StopClipsOnTrack")[1].args[1], 3, "stop track 3")

-- after scrolling right by 1, mixer column 0 controls global track 1
L.HandleMIDICC(0, 19, 127) -- close
L.HandleMIDICC(0, 94, 127) -- MoveRight(1)
L.HandleMIDICC(0, 19, 127) -- reopen
L.HandleMIDINoteOn(0, 41, 100)
assert_eq(mock.count("SetMute"), 2, "SetMute after scroll")
assert_eq(mock.find("SetMute")[2].args[1], 1, "track 1 after scroll")

-- LED state: armed track's arm pad is red, un-armed dim (window moved right
-- by 1, so column 0 is global track 1)
mock.tracks[1].RecArm:set(true) -- listener repaints the open mixer
assert_eq(mock.leds[21][1], 127, "armed track arm pad red")
assert_eq(mock.leds[21][2], 0, "armed pad has no green")
assert_eq(mock.leds[22][1], 30, "un-armed track arm pad dark red tint")
assert_eq(mock.leds[22][2], 0, "arm tint has no green")
-- select row: the current track is white; others show their track colour
L.HandleMIDINoteOn(0, 12, 100) -- select column 1 -> global track 2
assert_eq(mock.leds[12][1], 127, "select row: current track white")
assert_eq(mock.leds[12][2], 127, "select row: current track white (green channel)")
assert_eq(mock.leds[11][2], 76, "select row: other tracks show their colour")

-- close via the menu key
L.HandleMIDICC(0, 19, 127)
L.HandleMIDINoteOn(0, 11, 100) -- back on the clip grid: triggers again
assert_eq(mock.count("TriggerClip"), 1, "clip grid after mixer close")

L.OnUnload()
print("test-track: PASS")
