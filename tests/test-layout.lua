-- tests/test-layout.lua: the LPMiniMK3 wire protocol — mode/layout/feedback
-- readbacks, Programmer-mode entry, restore on unload, LED spec cap.
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

local function lastSysex()
	local calls = mock.find("SendMIDISysex")
	return calls[#calls]
end

local function sentPayload(payload)
	for _, c in ipairs(mock.find("SendMIDISysex")) do
		if c.args[1] == payload then
			return true
		end
	end
	return false
end

local HDR = string.char(0x00, 0x20, 0x29, 0x02, 0x0D)

L.OnLoad()
-- readbacks went out: mode (0E), layout (00), LED feedback (0A)
assert(sentPayload(HDR .. string.char(0x0E)), "mode readback sent")
assert(sentPayload(HDR .. string.char(0x00)), "layout readback sent")
assert(sentPayload(HDR .. string.char(0x0A)), "feedback readback sent")
-- device inquiry sent
assert(sentPayload(string.char(0x7E, 0x7F, 0x06, 0x01)), "device inquiry sent")

-- no programmer-mode select before the first timer tick
assert(not sentPayload(HDR .. string.char(0x0E, 0x01)), "no premature programmer entry")

-- replies arrive and are captured (Novation Mini MK3: family 13, model 01)
L.HandleMIDISysex(HDR .. string.char(0x0E, 0x00)) -- Live mode
L.HandleMIDISysex(HDR .. string.char(0x00, 0x04)) -- Custom mode 1 (Drums)
L.HandleMIDISysex(HDR .. string.char(0x0A, 0x01, 0x01)) -- feedback defaults

-- first tick: enter Programmer mode, set feedback (internal off, external on)
L.HandleTimer()
assert(sentPayload(HDR .. string.char(0x0E, 0x01)), "programmer mode selected")
assert(sentPayload(HDR .. string.char(0x0A, 0x00, 0x01)), "feedback set on entry")


-- LED colorspec messages never exceed the 81-spec message cap
for i = 1, 45 do
	L.HandleTimer() -- crosses the 2 s full-repaint boundary with a cold cache
end
for _, c in ipairs(mock.find("SendMIDISysex")) do
	local b = c.args[1]
	if #b >= 6 and b:sub(6, 6) == string.char(0x03) then
		local i, specs = 7, 0
		while i <= #b do
			local typ = b:byte(i)
			if typ == 3 then
				i = i + 5
			elseif typ == 1 then
				i = i + 4
			else
				i = i + 3
			end
			specs = specs + 1
		end
		assert(specs <= 81, "LED message respects the 81-spec cap")
	end
end

-- unload: feedback restored, Live mode + prior layout restored
L.OnUnload()
assert(sentPayload(HDR .. string.char(0x0A, 0x01, 0x01)), "feedback restored")
assert(sentPayload(HDR .. string.char(0x0E, 0x00)), "live mode restored")
assert(sentPayload(HDR .. string.char(0x00, 0x04)), "prior layout restored")
-- the surface went dark: grid + edges
assert_eq(mock.leds[11][1], 0, "grid dark on unload")
assert_eq(mock.leds[19][1], 0, "menu key dark on unload")

print("test-layout: PASS")
