-- tests/test-mixer.lua: the MIXER menu exposes record/stop/mute/solo/arm/select
-- per track at the same time, plus the two strips and the exit paths.
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

local function mixNote(row, col)
	return 10 * (8 - row) + col + 1
end

L.OnLoad()

-- all six per-track rows are exposed at the same time
L.HandleMIDICC(0, 19, 127)
-- pages strip: dim tints when idle (a solid bright colour would read "active")
assert_eq(mock.leds[mixNote(0, 0)][2], 22, "volume pad idles dim cyan (g)")
assert_eq(mock.leds[mixNote(0, 0)][3], 22, "volume pad idles dim cyan (b)")
assert_eq(mock.leds[mixNote(0, 1)][1], 22, "pan pad idles dim magenta (r)")
assert_eq(mock.leds[mixNote(0, 2)][1], 22, "send pad idles dim send colour")
assert_eq(mock.leds[mixNote(0, 3)][1], 20, "tempo pad idles dim white")
assert_eq(mock.leds[mixNote(0, 6)][1], 60, "tap pad grey (action, no state)")
-- row identity: each row idles in its own tint
assert_eq(mock.leds[mixNote(2, 0)][3], 45, "record row idles dark blue")
assert_eq(mock.leds[mixNote(2, 0)][1], 0, "record row idle has no red")
assert_eq(mock.leds[mixNote(4, 0)][1], 35, "mute row idles dark orange")
assert_eq(mock.leds[mixNote(5, 0)][1], 22, "solo row idles dark yellow")
assert_eq(mock.leds[mixNote(5, 0)][2], 22, "solo row idle g")
assert_eq(mock.leds[mixNote(6, 0)][1], 30, "arm row idles dark red")
local rows = { record = 2, stop = 3, mute = 4, solo = 5, arm = 6, select = 7 }
for name, row in pairs(rows) do
	for col = 0, 7 do
		assert(mock.leds[mixNote(row, col)] ~= nil, name .. " row pad " .. col .. " painted")
	end
end
-- the menu key lights white while the mixer is open
assert_eq(mock.leds[19][1], 127, "menu key white while open")

-- state colours: mute orange, solo yellow, arm red, select = track colour
mock.tracks[0].Mute:set(true)
mock.tracks[1].Solo:set(true)
mock.tracks[2].RecArm:set(true)
assert_eq(mock.leds[mixNote(4, 0)][1], 127, "mute row orange")
assert_eq(mock.leds[mixNote(4, 0)][2], 60, "mute row orange g")
assert_eq(mock.leds[mixNote(5, 1)][1], 127, "solo row yellow")
assert_eq(mock.leds[mixNote(5, 1)][2], 127, "solo row yellow g")
assert_eq(mock.leds[mixNote(6, 2)][1], 127, "arm row red")
assert_eq(mock.leds[mixNote(6, 2)][2], 0, "arm row red g")
assert_eq(mock.leds[mixNote(7, 3)][2], 76, "select row track colour (mock green)")

-- record row: armed = dim red, recording = bright red
assert_eq(mock.leds[mixNote(2, 2)][1], 60, "armed-not-recording dim red")
mock.clips[2] = { [3] = "recording" }
L.HandleTimer()
assert_eq(mock.leds[mixNote(2, 2)][1], 127, "recording bright red")
assert_eq(mock.leds[mixNote(2, 2)][2], 0, "recording bright red g")

-- record press on a recording track stops it
L.HandleMIDINoteOn(0, mixNote(2, 2), 100)
assert_eq(mock.count("StopClipsOnTrack"), 1, "record row press stops the recording")

-- record press on an idle track: select + arm + trigger the first empty slot
mock.clips[3] = { [0] = "stopped" }
L.HandleMIDINoteOn(0, mixNote(2, 3), 100)
assert_eq(mock.find("SetRecArm")[1].args[1], 3, "record press arms the track")
assert_eq(mock.find("SetRecArm")[1].args[2], true, "record press arms true")
assert_eq(mock.find("SetCurrentTrack")[1].args[1], 3, "record press selects the track")
local trig = mock.find("TriggerClip")
assert_eq(trig[#trig].args[1], 3, "record press triggers the column")
assert_eq(trig[#trig].args[2], 1, "record press triggers the first EMPTY slot (row 0 occupied)")

-- the pages strip opens the volume/pan/send menus (which replace the mixer view)
L.HandleMIDINoteOn(0, mixNote(0, 0), 100) -- volume
assert_eq(mock.leds[19][1], 60, "menu key available while a fader menu owns the grid")
L.HandleMIDINoteOn(0, mixNote(0, 1), 100) -- pan (volume menu closes it first)
L.HandleMIDINoteOn(0, mixNote(0, 2), 100) -- send 1
L.HandleMIDINoteOn(0, mixNote(0, 2), 100) -- send 2 (cycles)
-- tempo/swing pages close the mixer too
L.HandleMIDINoteOn(0, mixNote(0, 3), 100) -- tempo page
assert_eq(mock.count("SetBPM"), 0, "tempo page opens without touching BPM")
L.HandleMIDINoteOn(0, mixNote(0, 4), 100) -- swing page (tempo closes)

-- the menu key closes any open page, then reopens the mixer on the next press
L.HandleMIDICC(0, 19, 127) -- swing off -> "pages off"
L.HandleMIDINoteOn(0, 11, 100) -- clip grid: triggers
assert_eq(mock.count("TriggerClip"), 2, "pages off returns to the clip grid")
L.HandleMIDICC(0, 19, 127) -- mixer again
L.HandleMIDINoteOn(0, mixNote(7, 0), 100) -- select works again
assert_eq(mock.count("SetCurrentTrack"), 2, "mixer reopened")

-- Shift + menu closes the mixer
L.HandleMIDICC(0, 99, 127)
L.HandleMIDICC(0, 19, 127)
L.HandleMIDICC(0, 99, 0)
L.HandleMIDINoteOn(0, mixNote(7, 0), 100)
assert_eq(mock.count("SetCurrentTrack"), 2, "shift+menu closed the mixer (pad triggers instead)")
assert_eq(mock.count("TriggerClip"), 3, "clip grid after shift+menu")

-- Session (CC 95) leaves every page: mixer closes, the clip grid returns
L.HandleMIDICC(0, 19, 127)
assert_eq(mock.leds[19][1], 127, "mixer reopened")
L.HandleMIDICC(0, 95, 127)
assert_eq(mock.leds[19][1], 60, "session closed the mixer")
L.HandleMIDINoteOn(0, 11, 100)
assert_eq(mock.count("TriggerClip"), 4, "clip grid after session")

-- the window arrows do nothing while a page owns the grid
L.HandleMIDICC(0, 19, 127)
L.HandleMIDINoteOn(0, 81, 100) -- volume menu (closes the mixer)
local moves = #mock.find("MoveLeft")
L.HandleMIDICC(0, 93, 127) -- left: blocked in the fader menu
assert_eq(#mock.find("MoveLeft"), moves, "left blocked while the fader menu is open")
L.HandleMIDINoteOn(0, 81, 100) -- close the volume menu

-- no project: the mixer refuses to open
mock.mpc.currentSequence = nil
mock.mpc.tracks.currentTrack = nil
mock.mpc.sequencer.GetBPM = nil
L.HandleMIDICC(0, 19, 127)
L.HandleMIDINoteOn(0, mixNote(7, 0), 100)
assert_eq(mock.count("SetCurrentTrack"), 2, "mixer closed without a project")

L.OnUnload()
print("test-mixer: PASS")
