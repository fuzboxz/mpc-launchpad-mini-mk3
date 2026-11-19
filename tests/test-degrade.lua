-- tests/test-degrade.lua: the script loads and runs with optional APIs removed.
package.path = "./tests/?.lua;" .. package.path
local mock = require("mock-mpc")
_G.mpc = mock.mpc
_G.dev = mock.dev
-- remove optional APIs
mock.dev.clipMatrixAperture = nil
mock.mpc.clipMatrix = nil
mock.mpc.sequencer = nil
mock.mpc.commandManager = nil
_G.LaunchpadMiniMK3 = mock.dev
dofile(os.getenv("LPMINI_LUA") or "script/LaunchpadMiniMK3.lua")
local L = LaunchpadMiniMK3
L.OnLoad()
L.HandleMIDINoteOn(0, 11, 100)
L.HandleMIDICC(0, 19, 127)
L.HandleMIDINoteOn(0, 61, 100)
L.HandleTimer()
L.OnUnload()
print("test-degrade: PASS")
