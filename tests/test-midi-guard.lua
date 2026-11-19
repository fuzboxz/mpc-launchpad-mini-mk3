-- tests/test-midi-guard.lua: the track-input guard.
--
-- Device facts (3.10.1.12, readback probe): the controller port feeds the
-- MPC's MIDI engine unconditionally — script mappings are additive dispatch
-- and consume nothing (the leak showed in plain session mode). Every new
-- drum track defaults to MIDI-triggered input "All Inputs" (sentinel -3,
-- readback 2147483645), channel omni, so any channel-0 note sounds them.
--
-- The guard moves All-default tracks to the discovered "none" sentinel,
-- verified by readback, and never touches tracks set to a specific port.
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
mock.reset()

-- the probe + first guard run land on the first project-loaded 10-tick mark
for _ = 1, 10 do
	L.HandleTimer()
end
local sets = mock.find("SetTrackInputPort")
assert(#sets >= 8, "guard ran for the tracks (" .. #sets .. " sets)")
for _, s in ipairs(sets) do
	assert_eq(s.args[2], -1, "guard set the discovered 'none' sentinel (-1)")
end
-- every mock track (keys 0-7 and their names) reads back off the All default
assert_eq(mock.mpc.tracks.GetTrackInputPort(0), -1, "track 0 guarded")
assert_eq(mock.mpc.tracks.GetTrackInputPort(3), -1, "track 3 guarded")
assert_eq(mock.mpc.tracks.GetTrackInputPort("Track 5"), -1, "name-keyed readback guarded")

-- idempotence: another guard cycle (2 s) must not re-set anything
mock.reset()
for _ = 1, 40 do
	L.HandleTimer()
end
assert_eq(mock.count("SetTrackInputPort"), 0, "guard is idempotent once off All")

-- a track the user pointed at a specific port is never touched
mock.mpc.tracks.SetTrackInputPort(7, 4) -- "port 4", not the All sentinel
mock.reset()
for _ = 1, 40 do
	L.HandleTimer()
end
assert_eq(mock.count("SetTrackInputPort"), 0, "specific-port tracks are left alone")
assert_eq(mock.mpc.tracks.GetTrackInputPort(7), 4, "user setting preserved")

-- a NEW track defaulting to All is picked up by the next cycle
mock.mpc.tracks.SetTrackInputPort(6, 2147483645) -- re-default one to All
mock.reset()
for _ = 1, 40 do
	L.HandleTimer()
end
assert_eq(mock.mpc.tracks.GetTrackInputPort(6), -1, "new All-default track guarded")
assert_eq(mock.mpc.tracks.GetTrackInputPort(7), 4, "specific-port track still preserved")

L.OnUnload()
print("test-midi-guard: PASS")
