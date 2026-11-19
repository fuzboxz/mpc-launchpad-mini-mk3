-- tests/test-qlink.lua: Q-Link page (CC 98 user), driven by Twist on controlSurface.qlinks.
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

local function lastCall(name)
	local calls = mock.find(name)
	return calls[#calls]
end

L.OnLoad()
mock.reset()

-- Entering the Q-Link page from pads mode must hand the quadrant notes back to
-- the script: no note may stay bound to the MPC pads (they would keep PLAYING
-- through the page).
L.HandleMIDICC(0, 96, 127) -- enter pads mode (drum quadrant)
assert_eq(mock.count("AddNoteToMpcPad"), 16, "quadrant bound")
L.HandleMIDICC(0, 98, 127) -- user -> Q-Link page
assert_eq(mock.count("RemoveNoteToMpcPad"), 16, "quadrant pad bindings released")
-- the script binding was never removed, so the notes were consumed throughout
assert_eq(mock.leds[98][1], 127, "user button white on qlink page")
L.HandleMIDINoteOn(0, 11, 100) -- former quadrant pad: drives a qlink, plays nothing
assert_eq(mock.count("Twist"), 1, "former quadrant pad drives a qlink")

-- The MPC's DEFAULT Q-Link pages are global sequencer selectors (CURRENT TRACK,
-- SEQUENCE LENGTH, ...): driving them from a fader pad switches tracks mid-play
-- and slams sequence length/tempo. They are blocked: dark column, inert pad.
L.OnUnload()
L.OnLoad()
mock.reset()
-- after reset(): it clears the mock's qlink target names too
mock.setQlinkTarget(12, "CURRENT TRACK") -- column 1 on the MPC's page 1
mock.setQlinkTarget(8, "SEQUENCE LENGTH")
mock.setQlinkTarget(4, "TRACK LEVEL") -- a real fader: stays
L.HandleMIDICC(0, 98, 127) -- user -> Q-Link page
L.HandleMIDINoteOn(0, 81, 100) -- column 1 pad: CURRENT TRACK must be inert
assert_eq(mock.count("Twist"), 0, "blocked qlink column does not twist")
assert_eq(mock.count("SetCurrentTrack"), 0, "blocked CURRENT TRACK qlink cannot switch tracks")
L.HandleMIDINoteOn(0, 83, 100) -- column 3 pad: TRACK LEVEL is a real fader
assert_eq(mock.count("Twist"), 1, "TRACK LEVEL qlink still drives")

-- restore the mock's default target names for the sections below
mock.setQlinkTarget(12, nil)
mock.setQlinkTarget(8, nil)
mock.setQlinkTarget(4, nil)

-- Entering pads mode closes the Q-Link page (mutual exclusion, both ways).
mock.reset()
L.HandleMIDICC(0, 96, 127) -- drums -> pads mode
assert_eq(mock.count("AddNoteToMpcPad"), 16, "pads mode can be entered from the qlink page")
assert_eq(L.STATE().qlinkMode, false, "pads mode closes the qlink page")

-- back to the Q-Link page for the sections below
L.HandleMIDICC(0, 95, 127) -- session: close everything
L.HandleMIDICC(0, 98, 127) -- user -> Q-Link page again

-- The pad drives above account for every qlink write so far.
local twists = mock.count("Twist")

-- Display order (MPC screen, column-major, reversed within each bank):
-- page 1 = 12,8,4,0,13,9,5,1; page 2 = 14,10,6,2,15,11,7,3.
-- Top pad in column 1: Q-Link 12 -> 127, one Twist(127) from position 0.
L.HandleMIDINoteOn(0, 81, 100)
local c = lastCall("Twist")
assert_eq(mock.count("Twist"), twists + 1, "one twist for the pad press")
assert_eq(c.args[1], 12, "qlink 12 in column 1")
assert_eq(mock.qlinks[12]:GetPosition(), 127, "qlink 12 position 127 (delta from the earlier 16)")

-- Bottom pad in column 2: Q-Link 8 -> 16 (1/8 of 127).
L.HandleMIDINoteOn(0, 12, 100)
c = lastCall("Twist")
assert_eq(c.args[1], 8, "qlink 8 in column 2")
assert_eq(c.args[2], 16, "qlink 8 delta 16")
assert_eq(mock.qlinks[8]:GetPosition(), 16, "qlink 8 position 16")

-- Up (CC 91) switches to page 2 (first slot there is Q-Link 14); down (CC 92) goes back.
L.HandleMIDICC(0, 91, 127)
L.HandleMIDINoteOn(0, 81, 100)
c = lastCall("Twist")
assert_eq(c.args[1], 14, "qlink 14 on page 2")
assert_eq(c.args[2], 127, "qlink 14 delta 127")
assert_eq(mock.qlinks[14]:GetPosition(), 127, "qlink 14 position 127")
L.HandleMIDICC(0, 92, 127)
L.HandleMIDICC(0, 91, 127)

-- Fallback: a qlink without Twist is driven with SetPosition.
L.HandleMIDICC(0, 92, 127) -- back to page 1
local savedTwist = mock.qlinks[8].Twist
mock.qlinks[8].Twist = nil
L.HandleMIDINoteOn(0, 12, 100) -- column 2 = qlink 8
c = lastCall("SetPosition")
assert_eq(c.args[1], 8, "fallback qlink 8")
assert_eq(c.args[2], 16, "fallback position 16")
mock.qlinks[8].Twist = savedTwist

-- The mixer's qlink pad also enters the page; mutual exclusion with the mixer.
L.HandleMIDICC(0, 19, 127) -- first press: pages off (the qlink page closes)
L.HandleMIDICC(0, 19, 127) -- second press: mixer open
assert_eq(mock.leds[19][1], 127, "mixer open, menu key white")
L.HandleMIDINoteOn(0, 86, 100) -- mixer row 0 col 5 = qlink
assert_eq(mock.leds[98][1], 127, "user button white via the mixer pad")
-- a pad press on the qlink page must neither launch a clip nor open the mixer
local twistCount = mock.count("Twist")
local clipCount = mock.count("TriggerClip")
L.HandleMIDINoteOn(0, 82, 100) -- column 1 top pad (qlink 8 was left at 16)
assert_eq(mock.count("Twist"), twistCount + 1, "pad drives a qlink")
assert_eq(mock.count("TriggerClip"), clipCount, "no clip launch on the qlink page")

-- Press CC 98 twice to exit (page 2 first); a pad now launches a clip, button available.
L.HandleMIDICC(0, 98, 127)
L.HandleMIDICC(0, 98, 127)
assert_eq(mock.leds[98][1], 60, "user button available after exit")
L.HandleMIDINoteOn(0, 11, 100)
assert_eq(mock.count("TriggerClip"), clipCount + 1, "clip launch restored")

L.OnUnload()
print("test-qlink: PASS")
