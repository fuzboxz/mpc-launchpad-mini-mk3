-----------------------------------------------------------------------------------------------
-- LaunchpadMiniMK3.lua
-- Novation Launchpad Mini MK3 as a controller surface for Akai MPC 3.10.1 (Gen2, MPC Live III).
--
-- Programmer mode (SysEx header F0 00 20 29 02 0D). The Mini sends grid pads as notes 11-88
-- (bottom-left first — the same numbering as the Launchpad Pro MK3) and the edge buttons as
-- CCs. LEDs are driven by MPC state (property listeners + a 250 ms timer), never by the
-- button press alone.
--
-- Surface (Programmer mode; LED indices = the same numbers):
--   grid notes 11-88     8x8: clip window (launch; Shift+pad = select) or the page/mixer views
--   top row CC 91-98     91 up, 92 down, 93 left, 94 right, 95 session, 96 drums (MPC pads
--                        mode; repeat flips 16 <-> 64 pads), 97 keys (Pad Perform from the
--                        grid), 98 user (Q-Link page).
--                        The Novation logo is NOT a button: no shift layer exists.
--   right column CC      89,79,69,59,49,39,29 = scenes 1-7 (TriggerRow 0-6),
--                        19 = the bottom-right corner: MIXER menu
--
-- MIXER menu (CC 19), rows top to bottom — mute, solo, stop, select, record and
-- arm are all exposed at the same time, one row per function, one column per track
-- (the columns follow the clip window, so the mixer lines up with the grid):
--   row 0 notes 81-88   volume, pan, send (cycles 1-4), tempo page, swing page,
--                       Q-Link page, tap tempo, click
--   row 1 notes 71-73   play, record, stop (stop again returns to zero)
--   row 2 notes 61-68   RECORD per track: bright red = clip recording on that track,
--                       dim red = armed; press = start a clip recording (arm + trigger
--                       the first empty slot) / stop the track's recording
--   row 3 notes 51-58   stop clips (per track column)
--   row 4 notes 41-48   mute (per track column)
--   row 5 notes 31-38   solo (per track column)
--   row 6 notes 21-28   record arm (per track column)
--   row 7 notes 11-18   select track (per track column)
--

-- LED protocol: F0 00 20 29 02 0D 03 <spec>... F7; spec = <type> <index> <data>.
--   type 0 = static palette (1 byte), 1 = flashing (2 bytes), 2 = pulsing (1 byte),
--   type 3 = RGB (3 bytes, 0-127). Up to 81 specs per message (the whole surface).
--   SendMIDISysex takes the payload without F0/F7.
--
-- Degrade, never break: every optional API is guarded; a missing feature disables its surface.
-----------------------------------------------------------------------------------------------

local deviceName = "LaunchpadMiniMK3" -- must match the file name
local port = 0 -- the one LPMiniMK3 MIDI output (order of output= lines in the .ini)
local dev = LaunchpadMiniMK3

-- LPMiniMK3 Programmer-mode layout (programmer's reference p.10 + p.13 examples)
local GRID_NOTE0 = 11 -- notes 11-88, bottom-left first (10-note blocks)
local GRID_COLS, GRID_ROWS = 8, 8
local TOP = {
	up = 91,
	down = 92,
	left = 93,
	right = 94,
	session = 95,
	drums = 96,
	keys = 97,
	user = 98,
}
local SCENE = { 89, 79, 69, 59, 49, 39, 29 } -- scene buttons, top to bottom (rows 0-6)
local MENU = 19 -- bottom-right corner button: the MIXER menu
local SYSEX_MAX_SPECS = 81 -- the whole surface (64 pads + 8 top + 8 right)

-- Reference data for the generated manual (docs/MANUAL.md, tools/gen-manual.lua).
-- Every CC that the dispatch tables handle must have an entry here; a test
-- enforces that both directions stay complete.
local ACTIONS = {
	[91] = { label = "Up", plain = "window up / page value up (hold repeats)" },
	[92] = { label = "Down", plain = "window down / page value down (hold repeats)" },
	[93] = { label = "Left", plain = "move the clip window left (sends menu: previous send)" },
	[94] = { label = "Right", plain = "move the clip window right (sends menu: next send)" },
	[95] = { label = "Session", plain = "clip grid (leaves every page)" },
	[96] = { label = "Drums", plain = "pads mode; repeat: 16-pad quadrant <-> 64 pads, then off" },
	[97] = { label = "Keys", plain = "play the track's pads from the grid — kits plainly, melodic tracks with Pad Perform chords (repeat: leave)" },
	[98] = { label = "User", plain = "Q-Link page (repeat: page 2, then exit)" },
	[89] = { label = "Scene 1", plain = "launch scene 1" },
	[79] = { label = "Scene 2", plain = "launch scene 2" },
	[69] = { label = "Scene 3", plain = "launch scene 3" },
	[59] = { label = "Scene 4", plain = "launch scene 4" },
	[49] = { label = "Scene 5", plain = "launch scene 5" },
	[39] = { label = "Scene 6", plain = "launch scene 6" },
	[29] = { label = "Scene 7", plain = "launch scene 7" },
	[19] = { label = "Mixer", plain = "open/close the MIXER menu (grid)" },
}

-- MIXER menu geometry, top row first (row 0 = grid notes 81-88). Rows 2-7 are the
-- per-track-column actions (they follow the clip window); all six are exposed at
-- the same time: record, stop, mute, solo, arm, select. Exposed for the manual.
local MIXER = {
	{ row = 0, label = "Pages (global, not per track)", items = { "Volume (cyan tint)", "Pan (magenta tint)", "Send — cycles 1-4 on the arrows (tint follows the send)", "Tempo page (white)", "Swing page (yellow)", "Q-Link page (blue tint)", "Tap tempo (grey)", "Click — cyan while the metronome runs" } },
	{ row = 1, label = "Transport (global, not per track)", items = { "Play (green playing, orange loop armed)", "Record (red)", "Stop (stop; stop again = return to zero)" } },
	{ row = 2, label = "Record (blue; red while recording, dim red armed)", perTrack = true },
	{ row = 3, label = "Stop clips (grey)", perTrack = true },
	{ row = 4, label = "Mute (orange)", perTrack = true },
	{ row = 5, label = "Solo (yellow)", perTrack = true },
	{ row = 6, label = "Record arm (red)", perTrack = true },
	{ row = 7, label = "Select track (track colour, white = current)", perTrack = true },
}

-- Internal keys for the two fixed strips (row -> col 0-7 -> action key).
local MIX_STRIP_KEYS = {
	[0] = { "volume", "pan", "send", "tempo", "swing", "qlink", "tap", "click" },
	[1] = { "play", "record", "stop" },
}

-- Clip state enum (order confirmed by the stock MPK script and mpc-3-ce Gen1 enum)
local S = {
	NoSlot = 0,
	Empty = 1,
	Ready = 2,
	WillPlay = 3,
	Playing = 4,
	WillStopPlaying = 5,
	WillRecord = 6,
	Recording = 7,
	WillStopRecording = 8,
	WillOverdub = 9,
	Overdubbing = 10,
	WillStopOverdubbing = 11,
}

-- LED colours (RGB 0-127)
local C = {
	off = { 0, 0, 0 },
	dim = { 12, 12, 12 },
	available = { 60, 60, 60 },
	white = { 127, 127, 127 },
	green = { 0, 127, 0 },
	red = { 127, 0, 0 },
	orange = { 127, 60, 0 },
	blue = { 0, 60, 127 },
	cyan = { 0, 127, 127 },
	magenta = { 127, 0, 127 },
	yellow = { 127, 127, 0 },
}

-- Volume fader steps, bottom (row 7) to top (row 0), in dB.
-- -inf is sent as a very low dB so the MPC shows -inf.
local VOLUME_DB = { [7] = -100, [6] = -30, [5] = -20, [4] = -9, [3] = -3, [2] = 0, [1] = 3, [0] = 6 }

-- One colour per send so Send 1-4 are distinguishable.
local SEND_COLOURS = { C.yellow, C.green, C.blue, C.orange }

-- Idle tints for the mixer's per-track rows: each row keeps a low but visible
-- hint of its active colour, so the rows identify themselves without labels.
local DIM_RED = { 30, 0, 0 }
local DIM_YELLOW = { 22, 22, 0 }
local DIM_ORANGE = { 35, 16, 0 }
-- Idle tints for the mixer's pages strip (row 0): same rule — dim tint says
-- what the pad IS, bright says it is ON. A solid bright colour on an idle pad
-- reads as "active", which the device feedback showed as confusing.
local DIM_CYAN = { 0, 22, 22 }
local DIM_MAGENTA = { 22, 0, 22 }
local DIM_TEMPO = { 20, 20, 20 }
local DIM_QLINK = { 10, 0, 30 }
local DIM_SEND = { { 22, 22, 0 }, { 0, 22, 0 }, { 0, 0, 22 }, { 22, 10, 0 } }

-- State
local aperture, clipProps
local originCol, originRow = 0, 0
local padCache = {} -- LED index -> "r,g,b" last sent
local ledSpecs = {} -- accumulated specs for the current flush
local ticks = 0
local blinkOn = false
local adjustMode = nil -- nil / "volume" / "pan" / "sends" (menu mode)
local adjustSend = 1 -- 1..4, the active send in sends mode
local adjustCol = 0 -- last grid column touched in the menu (for up/down nudges)
local lastPadCol, lastPadRow, lastPadTick = nil, nil, -100
local tempoMode = false -- tempo page: up/down change BPM
local tempoHold = nil -- TOP.up / TOP.down while held (auto-repeat)
local tempoHoldTicks = 0 -- ticks since the tempo button was pressed
local swingMode = false -- swing page: up/down change swing
local swingHold = nil -- TOP.up / TOP.down while held (auto-repeat)
local swingHoldTicks = 0 -- ticks since the swing button was pressed
local qlinkMode = false -- CC98 user page: Q-Link faders (Twist-driven)
local qlinkPage = 0 -- 0 = Q-Links 0-7, 1 = Q-Links 8-15
local qlinkCol = 0 -- last grid column touched (for Shift+up/down nudges)
local padsMode = false -- CC96 MPC pads mode: the grid quadrant mirrors mpc.controlSurface.pads
local padsColourCache = {} -- pad index -> ARGB int last sent (diff-only mirror)
local tapTicks = {} -- recent tap-tempo tick timestamps (50 ms per tick)
local padsLayout = "drum" -- CC 96 mode layout: drum (4x4 bank A) or pads64 (all four banks)
local padsSwitched = false -- Drums pressed once in-mode: the layout flipped, next press exits
local keysPage = false -- Keys (CC 97) opened the keys page with pads mode
local keysPP = false -- we engaged the MPC's Pad Perform mode (melodic tracks only)
local trackIsMelodicFn = function()
	return false
end -- forward declaration; redefined next to firstLayoutForTrack

-- The Pad Perform page may stay open ONLY while the keys page owns the surface
-- AND the current track is melodic (device rule). Anything else sweeps it.
local function padPerformPageOurs()
	return keysPage and keysPP and trackIsMelodicFn()
end
local boundPadNotes = {} -- grid notes currently routed away from the script
local chromaticVirtualPad -- forward declaration (defined with the pad-mode helpers)
local mixerMode = false -- CC19 MIXER menu owns the grid
local priorMode, priorLayout = nil, nil -- captured from the readback replies
local priorFeedback = nil -- { internal, external } captured before we change it
local programmerEntered = false
local modeQuerySent = false
local lastLog = {}

-----------------------------------------------------------------------------------------------
-- Utilities
-----------------------------------------------------------------------------------------------

local H = {}

function H.log(msg)
	pcall(function()
		print(deviceName .. ": " .. tostring(msg))
	end)
end

function H.logOnce(key, msg)
	if lastLog[key] then
		return
	end
	lastLog[key] = true
	H.log(msg)
end

function H.call(f, ...)
	if type(f) ~= "function" then
		return nil
	end
	local ok, r = pcall(f, ...)
	if ok then
		return r
	end
	return nil
end

function H.propValue(obj, name)
	local p = obj and obj[name]
	if p == nil then
		return nil
	end
	local ok, v = pcall(function()
		return p.value
	end)
	if ok then
		return v
	end
	return nil
end

-- Boolean view of a property value. MPC state properties such as RecordState
-- are numbers (0 = off), and Lua treats 0 as true — never test them directly.
function H.truthy(v)
	return v ~= nil and v ~= false and v ~= 0
end

-- Safe accessor: the member when it exists with the expected type, else nil.
-- mpc.* objects are sol2 tables/userdata; a missing build field must never raise.
function H.member(obj, key, kind)
	if obj == nil then
		return nil
	end
	local v = obj[key]
	if v ~= nil and (kind == nil or type(v) == kind) then
		return v
	end
	return nil
end

-- Shorthand for H.member(obj, key, "function"): the callable, or nil.
function H.callable(obj, key)
	return H.member(obj, key, "function")
end

-- Call currentTrack.<field>() with a one-time log when the build lacks it.
-- Returns true when the action ran.
function H.trackAction(field, logKey, label)
	local ct = mpc.tracks and mpc.tracks.currentTrack
	local f = H.callable(ct, field)
	if not f then
		H.logOnce(logKey, label .. " unavailable: currentTrack." .. field .. " missing")
		return false
	end
	H.call(f)
	return true
end

-- Is a project loaded? Several independent indicators, because no single one is
-- reliable: an empty project legitimately has 0 tracks, so the track count is
-- NOT an indicator. The MPC's native side dereferences project state and can
-- crash hard (a native abort that pcall cannot catch), so this guard is
-- preventive. Any one positive indicator counts as "loaded" — a false positive
-- only re-enables an action, a false negative would disable a working one.
-- Name of the current popup: "No Popup" (or empty) when none is open — the MPC
-- binary documents the property as "The name of the current popup, or empty if
-- there is no popup". Project-scoped native actions crash while a dialog owns
-- the UI (e.g. the New Project page), so an open popup blocks them.
function H.currentPopup()
	local em = mpc.engineMode
	local p = H.propValue(em, "CurrentPopup")
	if p == nil then
		p = H.call(H.callable(em, "GetCurrentPopup"))
	end
	return tostring(p or "")
end

function H.popupOpen()
	local p = H.currentPopup()
	if p == "" or p == "No Popup" then
		return false
	end
	-- The keys page's own Pad Perform page is not a blocking dialog while the
	-- keys page owns the surface AND the track is melodic: leaving it open is
	-- the feature (chord settings on screen). Any other state sweeps it away.
	if padPerformPageOurs() and p == "Pad Perform" then
		return false
	end
	return true
end

function H.projectLoaded()
	if H.popupOpen() then
		return false
	end
	if mpc.currentSequence ~= nil then
		return true
	end
	local tracks = mpc.tracks
	if tracks ~= nil and tracks.currentTrack ~= nil then
		return true
	end
	local bpm = H.call(H.callable(mpc.sequencer, "GetBPM"))
	if type(bpm) == "number" and bpm > 0 then
		return true
	end
	return false
end

-- Guard for project-scoped actions: true when safe to run, else a one-time log.
function H.requireProject(label)
	if H.projectLoaded() then
		return true
	end
	if H.popupOpen() then
		H.logOnce(label .. "-popup", label .. ": dialog open (" .. H.currentPopup() .. ")")
	else
		H.logOnce(label .. "-noproject", label .. ": no project loaded")
	end
	return false
end

function H.clamp01(v)
	v = tonumber(v) or 0
	if v < 0 then
		return 0
	elseif v > 1 then
		return 1
	end
	return v
end

-- Nearest volume-fader row (0 = top, 7 = bottom) for a dB value.
function H.dbToRow(db)
	db = tonumber(db)
	if db == nil or db <= -60 then
		return 7
	elseif db <= -25 then
		return 6
	elseif db <= -14.5 then
		return 5
	elseif db <= -6 then
		return 4
	elseif db <= -1.5 then
		return 3
	elseif db <= 1.5 then
		return 2
	elseif db <= 4.5 then
		return 1
	end
	return 0
end

-- MPC volume fader curve, measured on 3.10.1: dB = 40*log10(gain) + 6.
-- Inverse: gain = 10^((dB - 6) / 40); -inf is gain 0.
function H.dbToGain(db)
	db = tonumber(db)
	if db == nil or db <= -60 then
		return 0
	end
	return 10 ^ ((db - 6) / 40)
end

function H.gainToDb(gain)
	gain = tonumber(gain)
	if gain == nil or gain <= 0 then
		return -100
	end
	return 40 * math.log(gain, 10) + 6
end

function H.trackAt(idx)
	return mpc.tracks and mpc.tracks.normalTracks and mpc.tracks.normalTracks[idx]
end

function H.adjustPropName()
	if adjustMode == "volume" then
		return "Volume"
	elseif adjustMode == "pan" then
		return "Pan"
	elseif adjustMode == "sends" then
		return "Send" .. adjustSend
	end
	return nil
end

-- Page colour for the active fader menu (also used by the arrows).
function H.adjustColour()
	if adjustMode == "pan" then
		return C.magenta
	elseif adjustMode == "sends" then
		return SEND_COLOURS[adjustSend] or C.yellow
	end
	return C.cyan
end

function H.argb(c)
	c = tonumber(c) or 0
	return math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256
end

function H.scale7(v)
	v = tonumber(v) or 0
	if v < 0 then
		v = 0
	elseif v > 255 then
		v = 255
	end
	return math.floor(v * 127 / 255)
end

function H.rgbKey(r, g, b)
	return r .. "," .. g .. "," .. b
end

-- Global matrix position of a window cell
function H.globalPos(col, row)
	if aperture then
		local gc = H.call(aperture.ToGlobalColumn, col)
		local gr = H.call(aperture.ToGlobalRow, row)
		if type(gc) == "number" and type(gr) == "number" then
			return gc, gr
		end
	end
	return col + (originCol or 0), row + (originRow or 0)
end

-- Clip status: 0 = no clip, 1 = stopped, 2 = playing/recording, 3 = queued
local function clipStatus(col, row)
	local m = mpc.clipMatrix
	if not (m and m.HasClip) then
		return 0
	end
	local gc, gr = H.globalPos(col, row)
	local has = H.call(m.HasClip, gc, gr)
	if not has then
		return 0, gc, gr
	end
	if H.call(m.ClipIsPlaying, gc, gr) or H.call(m.ClipIsRecording, gc, gr) then
		return 2, gc, gr
	end
	if H.call(m.ClipIsStopped, gc, gr) then
		return 1, gc, gr
	end
	return 3, gc, gr
end

local function clipColour(col, row)
	local p = clipProps and clipProps[col] and clipProps[col][row]
	local c = H.propValue(p, "Colour")
	if type(c) == "number" and c ~= 0 then
		return c
	end
	local m = mpc.clipMatrix
	if m and m.GetClipColour then
		local gc, gr = H.globalPos(col, row)
		local v = H.call(m.GetClipColour, gc, gr)
		if type(v) == "number" then
			return v
		end
	end
	return 0x808080
end

-----------------------------------------------------------------------------------------------
-- LED output
-----------------------------------------------------------------------------------------------

local function addSpec(spec)
	ledSpecs[#ledSpecs + 1] = spec
end

local function ledRGB(index, r, g, b)
	index = tonumber(index)
	if not index then
		return
	end
	r, g, b = math.floor(tonumber(r) or 0), math.floor(tonumber(g) or 0), math.floor(tonumber(b) or 0)
	if r < 0 then
		r = 0
	elseif r > 127 then
		r = 127
	end
	if g < 0 then
		g = 0
	elseif g > 127 then
		g = 127
	end
	if b < 0 then
		b = 0
	elseif b > 127 then
		b = 127
	end
	local key = H.rgbKey(r, g, b)
	if padCache[index] == key then
		return
	end
	padCache[index] = key
	addSpec(string.char(3, index % 128, r, g, b))
end

-- Paint one button with a {r,g,b} colour table from C (the palette above).
local function ledCol(index, colour)
	ledRGB(index, colour[1], colour[2], colour[3])
end

local function ledOff(index)
	ledRGB(index, 0, 0, 0)
end

local function flushLEDs()
	if #ledSpecs == 0 then
		return
	end
	local header = string.char(0x00, 0x20, 0x29, 0x02, 0x0D, 0x03)
	-- the LPMiniMK3 accepts up to 81 specs per message (exactly the whole surface);
	-- chunk larger flushes rather than dropping or truncating
	local ok = pcall(function()
		if #ledSpecs <= SYSEX_MAX_SPECS then
			dev.midiOut.SendMIDISysex(header .. table.concat(ledSpecs), port)
		else
			local i = 1
			while i <= #ledSpecs do
				local chunk = {}
				local n = 0
				while i <= #ledSpecs and n < SYSEX_MAX_SPECS do
					n = n + 1
					chunk[n] = ledSpecs[i]
					i = i + 1
				end
				dev.midiOut.SendMIDISysex(header .. table.concat(chunk), port)
			end
		end
	end)
	if not ok then
		H.logOnce("sysex", "SendMIDISysex failed")
	end
	ledSpecs = {}
end

-- LPMiniMK3 mode/layout control (programmer's reference pp.7-8):
--   00 <layout>  select layout (00 session DAW-only, 04-06 custom 1-3, 0D DAW faders, 7F programmer)
--   0E <mode>    0 = Live mode, 1 = Programmer mode (the dedicated switch)
--   0A <i> <e>   LED feedback config (internal, external)
-- Readback variants (command byte only) let the script capture the prior state.
local function sendMini(command, ...)
	local payload = { string.char(0x00, 0x20, 0x29, 0x02, 0x0D, command) }
	for _, b in ipairs({ ... }) do
		payload[#payload + 1] = string.char(b)
	end
	local ok = pcall(function()
		dev.midiOut.SendMIDISysex(table.concat(payload), port)
	end)
	if not ok then
		H.logOnce("mini" .. string.format("%02x", command), "sysex 0x" .. string.format("%02x", command) .. " failed")
	end
end

local function sendMode(m)
	sendMini(0x0E, m)
end

local function sendLayout(layout)
	sendMini(0x00, layout)
end

local function sendFeedback(internal, external)
	sendMini(0x0A, internal, external)
end

local function queryState()
	sendMini(0x0E) -- mode readback
	sendMini(0x00) -- layout readback
	sendMini(0x0A) -- LED feedback readback
end

-----------------------------------------------------------------------------------------------
-- Painting: tempo / swing / fader pages
-----------------------------------------------------------------------------------------------

-- Tempo page: a 7-segment display scaled to the grid. A 3-digit BPM uses
-- 2-column digits with 1-column gaps; a 2-digit BPM uses 4-column digits with
-- no gaps, so the number is as large as the grid allows.
local SEGMENTS = {
	["0"] = { a = true, b = true, c = true, d = true, e = true, f = true, g = false },
	["1"] = { a = false, b = true, c = true, d = false, e = false, f = false, g = false },
	["2"] = { a = true, b = true, c = false, d = true, e = true, f = false, g = true },
	["3"] = { a = true, b = true, c = true, d = true, e = false, f = false, g = true },
	["4"] = { a = false, b = true, c = true, d = false, e = false, f = true, g = true },
	["5"] = { a = true, b = false, c = true, d = true, e = false, f = true, g = true },
	["6"] = { a = true, b = false, c = true, d = true, e = true, f = true, g = true },
	["7"] = { a = true, b = true, c = true, d = false, e = false, f = false, g = false },
	["8"] = { a = true, b = true, c = true, d = true, e = true, f = true, g = true },
	["9"] = { a = true, b = true, c = true, d = true, e = false, f = true, g = true },
}

local function tempoPad(col, row, colour)
	if col >= 0 and col < GRID_COLS and row >= 0 and row < GRID_ROWS then
		ledRGB(10 * (8 - row) + col + 1, colour[1], colour[2], colour[3])
	end
end

-- Draw one 7-segment digit in the box (x0, y0) .. (x0+w-1, y0+h-1).
local function drawDigit(ch, x0, y0, w, h, colour)
	local seg = SEGMENTS[ch]
	if not seg then
		return
	end
	local mid = math.floor(h / 2)
	if seg.a then
		for c = 0, w - 1 do
			tempoPad(x0 + c, y0, colour)
		end
	end
	if seg.d then
		for c = 0, w - 1 do
			tempoPad(x0 + c, y0 + h - 1, colour)
		end
	end
	if seg.g then
		for c = 0, w - 1 do
			tempoPad(x0 + c, y0 + mid, colour)
		end
	end
	if seg.f then
		for r = 0, mid do
			tempoPad(x0, y0 + r, colour)
		end
	end
	if seg.b then
		for r = 0, mid do
			tempoPad(x0 + w - 1, y0 + r, colour)
		end
	end
	if seg.e then
		for r = mid, h - 1 do
			tempoPad(x0, y0 + r, colour)
		end
	end
	if seg.c then
		for r = mid, h - 1 do
			tempoPad(x0 + w - 1, y0 + r, colour)
		end
	end
end

local function paintNumberGrid(value)
	value = math.max(0, math.min(999, math.floor(value)))
	for row = 0, GRID_ROWS - 1 do
		for col = 0, GRID_COLS - 1 do
			ledOff(10 * (8 - row) + col + 1)
		end
	end
	-- Left-aligned, no gaps. The hundreds digit is narrow (1 column for a
	-- leading 1, 2 columns otherwise) so the tens and ones digits get the rest
	-- of the width and show more detail.
	local text
	local widths = {}
	if value >= 100 then
		text = string.format("%3d", value)
		widths[1] = (text:sub(1, 1) == "1") and 1 or 2
		local remaining = GRID_COLS - widths[1]
		widths[2] = math.floor(remaining / 2)
		widths[3] = remaining - widths[2]
	else
		text = string.format("%2d", value)
		widths[1] = 4
		widths[2] = 4
	end
	-- colour by position from the right: ones white (brightest), tens orange,
	-- hundreds blue. Blue/orange/white differ in both hue and luminance, so the
	-- digits stay distinct for red-green colourblindness (the common type).
	local colours = { C.white, C.orange, C.blue }
	local x0 = 0
	for i = 1, #text do
		drawDigit(text:sub(i, i), x0, 0, widths[i], GRID_ROWS, colours[#text - i + 1])
		x0 = x0 + widths[i]
	end
end

local function paintTempoGrid()
	local bpm = math.floor(H.call(mpc.sequencer and mpc.sequencer.GetBPM) or 120)
	paintNumberGrid(bpm)
end

local function paintSwingGrid()
	local q = mpc.sequencer and mpc.sequencer.quantiser
	-- MPC swing: 50% = straight, 75% = max; clamp the display into the range
	local swing = math.floor(H.call(q and q.GetSwing) or 50)
	paintNumberGrid(math.max(50, math.min(75, swing)))
end

local function paintAdjustGrid()
	local colour = C.cyan
	if adjustMode == "pan" then
		colour = C.magenta
	elseif adjustMode == "sends" then
		colour = SEND_COLOURS[adjustSend] or C.yellow
	end
	local name = H.adjustPropName()
	local trackCount = H.call(mpc.tracks and mpc.tracks.SizeNormalTracks) or GRID_COLS
	for col = 0, GRID_COLS - 1 do
		local gc = H.globalPos(col, 0)
		local t = H.trackAt(gc)
		if t and gc < trackCount then
			local litCount
			if adjustMode == "volume" then
				-- dB fader: -inf = no pads, +6 dB = all 8 pads
				local gain = H.propValue(t, "Volume")
				local db = H.gainToDb(gain)
				local row = H.dbToRow(db)
				litCount = (db <= -60) and 0 or (GRID_ROWS - row)
			else
				local value = H.propValue(t, name) or 0
				if type(value) ~= "number" then
					value = 0
				end
				litCount = math.floor(value * GRID_ROWS + 0.5)
			end
			for row = 0, GRID_ROWS - 1 do
				local idx = 10 * (8 - row) + col + 1
				local fromBottom = 7 - row
				if fromBottom < litCount then
					ledCol(idx, colour)
				else
					ledCol(idx, C.dim)
				end
			end
		else
			for row = 0, GRID_ROWS - 1 do
				ledOff(10 * (8 - row) + col + 1)
			end
		end
	end
end

-----------------------------------------------------------------------------------------------
-- Q-Link page (CC 98 user). SetPosition updates the ValueString but does not reach the
-- MPC edit-mode value on 3.10.1, so changes are driven with Twist (rotate by delta) instead.
-----------------------------------------------------------------------------------------------

local paintAll -- forward declaration (defined below)
local exitPadsMode -- forward declaration (defined with the pad-mode helpers)
local closeGridStates -- forward declaration (defined with the pad-mode helpers)

local function qlinkAt(i)
	local cs = mpc.controlSurface
	local ql = cs and cs.qlinks
	if not ql then
		return nil
	end
	return ql[i]
end

local function qlinkCount()
	local cs = mpc.controlSurface
	local ql = cs and cs.qlinks
	if not ql then
		return 0
	end
	return H.call(ql.GetNumQLinks) or 0
end

local function qlinkPosition(i)
	local q = qlinkAt(i)
	if not q then
		return 0
	end
	return H.call(q.GetPosition) or 0
end

-- Touch() signature is unknown on 3.10.1: try it with no args, ignore any error.
local function touchQlink(q)
	if q and type(q.Touch) == "function" then
		pcall(q.Touch)
	end
end

-- Drive qlink i to pos: Twist(target - GetPosition()), clamped to +-127, repeated at most
-- twice to absorb the GetPosition lag; falls back to SetPosition when Twist is missing.
local qlinkTargetLogged = {} -- page-open diagnosis: one line per qlink
-- The 16 Q-Links are the MPC's four Q-Link banks (4 knobs each); each bank gets its
-- own fader colour so the groups are visually distinct on the grid.
local QLINK_BANK_COLOURS = { C.cyan, C.magenta, C.yellow, C.blue }
-- Flip/binary params (e.g. Kill EQ Thru/Kill) show the same value string for many
-- positions and only two strings overall; once learned, presses round to 0/127 and
-- the column shows a single lit extreme pad instead of a fill.
local qlinkFlip = {}
local qlinkSeenStrings = {} -- i -> set of distinct value strings observed
local qlinkSeenPos = {} -- i -> { min = , max = }

local function qlinkTargetName(i)
	local q = qlinkAt(i)
	local name = H.call(q and q.GetTargetName)
	if type(name) ~= "string" then
		name = H.propValue(q, "TargetName")
	end
	return type(name) == "string" and name or ""
end

-- Drive qlink i to pos. Twist is primary (a real knob rotation); SetValue (the target's
-- un-normalised value) is the second attempt when Twist does not move the target;
-- SetPosition only syncs the knob position display and is the last resort.
local function setQlinkPosition(i, pos)
	local q = qlinkAt(i)
	if not q then
		return
	end
	if not qlinkTargetLogged[i] then
		qlinkTargetLogged[i] = true
		H.log(string.format("qlink %d target '%s'", i, qlinkTargetName(i)))
	end
	local before = H.call(q.GetValueString)
	local posBefore = H.call(q.GetPosition) or 0
	touchQlink(q)
	if type(q.Twist) == "function" then
		for _ = 1, 2 do
			local delta = pos - (H.call(q.GetPosition) or 0)
			if delta == 0 then
				break
			end
			if delta > 127 then
				delta = 127
			elseif delta < -127 then
				delta = -127
			end
			H.call(q.Twist, delta)
		end
	end
	local afterTwist = H.call(q.GetValueString)
	if afterTwist == before and type(q.SetValue) == "function" then
		-- Twist did not change the target value: try the target value directly.
		-- GetValue() is the current un-normalised value; scale by the position change.
		local v = H.call(q.GetValue)
		if type(v) == "number" and posBefore ~= 0 then
			H.call(q.SetValue, v * pos / posBefore)
		end
		H.call(q.SetPosition, pos)
	elseif type(q.SetPosition) == "function" then
		H.call(q.SetPosition, pos) -- keep the knob position in sync with the target
	end
	touchQlink(q)
	local str = tostring(H.call(q.GetValueString) or "")
	H.log(string.format("qlink %d = %d (%s)", i, pos, str))
	-- flip learning: remember distinct value strings and the position span; two distinct
	-- strings across a wide span means the parameter is binary (round to extremes)
	if str ~= "" then
		local seen = qlinkSeenStrings[i]
		if not seen then
			seen = {}
			qlinkSeenStrings[i] = seen
		end
		seen[str] = true
		local span = qlinkSeenPos[i]
		if not span then
			span = { min = pos, max = pos }
			qlinkSeenPos[i] = span
		else
			if pos < span.min then
				span.min = pos
			end
			if pos > span.max then
				span.max = pos
			end
		end
		local n = 0
		for _ in pairs(seen) do
			n = n + 1
		end
		if n == 2 and span.max - span.min >= 48 and not qlinkFlip[i] then
			qlinkFlip[i] = true
			H.log(string.format("qlink %d flip parameter", i))
		end
	end
end

-- A qlink with an empty target name is unassigned in the current Q-Link mode: its
-- column stays fully dark so the grid only shows faders that control something.
--
-- The MPC's DEFAULT Q-Link pages are global sequencer SELECTORS, not faders
-- (device journal: SEQUENCE TEMPO, CURRENT TRACK, TIME DIVISION, TRACK LEVEL,
-- SEQUENCE LENGTH, REC ARM, SWING, PLAYHEAD). A fader pad jumps its qlink to an
-- absolute position, which for those means: current track switches mid-play
-- (the "random triggers" report), sequence length slams to thousands of bars,
-- tempo to 513 BPM, record arms itself. They are blocked from the page: dark
-- column, inert pad. TRACK LEVEL stays (a real fader), and anything you assign
-- yourself in the MPC's Q-Link edit mode (plugin/mixer parameters) passes.
local QLINK_BLOCKED_TARGETS = {
	["SEQUENCE TEMPO"] = true, -- dedicated tempo page (arrows, repeat)
	["CURRENT TRACK"] = true,
	["TIME DIVISION"] = true,
	["SEQUENCE LENGTH"] = true,
	["REC ARM"] = true,
	["SWING"] = true, -- dedicated swing page
	["PLAYHEAD"] = true,
}

local function qlinkAssigned(i)
	local name = qlinkTargetName(i)
	return name ~= "" and not QLINK_BLOCKED_TARGETS[string.upper(name)]
end

local function qlinkColour(i)
	return QLINK_BANK_COLOURS[math.floor(i / 4) + 1] or C.cyan
end

-- Columns show the ASSIGNED Q-Links at FIXED slot positions: columns 1-4 are always
-- the MPC's page 1 slots (12,8,4,0) and columns 5-8 its page 2 slots (13,9,5,1), one
-- column per slot — no compaction, no sliding. An unassigned slot keeps its column as
-- a dark gap exactly where the MPC screen shows it (device-verified on the Pro build:
-- the user's page 1 reads unmapped, High, Mid, Low).
local QLINK_PAGE_GROUPS = {
	[0] = { { 12, 8, 4, 0 }, { 13, 9, 5, 1 } }, -- MPC pages 1+2
	[1] = { { 14, 10, 6, 2 }, { 15, 11, 7, 3 } }, -- MPC pages 3+4
}
local qlinkColumnMap = {}

local function buildQlinkColumnMap(page)
	qlinkColumnMap = {}
	local count = qlinkCount()
	local groups = QLINK_PAGE_GROUPS[page or qlinkPage] or QLINK_PAGE_GROUPS[0]
	for g = 1, 2 do
		for rank, i in ipairs(groups[g]) do
			if i < count and qlinkAssigned(i) then
				qlinkColumnMap[4 * (g - 1) + rank - 1] = i
			end
		end
	end
end

local function qlinkForColumn(col)
	return qlinkColumnMap[col]
end

local function qlinkPageHasContent(page)
	local count = qlinkCount()
	for _, group in ipairs(QLINK_PAGE_GROUPS[page]) do
		for _, i in ipairs(group) do
			if i < count and qlinkAssigned(i) then
				return true
			end
		end
	end
	return false
end

local function paintQlinkGrid()
	buildQlinkColumnMap()
	for col = 0, GRID_COLS - 1 do
		local i = qlinkForColumn(col)
		local assigned = i ~= nil
		local pos = assigned and qlinkPosition(i) or 0
		local colour = qlinkColour(i or 0)
		local litCount = math.floor(pos / 127 * GRID_ROWS + 0.5)
		for row = 0, GRID_ROWS - 1 do
			local idx = 10 * (8 - row) + col + 1
			local fromBottom = 7 - row
			if not assigned then
				ledOff(idx)
			elseif qlinkFlip[i] then
				-- binary parameter: only the matching extreme pad is lit (top = max)
				if (pos >= 64 and row == 0) or (pos < 64 and row == GRID_ROWS - 1) then
					ledCol(idx, colour)
				else
					ledCol(idx, C.dim)
				end
			elseif fromBottom < litCount then
				ledCol(idx, colour)
			else
				ledCol(idx, C.dim)
			end
		end
	end
end

local function handleQlinkPad(col, row)
	buildQlinkColumnMap()
	local i = qlinkForColumn(col)
	if i == nil then
		return
	end
	local target
	if qlinkFlip[i] then
		-- binary parameter: bottom half of the column = min extreme, top half = max
		target = (row < GRID_ROWS / 2) and 127 or 0
	else
		target = math.floor((GRID_ROWS - row) / GRID_ROWS * 127 + 0.5)
	end
	setQlinkPosition(i, target)
	qlinkCol = col
	paintAll()
end

local function enterQlink()
	if not H.requireProject("qlink page") then
		return
	end
	local cs = mpc.controlSurface
	if not (cs and cs.qlinks) then
		H.logOnce("noqlinks", "qlink page unavailable: controlSurface.qlinks missing")
		return
	end
	exitPadsMode() -- the Q-Link page needs the whole grid: any pads-mode note
	-- bindings (quadrant/64 pads) are handed back to the script, or the bound
	-- notes keep PLAYING the MPC pads through the page
	closeGridStates() -- one canonical "close every other page" list
	qlinkMode = true
	qlinkPage = 0
	qlinkCol = 0
	qlinkTargetLogged = {}
	qlinkFlip = {}
	qlinkSeenStrings = {}
	qlinkSeenPos = {}
	buildQlinkColumnMap(0)
	local map = {}
	local assignedCount = 0
	for c = 0, GRID_COLS - 1 do
		local i = qlinkColumnMap[c]
		if i then
			assignedCount = assignedCount + 1
			map[#map + 1] = (c + 1) .. "=" .. qlinkTargetName(i)
		else
			map[#map + 1] = (c + 1) .. "=-"
		end
	end
	H.log("qlink page (" .. assignedCount .. " assigned): " .. table.concat(map, ", "))
	paintAll()
end
local function exitQlink()
	qlinkMode = false
	H.log("qlink page off")
	paintAll()
end

-- User button / mixer qlink pad share this: page 1 -> page 2 (when page 2 has
-- content) -> off. One helper so the two paths can never drift apart.
local function cycleQlinkPage()
	if qlinkMode then
		if qlinkPage == 0 and qlinkPageHasContent(1) then
			qlinkPage = 1
			H.log("qlink page 2")
			paintAll()
		else
			exitQlink()
		end
	else
		enterQlink()
	end
end

-----------------------------------------------------------------------------------------------
-- Clip / pads / mixer painting
-----------------------------------------------------------------------------------------------

-- Clip states that blink: the MPK's fast set (transitions); other states > 3
-- (playing/recording/overdubbing) blink slowly. RGB pads have no blink channel
-- in the sysex we use, so blinking repaints the pad dim on the timer phase:
-- fast = the 2 Hz blinkOn, slow = 1 Hz via ticks.
local CLIP_BLINK_FAST = { [3] = true, [5] = true, [6] = true, [8] = true, [9] = true, [11] = true }

local function blinkPhase(fast)
	if fast then
		return blinkOn
	end
	return ticks % 10 < 5
end

-- One clip slot from its live property State (MPK semantics, device-verified):
-- < 2 empty, 2 = stopped (the clip's Colour, alpha ignored), 3-5 = playing or
-- queued (green), >= 6 = recording (red). Selected empty slots light dim white
-- (ring substitute). Returns false when the slot has no State property, so the
-- caller falls back to polling clipMatrix for that pad.
local function paintClipSlot(col, row)
	local p = clipProps and clipProps[col] and clipProps[col][row]
	local state = tonumber(H.propValue(p, "State"))
	if state == nil then
		return false
	end
	local idx = 10 * (8 - row) + col + 1
	if state < 2 then
		if H.propValue(p, "Selected") == true then
			ledCol(idx, C.available)
		else
			ledOff(idx)
		end
		return true
	end
	local r, g, b
	if state >= 6 then
		r, g, b = C.red[1], C.red[2], C.red[3]
	elseif state >= 3 then
		r, g, b = C.green[1], C.green[2], C.green[3]
	else
		r, g, b = H.argb(clipColour(col, row))
	end
	if state >= 3 and not blinkPhase(CLIP_BLINK_FAST[state]) then
		r, g, b = H.scale7(r * 0.18), H.scale7(g * 0.18), H.scale7(b * 0.18)
	end
	ledRGB(idx, r, g, b)
	return true
end

-- Pads mode grid: the bottom-left 4x4 quadrant mirrors mpc.controlSurface.pads[i].Colour
-- (ARGB int, alpha ignored); the rest of the grid is dark. poll=true re-reads the pad
-- colours; padsColourCache keeps the last ARGB per pad so only diffs are sent.
-- 64-pads layout LEDs: every pad mirrors its MPC colour from controlSurface.pads.virtual
-- (128 virtual pads; they read 0 until a program is loaded). Pads with no colour keep
-- a dim blue tint so the grid shape stays visible.
local function paintChromaticGrid()
	local cs = mpc.controlSurface
	local pads = cs and cs.pads
	local virt = pads and pads.virtual
	for padRow = 0, 7 do
		for col = 0, 7 do
			local idx = 10 * (padRow + 1) + col + 1
			local i = padRow * 8 + col
			local p = (virt and virt[i]) or (pads and pads[i])
			local v = H.call(p and p.GetColour)
			if type(v) ~= "number" then
				v = H.propValue(p, "Colour")
			end
			if type(v) == "number" and v ~= 0 and v ~= -16777216 then
				local r, g, b = H.argb(v)
				ledRGB(idx, H.scale7(r), H.scale7(g), H.scale7(b))
			else
				ledRGB(idx, 0, 15, 30)
			end
		end
	end
end

local function paintPadsGrid(poll)
	if padsLayout == "pads64" then
		paintChromaticGrid()
		return
	end
	local quadrant = {}
	for i = 0, 15 do
		quadrant[10 * (math.floor(i / 4) + 1) + (i % 4) + 1] = true
	end
	-- the rest of the grid stays dark; the quadrant pads are painted below
	for row = 0, GRID_ROWS - 1 do
		for col = 0, GRID_COLS - 1 do
			local idx = 10 * (8 - row) + col + 1
			if not quadrant[idx] then
				ledOff(idx)
			end
		end
	end
	local pads = mpc.controlSurface and mpc.controlSurface.pads
	for i = 0, 15 do
		local idx = 10 * (math.floor(i / 4) + 1) + (i % 4) + 1
		if poll then
			local p = pads and pads[i]
			local v = H.call(p and p.GetColour)
			if type(v) ~= "number" then
				v = H.propValue(p, "Colour")
			end
			if v ~= padsColourCache[i] then
				padsColourCache[i] = v
				local r, g, b = H.argb(v)
				ledRGB(idx, H.scale7(r), H.scale7(g), H.scale7(b))
			end
		elseif type(padsColourCache[i]) == "number" then
			local r, g, b = H.argb(padsColourCache[i])
			ledRGB(idx, H.scale7(r), H.scale7(g), H.scale7(b))
		end
	end
end

-- MIXER menu (CC 19): the grid becomes a track-column view. All six per-track
-- functions are exposed at the same time, one row each (top to bottom):
-- record, stop clips, mute, solo, arm, select — each row spans the 8 window
-- columns, so every pad lines up under its track's clip column. Two fixed
-- strips on top carry pages/utilities (row 0) and transport/clip-editing
-- (row 1). LEDs are state-driven: arm red / solo yellow / mute orange when
-- active, dim otherwise; the select row shows each track's colour (white for
-- the current track); the record row is bright red while the track records,
-- dim red while armed.
local function mixerNote(row, col)
	return 10 * (8 - row) + col + 1
end

local function quantiserEnabled()
	return H.truthy(H.propValue(mpc.sequencer and mpc.sequencer.quantiser, "Enabled"))
end

-- Is the track at global column gc currently recording a clip? (clipMatrix has
-- no property/listener for this, so the mixer paints poll it.)
local function trackRecording(gc)
	local m = mpc.clipMatrix
	if m and m.TrackIsRecording then
		local v = H.call(m.TrackIsRecording, gc)
		if v ~= nil then
			return v
		end
	end
	return false
end

local function paintMixerGrid()
	local sq = mpc.sequencer
	local playing = H.truthy(sq and H.call(sq.IsPlaying) or H.propValue(sq, "Playing"))
	local recording = H.truthy(H.propValue(sq, "RecordState"))
	local overdub = H.truthy(H.propValue(sq, "OverdubState"))
	local loop = H.truthy(H.propValue(sq, "Loop"))
	local metronome = H.truthy(H.propValue(sq, "MetronomeEnabled"))
	local projectOn = H.projectLoaded()
	local trackCount = H.call(mpc.tracks and mpc.tracks.SizeNormalTracks) or GRID_COLS
	local ct = mpc.tracks and mpc.tracks.currentTrack
	local currentIdx = tonumber(H.propValue(ct, "Index"))

	-- rows 0-1: the fixed strips
	for row = 0, 1 do
		for col = 0, GRID_COLS - 1 do
			local key = MIX_STRIP_KEYS[row][col + 1]
			local colour = C.off
			if projectOn then
				if key == "play" then
					colour = (playing and C.green) or (loop and C.orange) or C.available
				elseif key == "record" then
					colour = (recording and C.red) or (overdub and C.orange) or C.available
				elseif key == "stop" then
					colour = C.available
				elseif key == "tap" then
					colour = C.available
				elseif key == "click" then
					colour = metronome and C.cyan or C.available
				elseif key == "volume" then
					colour = (adjustMode == "volume") and C.white or DIM_CYAN
				elseif key == "pan" then
					colour = (adjustMode == "pan") and C.white or DIM_MAGENTA
				elseif key == "send" then
					if adjustMode == "sends" then
						colour = C.white
					else
						colour = DIM_SEND[adjustSend] or DIM_SEND[1]
					end
				elseif key == "tempo" then
					colour = tempoMode and C.white or DIM_TEMPO
				elseif key == "swing" then
					colour = swingMode and C.yellow or DIM_YELLOW
				elseif key == "qlink" then
					colour = qlinkMode and C.white or DIM_QLINK
				end
			end
			ledCol(mixerNote(row, col), colour)
		end
	end

	-- rows 2-7: the per-track-column rows. Each row has its OWN idle tint so the
	-- rows are distinguishable at a glance, not four rows of identical grey:
	--   record = dark blue (red while recording, dim red while armed)
	--   stop   = neutral grey
	--   mute   = dark orange (bright orange when muted)
	--   solo   = dark yellow (bright yellow when soloed)
	--   arm    = dark red (bright red when armed)
	--   select = the track's colour (white on the current track)
	for col = 0, GRID_COLS - 1 do
		local gc = H.globalPos(col, 0)
		local t = H.trackAt(gc)
		local hasTrack = (t ~= nil) and gc < trackCount
		local armed = hasTrack and H.truthy(H.propValue(t, "RecArm"))
		-- row 2: record
		if hasTrack and trackRecording(gc) then
			ledCol(mixerNote(2, col), C.red)
		elseif armed then
			ledRGB(mixerNote(2, col), 60, 0, 0)
		elseif hasTrack then
			ledRGB(mixerNote(2, col), 0, 0, 45)
		else
			ledCol(mixerNote(2, col), C.off)
		end
		-- row 3: stop clips
		ledCol(mixerNote(3, col), hasTrack and C.available or C.off)
		-- rows 4-6: mute / solo / arm
		local muteCol, soloCol, armCol = C.off, C.off, C.off
		if hasTrack then
			muteCol = H.truthy(H.propValue(t, "Mute")) and C.orange or DIM_ORANGE
			soloCol = H.truthy(H.propValue(t, "Solo")) and C.yellow or DIM_YELLOW
			armCol = armed and C.red or DIM_RED
		end
		ledCol(mixerNote(4, col), muteCol)
		ledCol(mixerNote(5, col), soloCol)
		ledCol(mixerNote(6, col), armCol)
		-- row 7: select — the track's colour, white-bright when it is current
		if hasTrack then
			if currentIdx == gc then
				ledCol(mixerNote(7, col), C.white)
			else
				local c = H.propValue(t, "Colour")
				if type(c) == "number" then
					local r, g, b = H.argb(c)
					ledRGB(mixerNote(7, col), H.scale7(r * 0.6), H.scale7(g * 0.6), H.scale7(b * 0.6))
				else
					ledCol(mixerNote(7, col), C.available)
				end
			end
		else
			ledOff(mixerNote(7, col))
		end
	end
end

local function paintGrid()
	if padsMode then
		-- mirror refresh every 2 ticks (100 ms); between refreshes repaint from the cache
		paintPadsGrid(ticks % 2 == 0)
		return
	end
	if tempoMode then
		paintTempoGrid()
		return
	end
	if swingMode then
		paintSwingGrid()
		return
	end
	if qlinkMode then
		paintQlinkGrid()
		return
	end
	if adjustMode then
		paintAdjustGrid()
		return
	end
	if mixerMode then
		paintMixerGrid()
		return
	end
	for row = 0, GRID_ROWS - 1 do
		for col = 0, GRID_COLS - 1 do
			local idx = 10 * (8 - row) + col + 1
			if not (clipProps and paintClipSlot(col, row)) then
				-- polling fallback: clipProperties missing or a slot without State
				local status = clipStatus(col, row)
				if status == 0 then
					ledOff(idx)
				else
					local c = clipColour(col, row)
					local r, g, b = H.argb(c)
					local k = 1.0
					if status == 1 then
						k = 0.18
					elseif status == 3 then
						k = blinkOn and 0.9 or 0.18
					elseif status == 2 then
						k = 0.95
					end
					ledRGB(idx, H.scale7(r * k), H.scale7(g * k), H.scale7(b * k))
				end
			end
		end
	end
end

-- Scene column: 7 buttons (the 8th position is the mixer/menu button).
local function paintScene()
	for row = 0, 6 do
		local idx = SCENE[row + 1]
		local state = nil
		if aperture and aperture.sceneProperties and aperture.sceneProperties[row] then
			state = H.propValue(aperture.sceneProperties[row], "State")
		end
		if state == S.Playing or state == S.Recording then
			ledCol(idx, C.green)
		elseif state == S.WillPlay or state == S.WillRecord then
			ledRGB(
				idx,
				blinkOn and C.green[1] or C.dim[1],
				blinkOn and C.green[2] or C.dim[2],
				blinkOn and C.green[3] or C.dim[3]
			)
		else
			ledCol(idx, C.dim)
		end
	end
end

local padsLayoutAvailable -- forward declaration (defined with the pad-mode helpers)

local function paintTop()
	local projectOn = H.projectLoaded()
	-- arrows: white while a project is loaded; while a nudge page is open they take
	-- the page colour so their extra meaning (value up/down) is visible
	local nudgeOn = adjustMode ~= nil or tempoMode or swingMode or qlinkMode
	local pageColour = tempoMode and C.white
		or (swingMode and C.yellow or (qlinkMode and qlinkColour(qlinkForColumn(0) or 0) or H.adjustColour()))
	local arrows = (not projectOn and C.off) or (nudgeOn and pageColour or C.white)
	ledCol(TOP.up, arrows)
	ledCol(TOP.down, arrows)
	ledCol(TOP.left, arrows)
	ledCol(TOP.right, arrows)
	ledCol(TOP.session, projectOn and C.white or C.off)
	local drums = C.off
	if padsMode then
		drums = (padsLayout == "pads64") and C.cyan or C.white
	elseif padsLayoutAvailable() and H.projectLoaded() then
		drums = C.available
	end
	ledCol(TOP.drums, drums)
	-- Keys opens the Pad Perform page WITH pads mode; white while that page owns
	-- the grid (press again to leave)
	local keys = (keysPage and C.white)
		or (projectOn and C.available or C.off)
	ledCol(TOP.keys, keys)
	local user = C.off
	if qlinkMode then
		user = C.white
	elseif H.projectLoaded() and mpc.controlSurface ~= nil and mpc.controlSurface.qlinks ~= nil then
		user = C.available
	end
	ledCol(TOP.user, user)
end

-- The bottom-right corner (CC 19): white while the mixer is open, red while a
-- clip op is armed, dim otherwise.
local function paintMenu()
	if mixerMode then
		ledCol(MENU, C.white)
	elseif H.projectLoaded() then
		ledCol(MENU, C.available)
	else
		ledCol(MENU, C.off)
	end
end

paintAll = function()
	paintGrid()
	paintScene()
	paintTop()
	paintMenu()
	flushLEDs()
end

-----------------------------------------------------------------------------------------------
-- Listeners
-----------------------------------------------------------------------------------------------

local listeners = {} -- every property listened to; stopped by removeListeners
local gridListeners = {} -- the current window's clip slots; rebound on window moves

local function listen(prop, fn, store)
	if prop and type(prop.listen) == "function" then
		local ok = pcall(function()
			prop:listen(fn, deviceName)
		end)
		if ok then
			local target = store or listeners
			target[#target + 1] = prop
		end
	end
end

-- Wrap a repaint so a failing listener callback can never break MPC's dispatch.
local function repaintFn(fn)
	return function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			H.logOnce("listenererror", "listener error: " .. tostring(err))
		end
	end
end

local function stopProps(props)
	for _, prop in ipairs(props) do
		if prop and type(prop.stopListening) == "function" then
			pcall(function()
				prop:stopListening(deviceName)
			end)
		end
	end
end

-- (Re-)register the 8x8 slot listeners: Colour/State/Selected -> full grid
-- repaint (MPK-style, so blink phases stay in sync). The aperture's
-- clipProperties follow the window, so every window move rebinds.
local function listenGrid()
	stopProps(gridListeners)
	gridListeners = {}
	if not clipProps then
		return
	end
	for col = 0, GRID_COLS - 1 do
		for row = 0, GRID_ROWS - 1 do
			local p = clipProps[col] and clipProps[col][row]
			if p then
				local repaint = repaintFn(function()
					paintGrid()
					flushLEDs()
				end)
				listen(p.Colour, repaint, gridListeners)
				listen(p.State, repaint, gridListeners)
				listen(p.Selected, repaint, gridListeners)
			end
		end
	end
end

-- Repaint the state-carrying surfaces (top row, menu button, and the mixer grid
-- when it is open). Used by the transport/track-property listeners.
local function repaintState()
	paintTop()
	paintMenu()
	if mixerMode then
		paintMixerGrid()
	end
	flushLEDs()
end

-- Follow MPC's current track: move the aperture window to that track's column
-- (Master matrix for the master track), then rebind the slot listeners for the
-- new window and repaint. The mixer's select row selects MPC's current track,
-- so the mixer follows track selection too.
local function followCurrentTrack(index)
	listenGrid()
	padCache = {}
	paintAll()
end

local function listenAll()
	if aperture and aperture.sceneProperties then
		for row = 0, 7 do
			local p = aperture.sceneProperties[row]
			if p then
				listen(
					p.State,
					repaintFn(function()
						paintScene()
						flushLEDs()
				end)
				)
			end
		end
	end
	local tracks = mpc.tracks and mpc.tracks.normalTracks
	if tracks then
		for i = 0, 7 do
			local t = tracks[i]
			if t then
				local repaint = repaintFn(repaintState)
				listen(t.Mute, repaint)
				listen(t.Solo, repaint)
				listen(t.RecArm, repaint)
			end
		end
	end
	local sq = mpc.sequencer
	if sq then
		local repaint = repaintFn(repaintState)
		listen(sq.Playing, repaint)
		listen(sq.RecordState, repaint)
		listen(sq.OverdubState, repaint)
		listen(sq.Loop, repaint)
		listen(sq.quantiser and sq.quantiser.Enabled, repaint)
	end
	local ct = mpc.tracks and mpc.tracks.currentTrack
	if ct then
		listen(
			ct.Index,
			repaintFn(function(newIndex)
				followCurrentTrack(newIndex)
			end)
		)
	end
	-- align the window with the current track (also registers the slot listeners)
	followCurrentTrack(H.propValue(ct, "Index"))
end

local function removeListeners()
	stopProps(gridListeners)
	gridListeners = {}
	stopProps(listeners)
	listeners = {}
end

-----------------------------------------------------------------------------------------------
-- Actions
-----------------------------------------------------------------------------------------------

-----------------------------------------------------------------------------------------------
-- Pad modes (CC 96 MPC pads)
-----------------------------------------------------------------------------------------------

-- The pad modes own the grid, so the grid-hungry states (mixer, fader menus,
-- tempo/swing pages, armed clip ops) close when one opens.
closeGridStates = function()
	adjustMode = nil
	tempoMode = false
	swingMode = false
	qlinkMode = false
	tempoHold = nil
	swingHold = nil
	mixerMode = false
	lastPadCol, lastPadRow, lastPadTick = nil, nil, -100
end

-- Grid note of a pads-mode pad: padIndex 0-15 -> the bottom-left 4x4 quadrant.
local function padsModeNote(i)
	return 10 * (math.floor(i / 4) + 1) + (i % 4) + 1
end

-- pressSurfaceButton drives the MPC's own control-surface buttons. CC 97 (keys)
-- opens the MPC's Pad Perform page — the on-screen page with the pad chord/scale
-- performance modes and their key/scale settings — via controlSurface.padPerform.

-- Try f(...) and log the failure reason: distinguishes "wrong signature"
-- from "errors on this build" for the MIDI-routing probe below.
local function try(label, f, ...)
	if type(f) ~= "function" then
		return nil, label .. ": not a function"
	end
	local ok, r = pcall(f, ...)
	if not ok then
		return nil, label .. ": " .. tostring(r)
	end
	return r
end

-- One-shot dump of every track's MIDI input routing (the receiving side of the
-- double-feed report: mappings do NOT consume notes, so whatever track listens
-- on our port plays along in EVERY mode, session included).
local midiRoutingLogged = false
local function logMidiRouting()
	if midiRoutingLogged or not H.projectLoaded() then
		return
	end
	local tr = mpc.tracks
	local n = H.call(tr and tr.SizeNormalTracks) or 0
	H.log("midi routing probe (" .. n .. " normal tracks):")
	for i = 0, math.min(n, 8) - 1 do
		local name = try("name(" .. i .. ")", tr.GetCurrentTrackName, i)
		if type(name) ~= "string" then
			name = try("name#" .. i, tr.GetCurrentTrackName, tostring(i))
		end
		local key = (type(name) == "string" and name ~= "") and name or i
		local port = try("port", tr.GetTrackInputPort, key)
		local ch = try("ch", tr.GetTrackInputChannel, key)
		local mon = try("mon", tr.GetTrackMonitorState, key)
		local trig = try("trig", tr.IsTrackMidiTriggered, key)
		local armed = H.truthy(H.propValue(H.trackAt(i), "RecArm"))
		H.log(string.format(
			"  [%d] %s: in=%s ch=%s mon=%s midiTrig=%s armed=%s",
			i, tostring(name), tostring(port), tostring(ch), tostring(mon), tostring(trig), tostring(armed)
		))
	end
	midiRoutingLogged = true
end

-- THE MIDI GUARD. The MPC defaults every new (drum) track to MIDI-triggered
-- input "All Inputs, omni" (readback 2147483645 = -3 on 3.10.1.12), so every
-- note this controller sends sounds those tracks in ANY surface mode — script
-- mappings are additive dispatch and consume nothing (device-proven: the leak
-- shows in plain session mode). The guard moves tracks on the "All" default to
-- a no-external-input state instead:
--   - only tracks whose input reads back as the All sentinel are touched; a
--     track you pointed at a specific port (a keyboard, another controller)
--     keeps its setting forever;
--   - the "none" value is discovered once by trying candidates and reading
--     back, then cached;
--   - it re-runs every 2 s, so newly added tracks are guarded too;
--   - the MPC's own hardware pads are unaffected (they trigger internally,
--     not through the track's MIDI input).
local MIDI_IN_ALL = 2147483645
local midiInNone = nil -- discovered once, cached across guard runs

local function trackInputKeys(tr, i)
	local name = H.call(tr.GetCurrentTrackName, i)
	if type(name) == "string" and name ~= "" then
		return { i, name }
	end
	return { i }
end

local function guardTrackInputs()
	local tr = mpc.tracks
	if not (tr and type(tr.GetTrackInputPort) == "function" and type(tr.SetTrackInputPort) == "function") then
		return
	end
	if not H.projectLoaded() then
		return
	end
	local n = H.call(tr.SizeNormalTracks) or 0
	for i = 0, n - 1 do
		for _, key in ipairs(trackInputKeys(tr, i)) do
			if H.call(tr.GetTrackInputPort, key) == MIDI_IN_ALL then
				if midiInNone == nil then
					for _, v in ipairs({ -1, -2 }) do
						local ok = pcall(tr.SetTrackInputPort, key, v)
						if ok and H.call(tr.GetTrackInputPort, key) == v then
							midiInNone = v
							H.log("midi guard: input 'none' sentinel is " .. v)
							break
						end
					end
					if midiInNone == nil then
						H.logOnce("noguard", "midi guard: no 'none' sentinel accepted; tracks stay on All")
						return
					end
				end
				local ok = pcall(tr.SetTrackInputPort, key, midiInNone)
				if ok and H.call(tr.GetTrackInputPort, key) == midiInNone then
					H.log("midi guard: track [" .. i .. "] input All -> none")
				end
			end
		end
	end
end

-- The virtual padPerform press opens the Pad Perform DIALOG on 3.10.1, not
-- just the mode. While any dialog is open the popup guard blocks every other
-- button on the surface (device report: "session/drum/keys/user all dead,
-- arrows too"). Close it — but ONLY the one we opened; a user's own dialog
-- (New Project, save prompts, ...) is never dismissed.
local ppWatchUntil = 0 -- close the Pad Perform dialog for this many ticks after a press
local pressSurfaceButton -- forward declaration (defined below)

local function closePadPerformPopup()
	if H.currentPopup() ~= "Pad Perform" then
		return false
	end
	local popups = mpc.ui and mpc.ui.popups
	local close = H.callable(popups, "CloseCurrentPopup")
	if not close then
		H.logOnce("nopopupclose", "Pad Perform dialog cannot be closed: ui.popups.CloseCurrentPopup missing")
		return false
	end
	H.call(close)
	H.log("pad perform dialog closed")
	return true
end

-- The dialog opens ASYNCHRONOUSLY on the device (a beat after the press), so
-- the immediate close after a padPerform press races and loses. Watch for it
-- on the timer instead: for 2 s after each of our presses, any "Pad Perform"
-- popup is ours and gets closed. After the window, a dialog YOU opened by
-- hand is left alone.
local function watchPadPerformPopup()
	if padPerformPageOurs() then
		return -- our page stays open while keys owns the surface on a melodic track
	end
	if ticks < ppWatchUntil and H.currentPopup() == "Pad Perform" then
		closePadPerformPopup()
	end
end

-- padPerform presses must NEVER run right after a screen transition (the
-- Main press inside enterPadsMode/exit): the host swallows the second press
-- while the UI settles — Pad Perform then only engaged on the first use
-- (device report). Every padPerform press is deferred two ticks (~100 ms)
-- through the timer instead.
local ppPressAt = nil -- tick deadline for a deferred padPerform toggle

local function deferPadPerformPress()
	ppPressAt = ticks + 2
end

local function runDeferredPadPerform()
	if not ppPressAt or ticks < ppPressAt then
		return
	end
	ppPressAt = nil
	if pressSurfaceButton("padPerform") then
		ppWatchUntil = ticks + 40 -- a dialog arriving AFTER we left gets closed
		H.log("pad perform toggled (deferred)")
	else
		H.logOnce("padperform", "pad perform unavailable: controlSurface.padPerform missing")
	end
	if not padPerformPageOurs() then
		closePadPerformPopup() -- only a page we own stays open
	end
end

-- Proactive fault tolerance (device request): entering session, drums, user,
-- the mixer or leaving keys SWEEPS Pad Perform away, even when our bookkeeping
-- desynced (the dialog opens asynchronously, a page may have been opened by
-- hand). Evidence-based — the popup name or our keysPP flag — so the clean
-- path presses nothing.
local function dismissPadPerform()
	local popup = H.currentPopup() == "Pad Perform"
	if not popup and not keysPP then
		return -- a pending deferred press (if any) still handles the toggle
	end
	ppPressAt = nil -- we take over: never toggle twice
	keysPP = false
	if pressSurfaceButton("padPerform") then
		H.log("pad perform off (sweep)")
		ppWatchUntil = ticks + 40 -- the press may reopen the dialog late
	end
	closePadPerformPopup()
end

pressSurfaceButton = function(name)
	local press = H.callable(mpc.controlSurface and mpc.controlSurface[name], "Press")
	if press then
		H.call(press)
		H.call(H.callable(mpc.controlSurface[name], "Release"))
		return true
	end
	return false
end

padsLayoutAvailable = function()
	local pads = dev.mappings and dev.mappings.pads
	if not pads then
		return false
	end
	local field = (padsLayout == "pads64") and "AddNoteToVirtualPad" or "AddNoteToMpcPad"
	return H.callable(pads, field) ~= nil
end

exitPadsMode = function()
	-- The Pad Perform page must never outlive the pads mode it was opened with:
	-- every exit path funnels through here, so the page closes exactly once and
	-- the MPC returns to its Main screen (keysPage without padsMode was the
	-- "screen says one thing, surface does another" divergence).
	if keysPage then
		keysPage = false -- the Pad Perform page stops being ours (predicate went false)
		-- Main first; the padPerform OFF toggle is deferred past the transition
		if pressSurfaceButton("main") then
			H.log("keys: back to main")
		end
		if keysPP then
			keysPP = false
			deferPadPerformPress()
		end
	end
	dismissPadPerform() -- evidence-based immediate sweep (cancels the deferral)
	if not padsMode then
		return
	end
	padsMode = false
	local pads = dev.mappings and dev.mappings.pads
	for _, b in ipairs(boundPadNotes) do
		if b.pad then
			H.call(pads and pads.RemoveNoteToMpcPad, 0, b.note, b.pad)
		else
			H.call(pads and pads.RemoveNoteToVirtualPad, 0, b.note)
		end
		-- NOTE: no AddNoteToScript here — the script binding is never removed
		-- (see enterPadsMode); it is only ever added once at OnLoad. (Kept for
		-- handler dispatch, NOT consumption — see the midi guard.)
	end
	boundPadNotes = {}
	padsColourCache = {}
	if padsLayout == "pads64" then
		-- virtual pads live beyond the physical 16; using them can leave the MPC's pad
		-- engine on an out-of-range bank where every track's pads are dark and silent
		-- (they still show MIDI activity). Return the pad bank to A on the way out.
		if pressSurfaceButton("bank1") then
			H.log("pad bank reset (bank 1)")
		else
			H.logOnce("bankreset", "pad bank reset unavailable: controlSurface.bank1 missing")
		end
	end
	H.log("pads mode off")
end

-- Enter pads mode: route the 16 quadrant notes to the MPC pads (hardware-routed; they no
-- longer reach HandleMIDINoteOn). Missing mappings degrade: the mode stays off.
-- Chromatic layout: the whole grid, rows a perfect 4th apart (5 semitones), driven
-- through virtual pads (AddNoteToVirtualPad) because AddNoteToMpcPad only reaches
-- bank A (16 pads, device-verified). The root note shifts by octaves with the
-- up/down arrows while the mode is open.
-- 64-pads layout (MPC 3.10.1 "8x8: 64 Pads Mode"): the grid maps 1:1 to the
-- program's 64 pads, row-major — each grid row is one pad bank (bottom row = bank A,
-- eight banks A-H of eight pads). Virtual pad N is program pad N+1, so virtual pads
-- 0-63 cover the whole program.
chromaticVirtualPad = function(padRow, col)
	return padRow * 8 + col
end

local function enterPadsMode()
	local m = dev.mappings and dev.mappings.script
	local pads = dev.mappings and dev.mappings.pads
	if not (m and pads and m.AddNoteToScript) then
		H.logOnce("padsmode", "pads mode unavailable: mappings.pads missing")
		return
	end
	if padsLayout == "pads64" and type(pads.AddNoteToVirtualPad) ~= "function" then
		H.logOnce("padschromatic", "chromatic layout unavailable: AddNoteToVirtualPad missing")
		return
	end
	if padsLayout == "drum" and type(pads.AddNoteToMpcPad) ~= "function" then
		H.logOnce("padsmode", "pads mode unavailable: AddNoteToMpcPad missing")
		return
	end
	padsMode = true
	padsColourCache = {}
	boundPadNotes = {}
	if padsLayout == "drum" then
		-- The MPC only lights its pad grid on pad-capable screens (Main, program
		-- editors); on other pages (Keyboard settings, Q-Link, step seq, browser) the
		-- pads report black and the mirror would go dark. Return the MPC to its Main
		-- screen so the grid lights up (guarded; logged once if unavailable).
		if pressSurfaceButton("main") then
			H.log("pad view: main screen")
		else
			H.logOnce("padview", "pad view reset unavailable: controlSurface.main missing")
		end
	end
	if padsLayout == "pads64" then
		for padRow = 0, 7 do
			for col = 0, 7 do
				local note = 10 * (padRow + 1) + col + 1
				-- the notes STAY script-bound: dispatch is additive (the pad binding
				-- fires the virtual pad, the script binding reaches our handler which
				-- early-returns). NOTE: nothing here CONSUMES the note — the host
				-- feeds track inputs regardless of mappings; the track-input guard
				-- (guardTrackInputs) is what keeps the Launchpad silent as a sound
				-- source.
				H.call(pads.AddNoteToVirtualPad, 0, note, chromaticVirtualPad(padRow, col))
				boundPadNotes[#boundPadNotes + 1] = { note = note }
			end
		end
	else
		for i = 0, 15 do
			local note = padsModeNote(i)
			H.call(pads.AddNoteToMpcPad, 0, note, i)
			boundPadNotes[#boundPadNotes + 1] = { note = note, pad = i }
		end
	end
	H.log("pads mode on (" .. padsLayout .. ")")
	if padsLayout == "pads64" then
		-- the 8x8 view itself is a screen-side setting with no script API; without it
		-- the MPC stays in the 16-pad view and the upper pad colours/banks do not
		-- populate (there is no 8x8 mode for drum kits at all)
		H.logOnce("tip8x8", "tip: switch the MPC's pad view to 8x8 64 Pads for full colours")
	end
end

-- Pick the first layout from the current track's Type: pad-based programs (Drum)
-- get the drum layout, melodic programs (Plugin/Keygroup/MIDI) get chromatic.
local function firstLayoutForTrack()
	local t = mpc.tracks and mpc.tracks.currentTrack
	local trackType = H.propValue(t, "Type")
	if type(trackType) == "string" and trackType ~= "" and trackType ~= "Drum" then
		return "pads64", trackType
	end
	return "drum", trackType
end

trackIsMelodicFn = function()
	return firstLayoutForTrack() == "pads64"
end

-- Tapping Drums cycles: off -> the layout the track type suggests (drum tracks
-- the 4x4 quadrant, melodic tracks the 64-pad chromatic grid) -> the OTHER
-- layout -> off. Without a shift layer the cycle is the only layout switcher,
-- and every program can reach the 64-pad grid (kits beyond bank A included).
local function togglePadsMode()
	if not padsMode and not H.requireProject("pads mode") then
		return
	end
	logMidiRouting()
	if not padsMode then
		local layout, trackType = firstLayoutForTrack()
		padsLayout = layout
		padsSwitched = false
		H.log("track type " .. tostring(trackType or "?") .. " -> " .. layout)
		exitPadsMode() -- clears a stray keysPage (degraded padPerform entry)
		closeGridStates()
		enterPadsMode()
		if padsMode then
			paintPadsGrid(true) -- immediate mirror, independent of the tick parity
		end
		return
	end
	if not padsSwitched then
		-- flip the layout in place: quadrant <-> 64 pads
		exitPadsMode()
		padsLayout = (padsLayout == "drum") and "pads64" or "drum"
		padsSwitched = true
		enterPadsMode()
		if padsMode then
			paintPadsGrid(true)
		end
		return
	end
	exitPadsMode()
	paintAll()
end

-- Keys (CC 97): play the current track's pads from the grid, track-type aware.
--   drum track    -> the 4x4 quadrant plays the kit plainly. Pad Perform is NOT
--                    engaged: its chord/scale transform remaps the kit's pads
--                    and most of them go silent (two device reports) — a drum
--                    kit is not a chord instrument.
--   melodic track -> the quadrant + the MPC's Pad Perform page: the 16 pads
--                    play chords/scales under the page's settings.
-- Pressing Keys again leaves: Pad Perform toggled off (only if we engaged it),
-- pads mode off, MPC back on its Main screen.
local function toggleKeysPage()
	if keysPage then
		exitPadsMode() -- also leaves the Pad Perform page (MPC back on Main)
		paintAll()
		return
	end
	if not H.requireProject("keys page") then
		return
	end
	local layout, trackType = firstLayoutForTrack()
	exitPadsMode()
	closeGridStates()
	padsLayout = "drum" -- Pad Perform and plain kit play both drive the 16 pads
	padsSwitched = true -- one more Drums press exits instead of flipping
	enterPadsMode()
	if not padsMode then
		H.logOnce("padperform", "keys page unavailable: pads mapping missing")
		paintAll()
		return
	end
	if layout == "pads64" then
		-- melodic: engage the Pad Perform mode for chords/scales. The press is
		-- DEFERRED past enterPadsMode's Main press (immediate presses get
		-- swallowed by the screen transition). The Pad Perform page STAYS OPEN:
		-- it is the feature's UI, and closing it on entry raced the mode
		-- lifecycle (device report: re-entry from other screens never engaged).
		keysPage, keysPP = true, true
		deferPadPerformPress()
		H.log("keys page: pad perform chords (" .. tostring(trackType) .. ")")
	else
		-- drum kit: play it plainly, no mode toggle, no screen change
		keysPage, keysPP = true, false
		H.log("keys page: kit play (drum track)")
	end
	paintAll()
end

-- Close EVERY grid-owning state. Single source of truth: exitPadsMode handles
-- the pads-mode note bindings and the Pad Perform page, closeGridStates every
-- page flag. Every "leave a page" path funnels through one of these two, so a
-- page can never survive under a new mode — the overlap class the device
-- reported twice (mixer-under-pages, notes-playing-under-qlink).
local function closeAllPages()
	exitPadsMode()
	closeGridStates()
end


local function doClip(col, row)
	if not aperture then
		return
	end
	H.call(aperture.SelectClip, col, row)
	H.call(aperture.TriggerClip, col, row)
	H.log(string.format("TriggerClip(%d,%d)", col, row))
end

local function doScene(row)
	if not aperture then
		return
	end
	H.call(aperture.TriggerRow, row)
	H.log("TriggerRow(" .. row .. ")")
end

-- Apply a track function (mute/solo/recArm/stopClip) to a specific track index.
local function applyFunction(fn, idx)
	local t = mpc.tracks and mpc.tracks.normalTracks and mpc.tracks.normalTracks[idx]
	if not t then
		H.logOnce("track", "no track " .. tostring(idx))
		return
	end
	if fn == "recArm" then
		local v = H.propValue(t, "RecArm")
		H.call(t.SetRecArm, not v)
		H.log("SetRecArm(" .. tostring(not v) .. ") track " .. idx)
	elseif fn == "mute" then
		local v = H.propValue(t, "Mute")
		H.call(t.SetMute, not v)
		H.log("SetMute(" .. tostring(not v) .. ") track " .. idx)
	elseif fn == "solo" then
		local v = H.propValue(t, "Solo")
		H.call(t.SetSolo, not v)
		H.log("SetSolo(" .. tostring(not v) .. ") track " .. idx)
	elseif fn == "stopClip" then
		H.call(aperture and aperture.StopClipsOnTrack, idx)
		H.log("StopClipsOnTrack(" .. idx .. ")")
	else
		H.log(fn .. ": unsupported track function " .. idx)
	end
end

-- Select a track (the mixer's bottom row). Two coordinates: the aperture takes a
-- window-LOCAL column (same convention as SelectClip), while mpc.tracks.SetCurrentTrack
-- takes the GLOBAL index and is what currentTrack — and everything reading it
-- (note mode's track type, track nav, plugin presets) — follows. Call both so the
-- column highlight and the real selection agree.
local function selectTrack(col, gc)
	local setCurrent = H.callable(mpc.tracks, "SetCurrentTrack")
	if setCurrent then
		H.call(setCurrent, gc)
		H.log("SetCurrentTrack(" .. gc .. ")")
	end
	if aperture then
		H.call(aperture.SelectTrack, col)
	end
end

-- Write a track property (Volume/Pan/Send1-4) through its .value, guarded.
local function setTrackValue(idx, name, v)
	local t = H.trackAt(idx)
	if not t then
		H.logOnce("track", "no track " .. tostring(idx))
		return
	end
	local p = t[name]
	if p == nil then
		H.logOnce("prop" .. name, name .. " MISSING on track " .. tostring(idx))
		return
	end
	local value = H.clamp01(v)
	local ok = pcall(function()
		p.value = value
	end)
	if not ok then
		H.logOnce("set" .. name, "set " .. name .. " failed on track " .. tostring(idx))
		return
	end
	H.log(string.format("%s track %d = %.3f", name, idx, value))
end

-- Write a track's VolumeDB directly (dB), falling back to the linear Volume
-- property if VolumeDB is read-only on this firmware.
local function setTrackVolumeDB(idx, db)
	local t = H.trackAt(idx)
	if not t then
		H.logOnce("track", "no track " .. tostring(idx))
		return
	end
	local p = t.VolumeDB
	if p ~= nil then
		local ok = pcall(function()
			p.value = db
		end)
		if ok then
			H.log(string.format("VolumeDB track %d = %s", idx, tostring(db)))
			return
		end
	end
	-- fallback: invert the MPC fader curve (dB = 40*log10(gain) + 6)
	setTrackValue(idx, "Volume", H.dbToGain(db))
end

local function changeTempo(delta)
	if not H.requireProject("tempo") then
		return
	end
	local sq = mpc.sequencer
	local bpm = H.call(sq and sq.GetBPM) or 120
	bpm = math.max(20, math.min(300, math.floor(bpm + delta + 0.5)))
	H.call(sq and sq.SetBPM, bpm)
	H.log("tempo: " .. bpm .. " BPM")
	paintGrid()
	paintTop()
	flushLEDs()
end

local function changeSwing(delta)
	if not H.requireProject("swing") then
		return
	end
	local q = mpc.sequencer and mpc.sequencer.quantiser
	-- MPC swing: 50% = straight, > 50 delays every other step; 75% is the max
	local swing = H.call(q and q.GetSwing) or 50
	swing = math.max(50, math.min(75, math.floor(swing + delta + 0.5)))
	H.call(q and q.SetSwing, swing)
	H.log("swing: " .. swing .. "%")
	paintGrid()
	paintTop()
	flushLEDs()
end

local function nudgeAdjust(delta)
	if not adjustMode then
		return
	end
	local gc = H.globalPos(adjustCol, 0)
	local name = H.adjustPropName()
	if not name then
		return
	end
	if adjustMode == "volume" then
		local db = H.gainToDb(H.propValue(H.trackAt(gc), "Volume"))
		local row = H.dbToRow(db)
		if delta > 0 then
			row = math.max(0, row - 1)
		else
			row = math.min(GRID_ROWS - 1, row + 1)
		end
		setTrackVolumeDB(gc, VOLUME_DB[row])
		paintAll()
		return
	end
	local cur = H.propValue(H.trackAt(gc), name)
	if type(cur) ~= "number" then
		cur = 0
	end
	setTrackValue(gc, name, cur + delta)
	paintAll()
end

local function enterAdjust(newMode, sendIdx)
	if not H.requireProject(newMode .. " menu") then
		return
	end
	exitPadsMode() -- the fader menus need the whole grid
	closeGridStates() -- one canonical "close every other page" list
	adjustMode = newMode
	adjustCol = 0
	lastPadCol, lastPadRow, lastPadTick = nil, nil, -100
	if newMode == "sends" then
		adjustSend = sendIdx or adjustSend or 1
	end
	H.log("menu " .. newMode .. (newMode == "sends" and (" send " .. adjustSend) or ""))
	paintAll()
end

local function exitAdjust()
	if adjustMode then
		adjustMode = nil
		lastPadCol, lastPadRow, lastPadTick = nil, nil, -100
		H.log("menu off")
		paintAll()
	end
end

local function handleAdjustPad(col, row)
	if not adjustMode then
		return
	end
	local gc = H.globalPos(col, 0)
	if adjustMode == "volume" then
		setTrackVolumeDB(gc, VOLUME_DB[row])
		lastPadCol, lastPadRow, lastPadTick = col, row, ticks
		adjustCol = col
		paintAll()
		return
	end
	local value = (GRID_ROWS - row) / GRID_ROWS
	-- double-tapping the bottom pad reaches the true minimum (0.0)
	if col == lastPadCol and row == lastPadRow and ticks - lastPadTick <= 2 then
		if row == GRID_ROWS - 1 then
			value = 0
		end
	end
	lastPadCol, lastPadRow, lastPadTick = col, row, ticks
	adjustCol = col
	local name = H.adjustPropName()
	if name then
		setTrackValue(gc, name, value)
		paintAll()
	end
end

-- Tap tempo: use dev.timer.Now() (ms, high resolution) and average the last
-- few tap intervals. Falls back to the 50 ms timer tick if Now() is missing.
-- (The Mini has no spare CC to route to the MPC's native Tap Tempo control,
-- so the averager is the only path.)
local function doTapTempo()
	local now = H.call(dev.timer and dev.timer.Now)
	local useMs = type(now) == "number"
	if not useMs then
		now = ticks
	end
	local function diff(a, b)
		local d = a - b
		if useMs and d < 0 then
			d = d + 4294967296 -- 32-bit wrap
		end
		return d
	end
	-- a gap longer than 2 s starts a new tap sequence
	if #tapTicks > 0 and diff(now, tapTicks[#tapTicks]) > (useMs and 2000 or 40) then
		tapTicks = {}
	end
	tapTicks[#tapTicks + 1] = now
	if #tapTicks > 5 then
		table.remove(tapTicks, 1)
	end
	if #tapTicks < 2 then
		H.log("tap tempo: first tap")
		return
	end
	local total = 0
	for i = 2, #tapTicks do
		total = total + diff(tapTicks[i], tapTicks[i - 1])
	end
	local avg = total / (#tapTicks - 1)
	local bpm = (useMs and 60000 or 1200) / avg
	bpm = math.max(20, math.min(300, bpm))
	bpm = math.floor(bpm + 0.5) -- MPC BPM is an integer
	local setBPM = H.callable(mpc.sequencer, "SetBPM")
	if setBPM then
		H.call(setBPM, bpm)
		H.log(string.format("tap tempo: %d BPM (%.1f ms)", bpm, avg))
	else
		H.logOnce("tapbpm", "tap tempo unavailable: sequencer.SetBPM missing")
	end
end

local function doMetronomeToggle()
	local sq = mpc.sequencer
	local me = H.propValue(sq, "MetronomeEnabled")
	if sq and type(sq.SetMetronomeEnabled) == "function" then
		H.call(sq.SetMetronomeEnabled, not me)
		H.log("Metronome " .. tostring(not me))
	else
		H.logOnce("metronome", "metronome unavailable: sequencer.SetMetronomeEnabled missing")
	end
end

local function doTransport(fn)
	if not H.requireProject("transport") then
		return
	end
	local sq = mpc.sequencer
	if fn == "play" then
		local playing = sq and H.call(sq.IsPlaying) or H.propValue(sq, "Playing")
		if not playing then
			H.call(sq and sq.Play)
			H.log("Play")
		end
	elseif fn == "stop" then
		local playing = sq and H.call(sq.IsPlaying) or H.propValue(sq, "Playing")
		if playing then
			H.call(sq and sq.Stop)
			H.log("Stop")
		else
			-- stop while stopped returns the playhead to zero (MPC hardware habit)
			if H.callable(sq, "JumpToBeginning") then
				H.call(sq.JumpToBeginning)
				H.log("Locate zero")
			else
				H.logOnce("locate", "locate zero unavailable: sequencer.JumpToBeginning missing")
			end
		end
	end
end

-- Record: arm/disarm, matching the MPC's own REC button — the first press arms
-- recording (recording starts when the transport runs or a clip is triggered),
-- the next press disarms. Delegates to controlSurface.record so the MPC's
-- record state machine does the work; falls back to Record/RecordOff.
local function recordArmed()
	return H.truthy(H.propValue(mpc.sequencer, "RecordState"))
end

local function doRecordToggle()
	if not H.requireProject("record") then
		return
	end
	local armed = recordArmed()
	if pressSurfaceButton("record") then
		H.log("record: " .. (armed and "disarmed" or "armed"))
		return
	end
	local name = armed and "RecordOff" or "Record"
	local f = H.callable(mpc.sequencer, name)
	if not f then
		H.logOnce("record", "record unavailable: sequencer." .. name .. " missing")
		return
	end
	H.call(f)
	H.log("record: " .. (armed and "disarmed" or "armed"))
end

-- Previous/next plugin preset on the current track (present on track objects
-- in 3.10.1).
local function moveWindow(dir, n)
	if not aperture then
		return
	end
	local fn = ({ left = "MoveLeft", right = "MoveRight", up = "MoveUp", down = "MoveDown" })[dir]
	if fn then
		H.call(aperture[fn], n)
		H.log(fn .. "(" .. n .. ")")
		padCache = {}
		listenGrid() -- the slot properties follow the window: rebind, then repaint
		paintAll()
	end
end

-----------------------------------------------------------------------------------------------
-- MIXER menu (CC 19)
-----------------------------------------------------------------------------------------------

local function enterMixer()
	if not H.requireProject("mixer menu") then
		return
	end
	exitPadsMode() -- the mixer needs the whole grid
	closeGridStates() -- one canonical "close every other page" list
	mixerMode = true
	H.log("mixer menu")
	paintAll()
end

local function exitMixer()
	if not mixerMode then
		return
	end
	mixerMode = false
	H.log("mixer menu off")
	paintAll()
end

local function toggleMixer()
	if mixerMode then
		exitMixer()
	else
		enterMixer()
	end
end

-- Open the tempo page (mixer row 1). Closes the mixer: the page owns the grid.
local function toggleTempoPage()
	if not tempoMode and not H.requireProject("tempo page") then
		return
	end
	exitPadsMode() -- the tempo page needs the whole grid
	exitMixer()
	closeGridStates() -- one canonical "close every other page" list
	tempoMode = not tempoMode
	tempoHold = nil
	if tempoMode then
		H.log("tempo page: " .. tostring(H.call(mpc.sequencer and mpc.sequencer.GetBPM)) .. " BPM")
	else
		H.log("tempo page off")
	end
	paintAll()
	flushLEDs()
end

-- Open the swing page (mixer row 1). Closes the mixer: the page owns the grid.
local function toggleSwingPage()
	if not swingMode and not H.requireProject("swing page") then
		return
	end
	exitPadsMode() -- the swing page needs the whole grid
	exitMixer()
	closeGridStates() -- one canonical "close every other page" list
	swingMode = not swingMode
	swingHold = nil
	if swingMode then
		H.log(
			"swing page: "
				.. tostring(H.call(mpc.sequencer and mpc.sequencer.quantiser and mpc.sequencer.quantiser.GetSwing))
				.. "%"
		)
	else
		H.log("swing page off")
	end
	paintAll()
	flushLEDs()
end

-- One mixer pad press. row 0 = pages strip, row 1 = transport strip,
-- rows 2-7 = the per-track rows (record / stop / mute / solo / arm / select).
local function startTrackRecording(col, gc)
	-- start a clip recording on this track: select + arm it, then trigger its
	-- first empty slot in the window (an armed track records into an empty slot
	-- on trigger — verify on hardware, see docs/LAYOUT open questions)
	local t = H.trackAt(gc)
	if not t then
		return
	end
	selectTrack(col, gc)
	if not H.truthy(H.propValue(t, "RecArm")) then
		H.call(t.SetRecArm, true)
	end
	local m = mpc.clipMatrix
	if not (m and m.HasClip and aperture) then
		H.logOnce("recslot", "track record: clipMatrix.HasClip missing")
		return
	end
	for row = 0, GRID_ROWS - 1 do
		local gC, gR = H.globalPos(col, row)
		local has = H.call(m.HasClip, gC, gR)
		if not has then
			H.call(aperture.TriggerClip, col, row)
			H.log(string.format("track record: TriggerClip(%d,%d) on armed track", col, row))
			return
		end
	end
	H.logOnce("recfull", "track record: no empty slot in the window for track " .. gc)
end

local function handleMixerPad(col, row)
	if row >= 2 then
		-- per-track-column rows
		if not H.requireProject("mixer track row") then
			return
		end
		local gc = H.globalPos(col, 0)
		if row == 7 then
			selectTrack(col, gc)
		elseif row == 6 then
			applyFunction("recArm", gc)
		elseif row == 5 then
			applyFunction("solo", gc)
		elseif row == 4 then
			applyFunction("mute", gc)
		elseif row == 3 then
			H.call(aperture and aperture.StopClipsOnTrack, gc)
			H.log("StopClipsOnTrack(" .. gc .. ")")
		elseif row == 2 then
			-- record: stop the track's recording, or start one
			if trackRecording(gc) then
				H.call(aperture and aperture.StopClipsOnTrack, gc)
				H.log("StopClipsOnTrack(" .. gc .. ") (recording)")
			else
				startTrackRecording(col, gc)
			end
		end
		paintAll()
		return
	end
	local key = MIX_STRIP_KEYS[row][col + 1]
	if not key then
		return
	end
	if key == "play" then
		doTransport("play")
	elseif key == "record" then
		doRecordToggle()
	elseif key == "stop" then
		doTransport("stop")
	elseif key == "tap" then
		doTapTempo()
	elseif key == "click" then
		doMetronomeToggle()
	elseif key == "volume" then
		if adjustMode == "volume" then
			exitAdjust()
		else
			enterAdjust("volume")
		end
	elseif key == "pan" then
		if adjustMode == "pan" then
			exitAdjust()
		else
			enterAdjust("pan")
		end
	elseif key == "send" then
		if adjustMode == "sends" then
			adjustSend = (adjustSend % 4) + 1
			H.log("send " .. adjustSend)
			paintAll()
		else
			enterAdjust("sends")
		end
	elseif key == "tempo" then
		toggleTempoPage()
	elseif key == "swing" then
		toggleSwingPage()
	elseif key == "qlink" then
		cycleQlinkPage()
	end
	paintAll()
end

-----------------------------------------------------------------------------------------------
-- Input handlers
-----------------------------------------------------------------------------------------------

local function noteIndex(note)
	if note >= GRID_NOTE0 and note <= GRID_NOTE0 + 77 then
		local i = note - GRID_NOTE0
		local padRow = math.floor(i / 10)
		local col = i % 10
		if col < 8 and padRow < 8 then
			return col, 7 - padRow -- col, MPC row (0 = top)
		end
	end
	return nil
end

function LaunchpadMiniMK3.HandleMIDINoteOn(channel, note, velocity)
	if channel ~= 0 then
		return
	end
	local col, row = noteIndex(note)
	if col then
		if padsMode then
			-- a pad mode owns the grid. The pad binding fired the MPC pad; the
			-- script binding also delivers here (additive dispatch) and we ignore
			-- it. Sound-side silence comes from the track-input guard instead.
			return
		end
		if velocity > 0 then
			-- exactly one owner decides: a page, else the clip grid. Never add a
			-- branch that can be reached while another page owns the grid — that
			-- dispatch-order leak is how pads once played through the Q-Link page.
			if mixerMode then
				handleMixerPad(col, row)
			elseif adjustMode then
				handleAdjustPad(col, row)
			elseif qlinkMode then
				handleQlinkPad(col, row)
			elseif not tempoMode and not swingMode then
				doClip(col, row)
			end
		end
		return
	end
end

function LaunchpadMiniMK3.HandleMIDINoteOff(_channel, _note, _velocity)
	-- LPMiniMK3 sends Note On with velocity 0 for Note Off; nothing to do here
end

-- ==== CC dispatch ==========================================================
-- One action map: PRESS runs on a press (value > 0); a release stops the
-- up/down auto-repeat. There is no Shift — the Novation logo is not a button.

local function ccRelease(cc)
	-- releasing the up/down button stops the auto-repeat
	if cc == TOP.up or cc == TOP.down then
		tempoHold = nil
		swingHold = nil
	end
end

-- Up/down arrows: the active page decides what they nudge.
local function ccUpDown(delta)
	if tempoMode then
		tempoHold = (delta > 0) and TOP.up or TOP.down
		tempoHoldTicks = 0
		changeTempo(delta)
	elseif swingMode then
		swingHold = (delta > 0) and TOP.up or TOP.down
		swingHoldTicks = 0
		changeSwing(delta)
	elseif adjustMode then
		nudgeAdjust(delta / 8)
	elseif qlinkMode then
		if qlinkPage == 0 and qlinkPageHasContent(1) then
			qlinkPage = 1
			H.log("qlink page 2")
			paintAll()
		elseif qlinkPage == 1 then
			qlinkPage = 0
			H.log("qlink page 1")
			paintAll()
		end
	elseif padsMode then
		-- the pads layout owns the grid: the window must not move under it
		return
	else
		moveWindow((delta > 0) and "up" or "down", 1)
	end
end

-- Plain press actions.
local PRESS = {
	[TOP.up] = function()
		ccUpDown(1)
	end,
	[TOP.down] = function()
		ccUpDown(-1)
	end,
	-- Left/right while a fader/tempo/swing/Q-Link page owns the grid: only the
	-- sends cycle applies; the window must NOT move under a page. In the mixer
	-- they keep moving the window (the mixer columns follow it — a feature).
	[TOP.left] = function()
		if adjustMode == "sends" then
			adjustSend = ((adjustSend - 2) % 4) + 1
			H.log("send " .. adjustSend)
			paintAll()
			return
		end
		if adjustMode or tempoMode or swingMode or qlinkMode or padsMode then
			return
		end
		moveWindow("left", 1)
	end,
	[TOP.right] = function()
		if adjustMode == "sends" then
			adjustSend = (adjustSend % 4) + 1
			H.log("send " .. adjustSend)
			paintAll()
			return
		end
		if adjustMode or tempoMode or swingMode or qlinkMode or padsMode then
			return
		end
		moveWindow("right", 1)
	end,
	-- Session: the universal "back to the clip grid" — every page and pads mode
	-- close, the window stays where it is.
	[TOP.session] = function()
		dismissPadPerform() -- a stuck Pad Perform must never block the escape
		closeAllPages()
		H.log("session: clip grid")
		paintAll()
	end,
	[TOP.drums] = function()
		dismissPadPerform() -- a chord-mangled surface must not leak into pads mode
		togglePadsMode()
		paintAll()
	end,
	[TOP.keys] = toggleKeysPage,
	[TOP.user] = function()
		dismissPadPerform()
		cycleQlinkPage()
	end,
}

-- Scene buttons: launch the row.
for row = 0, 6 do
	local sceneRow = row
	PRESS[SCENE[sceneRow + 1]] = function()
		doScene(sceneRow)
	end
end

-- The menu key (bottom-right corner).
PRESS[MENU] = function()
	dismissPadPerform()
	if adjustMode or tempoMode or swingMode or qlinkMode then
		-- acts as the universal page exit, then falls through to the mixer on
		-- the next press (single-button surfaces need one obvious exit)
		closeAllPages()
		H.log("pages off")
		paintAll()
		return
	end
	toggleMixer()
end

function LaunchpadMiniMK3.HandleMIDICC(channel, cc, value)
	if channel ~= 0 then
		return
	end
	if value == 0 then
		ccRelease(cc)
		return
	end
	local action = PRESS[cc]
	if action then
		action()
		return
	end
	H.log("unmapped CC " .. cc .. " value " .. value)
end

function LaunchpadMiniMK3.HandleMIDISysex(bytes)
	if type(bytes) ~= "string" then
		return
	end
	-- strip F0/F7 if the host passes them
	if bytes:byte(1) == 0xF0 then
		bytes = bytes:sub(2)
	end
	if bytes:byte(-1) == 0xF7 then
		bytes = bytes:sub(1, -2)
	end
	-- device identity reply: 7E <dev> 06 02 <00 20 29 Novation> <family 0x13> <model 01> <version x4>
	if
		bytes:byte(1) == 0x7E
		and bytes:byte(3) == 0x06
		and bytes:byte(4) == 0x02
		and bytes:sub(5, 7) == string.char(0x00, 0x20, 0x29)
		and bytes:byte(8) == 0x13
	then
		local ver = {}
		for i = 12, math.min(15, #bytes) do
			ver[#ver + 1] = tostring(bytes:byte(i))
		end
		H.logOnce("firmware", "firmware: " .. (#ver > 0 and table.concat(ver, ".") or "unknown"))
	end
	-- LPMiniMK3 state replies: 00 20 29 02 0D <command> <data...>
	if bytes:sub(1, 6) == string.char(0x00, 0x20, 0x29, 0x02, 0x0D) and #bytes >= 7 then
		local command = bytes:byte(6)
		if command == 0x0E and #bytes >= 7 then
			-- mode readback/echo: 0 = Live, 1 = Programmer
			local m = bytes:byte(7)
			if priorMode == nil and m ~= 0x01 then
				priorMode = m
				H.log(string.format("prior mode 0x%02x", m))
			end
		elseif command == 0x00 and #bytes >= 7 then
			-- layout readback/echo: 00 session, 04-06 custom, 0D faders, 7F programmer
			local layout = bytes:byte(7)
			if priorLayout == nil and layout ~= 0x7F then
				priorLayout = layout
				H.log(string.format("prior layout 0x%02x", layout))
			end
		elseif command == 0x0A and #bytes >= 8 then
			if priorFeedback == nil then
				priorFeedback = { bytes:byte(7), bytes:byte(8) }
			end
		end
	end
end

-----------------------------------------------------------------------------------------------
-- Timer
-----------------------------------------------------------------------------------------------

function LaunchpadMiniMK3.HandleTimer()
	ticks = ticks + 1
	-- the page may stay open only while keys owns AND the track is melodic:
	-- a track switch to drums drops the chords (kit play remains)
	if keysPage and keysPP and not trackIsMelodicFn() then
		H.log("keys page: track is not melodic anymore - chords off, kit play")
		dismissPadPerform()
	end
	runDeferredPadPerform()
	watchPadPerformPopup()
	if not midiRoutingLogged and ticks % 10 == 0 then
		logMidiRouting()
		if midiRoutingLogged then
			guardTrackInputs()
		end
	end
	-- timer runs at 50 ms; blink at 2 Hz (every 5 ticks) and full repaint every 2 s
	if ticks % 5 == 0 then
		blinkOn = not blinkOn
	end
	-- tempo page: holding up/down repeats, accelerating after a short delay
	if tempoMode and tempoHold then
		tempoHoldTicks = tempoHoldTicks + 1
		local interval = tempoHoldTicks < 10 and 6 or (tempoHoldTicks < 20 and 3 or 1)
		if tempoHoldTicks % interval == 0 then
			changeTempo(tempoHold == TOP.up and 1 or -1)
		end
	end
	-- swing page: holding up/down repeats, accelerating after a short delay
	if swingMode and swingHold then
		swingHoldTicks = swingHoldTicks + 1
		local interval = swingHoldTicks < 10 and 6 or (swingHoldTicks < 20 and 3 or 1)
		if swingHoldTicks % interval == 0 then
			changeSwing(swingHold == TOP.up and 1 or -1)
		end
	end
	-- enter Programmer mode on the first tick (the readbacks went out in OnLoad;
	-- 50 ms is enough for the replies to have arrived and been parsed)
	if modeQuerySent and not programmerEntered and ticks >= 1 then
		sendMode(0x01)
		programmerEntered = true
		-- keep the device's own press-lighting out of the way: internal feedback
		-- off, external on (the prior values are restored on unload)
		sendFeedback(0x00, 0x01)
		padCache = {}
		H.log("programmer mode")
	end
	if aperture and not clipProps then
		-- window position fallback, whichever getter this firmware has
		for _, n in ipairs({ "GetOriginX", "GetColumn", "GetX" }) do
			local v = H.call(aperture[n])
			if type(v) == "number" then
				originCol = v
				break
			end
		end
		for _, n in ipairs({ "GetOriginY", "GetRow", "GetY" }) do
			local v = H.call(aperture[n])
			if type(v) == "number" then
				originRow = v
				break
			end
		end
	end
	if ticks % 40 == 0 then
		padCache = {}
		if padsMode then
			padsColourCache = {} -- force a full quadrant resend every 2 s
		end
		guardTrackInputs() -- new tracks default to input All: move them off it
	end -- resend everything every 2 s
	paintAll()
end

-----------------------------------------------------------------------------------------------
-- Load / unload
-----------------------------------------------------------------------------------------------

function LaunchpadMiniMK3.OnLoad()
	-- full state reset: every flag the state machine owns, so a reload can never
	-- inherit a stale page (keysPage/padsSwitched/holds once leaked across reloads)
	adjustMode = nil
	adjustSend = 1
	tempoMode = false
	swingMode = false
	qlinkMode = false
	qlinkPage = 0
	qlinkCol = 0
	padsMode = false
	padsLayout = "drum"
	padsSwitched = false
	keysPage = false
	tempoHold = nil
	swingHold = nil
	padsColourCache = {}
	mixerMode = false
	aperture = dev.clipMatrixAperture or (mpc.clipMatrix and mpc.clipMatrix.clipMatrixAperture)
	clipProps = (aperture and aperture.clipProperties)
		or dev.clipProperties
		or (mpc.clipMatrix and mpc.clipMatrix.clipProperties)
	if aperture then
		H.call(aperture.SetColumns, 8)
		H.call(aperture.SetRows, 8)
		H.call(aperture.SetLabel, "LPMINI")
		H.call(aperture.SetFollowsTUI, false)
		H.call(aperture.Show)
		H.log("aperture ok")
	else
		H.logOnce("noaperture", "aperture MISSING: clip surface disabled")
	end
	if clipProps then
		H.log("clipProperties ok")
	else
		H.logOnce("noclips", "clipProperties MISSING")
	end

	-- register the LPMiniMK3 controls with the script
	local m = dev.mappings and dev.mappings.script
	if m then
		for padRow = 0, 7 do
			for col = 0, 7 do
				H.call(m.AddNoteToScript, 0, 10 * (padRow + 1) + col + 1)
			end
		end
		local ccs = { 19, 29, 39, 49, 59, 69, 79, 89, 91, 92, 93, 94, 95, 96, 97, 98 }
		for _, cc in ipairs(ccs) do
			H.call(m.AddCCToScript, 0, cc)
		end
		H.call(m.SetHandleSysex, true)
	end

	-- ask the device for its current mode/layout/feedback so they can be
	-- restored on unload; Programmer mode is entered on the first timer tick
	queryState()
	modeQuerySent = true

	-- device inquiry (universal sysex F0 7E 7F 06 01 F7): ask the LPMiniMK3 for
	-- its firmware version; log-only, the reply is parsed in HandleMIDISysex
	local okProbe = pcall(function()
		dev.midiOut.SendMIDISysex(string.char(0x7E, 0x7F, 0x06, 0x01), port)
	end)
	if not okProbe then
		H.logOnce("fwprobe", "firmware probe failed")
	end

	listenAll()
	paintAll()
	H.call(dev.timer and dev.timer.Start, 50)
	H.log("loaded")
	H.log(
		"engine mode: "
			.. tostring(
				H.propValue(mpc.engineMode, "CurrentMode") or H.call(H.callable(mpc.engineMode, "GetCurrentMode"))
			)
			.. " popup: "
			.. H.currentPopup()
	)
end
function LaunchpadMiniMK3.OnUnload()
	H.call(dev.timer and dev.timer.Stop)
	removeListeners()
	exitPadsMode() -- hand the pad-mode notes back to the script before unmapping
	padsMode = false
	padsColourCache = {}
	adjustMode = nil
	adjustSend = 1
	tempoMode = false
	swingMode = false
	qlinkMode = false
	qlinkPage = 0
	qlinkCol = 0
	mixerMode = false
	padsSwitched = false
	keysPage = false
	tempoHold = nil
	swingHold = nil
	local m = dev.mappings and dev.mappings.script
	if m then
		for padRow = 0, 7 do
			for col = 0, 7 do
				H.call(m.RemoveNoteToScript, 0, 10 * (padRow + 1) + col + 1)
			end
		end
		local ccs = { 19, 29, 39, 49, 59, 69, 79, 89, 91, 92, 93, 94, 95, 96, 97, 98 }
		for _, cc in ipairs(ccs) do
			H.call(m.RemoveCCToScript, 0, cc)
		end
	end
	-- dark the surface
	for padRow = 0, 7 do
		for col = 0, 7 do
			ledOff(10 * (padRow + 1) + col + 1)
		end
	end
	for _, cc in ipairs({ 19, 29, 39, 49, 59, 69, 79, 89, 91, 92, 93, 94, 95, 96, 97, 98 }) do
		ledOff(cc)
	end
	flushLEDs()
	-- restore the device: prior LED feedback config, then Live mode + the prior
	-- layout (Programmer mode disables the device's Setup entry, so returning to
	-- Live is required for standalone use; the reference: Live mode switches to
	-- Session or Custom 2, hence the explicit layout restore after it)
	if programmerEntered then
		if priorFeedback then
			sendFeedback(priorFeedback[1], priorFeedback[2])
		else
			sendFeedback(0x01, 0x01)
		end
		if priorMode ~= 0x01 then
			sendMode(0x00)
			sendLayout(priorLayout or 0x04)
			H.log("restored live mode")
		end
	end
	if aperture then
		H.call(aperture.Hide)
	end
	H.log("unloaded")
end

-- Reference data for the generated manual (docs/MANUAL.md).
LaunchpadMiniMK3.ACTIONS = ACTIONS
LaunchpadMiniMK3.PALETTE = C
LaunchpadMiniMK3.MIXER = MIXER

-- State-machine snapshot for the tests (tests/test-state-matrix.lua asserts the
-- invariants through it) and for on-device diagnosis: log STATE() after any
-- weird surface behaviour and the journal shows which page owns the grid.
LaunchpadMiniMK3.STATE = function()
	return {
		padsMode = padsMode,
		padsLayout = padsLayout,
		padsSwitched = padsSwitched,
		keysPage = keysPage,
		mixerMode = mixerMode,
		adjustMode = adjustMode,
		adjustSend = adjustSend,
		tempoMode = tempoMode,
		swingMode = swingMode,
		qlinkMode = qlinkMode,
		qlinkPage = qlinkPage,
		boundPadNotes = #boundPadNotes,
	}
end
