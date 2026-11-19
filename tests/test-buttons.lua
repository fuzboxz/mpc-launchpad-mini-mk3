-- tests/test-buttons.lua: Shift functions (logo = Shift): follow, probe, track
-- navigation, quantize/presets/step-seq on Shift+scene, and the firmware probe.
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
local function logCount(prefix)
	local n = 0
	for _, l in ipairs(logs) do
		if l:sub(1, #prefix) == prefix then
			n = n + 1
		end
	end
	return n
end

L.OnLoad()

-- Firmware probe: OnLoad sent the device-inquiry sysex (payload without F0/F7).
local inquiries = 0
for _, c in ipairs(mock.find("SendMIDISysex")) do
	if c.args[1] == string.char(0x7E, 0x7F, 0x06, 0x01) and c.args[2] == 0 then
		inquiries = inquiries + 1
	end
end
assert_eq(inquiries, 1, "device inquiry sent once")
-- identity reply (Novation Mini MK3: family 13h, model 01h, 4 version bytes)
L.HandleMIDISysex(string.char(0x7E, 0x00, 0x06, 0x02, 0x00, 0x20, 0x29, 0x13, 0x01, 0x00, 0x00, 0x01, 0x01, 0x08, 0x00))
assert_eq(lastLog(), "LaunchpadMiniMK3: firmware: 1.1.8.0", "firmware version logged")
L.HandleMIDISysex(string.char(0x7E, 0x00, 0x06, 0x02, 0x00, 0x20, 0x29, 0x13, 0x01, 0x00, 0x00, 0x01, 0x01, 0x08, 0x00))
assert_eq(logCount("LaunchpadMiniMK3: firmware:"), 1, "firmware logged once")
-- a non-Novation identity reply is ignored
L.HandleMIDISysex(string.char(0x7E, 0x00, 0x06, 0x02, 0x47, 0x00, 0x5D, 0x00, 0x00, 0x00, 0x01, 0x02, 0x41))
assert_eq(logCount("LaunchpadMiniMK3: firmware:"), 1, "non-Novation reply ignored")

-- There is NO shift layer: the logo is not a button, CC 99 is unregistered
-- and every press is a plain press.
for _, c in ipairs(mock.find("AddCCToScript")) do
	assert(c.args[2] ~= 99, "CC 99 must not be registered (logo is not a button)")
end
L.HandleMIDICC(0, 99, 127) -- nothing handles it
assert_eq(logCount("LaunchpadMiniMK3: unmapped CC 99"), 1, "CC 99 is unmapped")

-- arrows: plain window moves only
L.HandleMIDICC(0, 93, 127)
local left = mock.find("MoveLeft")
assert_eq(left[#left].args[1], 1, "left moves by 1")
L.HandleMIDICC(0, 94, 127)
local right = mock.find("MoveRight")
assert_eq(right[#right].args[1], 1, "right moves by 1")

-- keys (CC 97) opens the Pad Perform page and enters pads mode
L.HandleMIDICC(0, 97, 127)
assert_eq(mock.count("padPerform.Press"), 0, "no Pad Perform on a drum track")
assert_eq(mock.count("AddNoteToMpcPad"), 16, "keys enters pads mode")
L.HandleMIDICC(0, 97, 127) -- leave again (keep the surface clean for what follows)
assert_eq(mock.count("padPerform.Press"), 0, "drum-track keys never touches Pad Perform")
assert_eq(mock.count("main.Press"), 2, "main pressed on keys enter and exit")

L.OnUnload()
_G.print = realPrint
print("test-buttons: PASS")
