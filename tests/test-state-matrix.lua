-- tests/test-state-matrix.lua: state-machine invariants.
--
-- The device reported two overlap bugs of the same class: a page surviving
-- under another mode (mixer under pads) and pads-mode notes staying routed
-- while the Q-Link page owned the grid (pads kept PLAYING through the page).
-- Both were "enter X forgot to close Y". This test sweeps EVERY predecessor
-- x opener combination and asserts the invariants that make that class of
-- bug impossible to reintroduce:
--   INV1 single owner   at most one grid-owning state; keysPage only with padsMode
--   INV2 routing        outside pads mode no note stays routed to (virtual) pads
--   INV3 dispatch       a pad press does exactly its owner's action — never
--                       another page's effect (TriggerClip/Twist/SetMute/...)
--   INV4 frozen window  arrows never move the clip window under a page or pads
--   INV5 escape         Session always returns to the clean clip state
package.path = "./tests/?.lua;" .. package.path
local mock = require("mock-mpc")
_G.mpc = mock.mpc
_G.dev = mock.dev
_G.LaunchpadMiniMK3 = mock.dev
dofile(os.getenv("LPMINI_LUA") or "script/LaunchpadMiniMK3.lua")
local L = LaunchpadMiniMK3

local failed = 0
local function check(cond, msg)
	if not cond then
		failed = failed + 1
		print("FAIL: " .. msg)
	end
end

-- effects a pad press could trigger, per owner (the cross-effect leak detector)
local ALL_FX = {
	"TriggerClip", "SetMute", "SetSolo", "SetRecArm", "SetCurrentTrack",
	"StopClipsOnTrack", "DeleteClip", "CopyClip", "Twist", "SetBPM", "SetSwing",
}
local FX_SET = {}
for _, fx in ipairs(ALL_FX) do
	FX_SET[fx] = true
end

local function forbiddenCount(allowed)
	local n = 0
	for _, fx in ipairs(ALL_FX) do
		if not (allowed and allowed[fx]) then
			n = n + mock.count(fx)
		end
	end
	return n
end

local GRID_STATES = { "mixerMode", "adjustMode", "tempoMode", "swingMode", "qlinkMode", "padsMode" }

local function inv1(label)
	local s = L.STATE()
	local owners = 0
	for _, k in ipairs(GRID_STATES) do
		if s[k] then
			owners = owners + 1
		end
	end
	check(owners <= 1, label .. ": INV1 multiple grid owners (" .. owners .. ")")
	check(not s.keysPage or s.padsMode, label .. ": INV1 keysPage without padsMode")
	if s.padsMode then
		local want = (s.padsLayout == "pads64") and 64 or 16
		check(s.boundPadNotes == want, label .. ": INV1 boundPadNotes " .. s.boundPadNotes .. " (want " .. want .. ")")
	else
		check(s.boundPadNotes == 0, label .. ": INV1 boundPadNotes " .. s.boundPadNotes .. " while no pads mode")
	end
end

local function press(cc)
	L.HandleMIDICC(0, cc, 127)
end

local function pad(note)
	L.HandleMIDINoteOn(0, note, 100)
end

-- predecessor states, each entered from a clean load
-- sequence encoding: positive = CC press, negative = grid NOTE press
local PREDS = {
	{ name = "clip", seq = {} },
	{ name = "mixer", seq = { 19 } },
	{ name = "adjust", seq = { 19, -81 } }, -- mixer strip -> volume faders
	{ name = "tempo", seq = { 19, -84 } },
	{ name = "swing", seq = { 19, -85 } },
	{ name = "qlink", seq = { 98 } },
	{ name = "pads", seq = { 96 } }, -- drum quadrant (mock track has no Type)
	{ name = "pads64", seq = { 96, 96 } }, -- flip to the 64-pad layout
	{ name = "keys", seq = { 97 } },
}

-- states where the MENU key acts as the page exit first (it opens the mixer
-- only from non-page states: single-button surfaces need one obvious exit)
local MENU_IS_EXIT = {
	mixer = true, adjust = true, tempo = true, swing = true, qlink = true,
}

-- openers: name -> { seq(pred), want(label) } producing a target state from
-- EVERY predecessor (the MENU semantics decide the prefix)
local OPENERS = {
	{
		name = "mixer",
		seq = function(pred)
			return MENU_IS_EXIT[pred] and { 19, 19 } or { 19 }
		end,
		want = function(s)
			return s.mixerMode
		end,
		padAllowed = { SetCurrentTrack = true }, -- select row (note 11)
	},
	{
		name = "adjust",
		seq = function(pred)
			return MENU_IS_EXIT[pred] and { 19, 19, -81 } or { 19, -81 }
		end,
		want = function(s)
			return s.adjustMode == "volume"
		end,
		padAllowed = {}, -- property write only
	},
	{
		name = "tempo",
		seq = function(pred)
			return MENU_IS_EXIT[pred] and { 19, 19, -84 } or { 19, -84 }
		end,
		want = function(s)
			return s.tempoMode
		end,
		padAllowed = {},
	},
	{
		name = "swing",
		seq = function(pred)
			return MENU_IS_EXIT[pred] and { 19, 19, -85 } or { 19, -85 }
		end,
		want = function(s)
			return s.swingMode
		end,
		padAllowed = {},
	},
	{
		name = "qlink",
		seq = function()
			return { 98 }
		end,
		want = function(s)
			return s.qlinkMode
		end,
		padAllowed = { Twist = true },
	},
	{
		name = "drums",
		seq = function()
			return { 96 }
		end,
		want = function(s, pred)
			if pred == "pads" then
				return s.padsMode and s.padsLayout == "pads64" -- flip in place
			elseif pred == "pads64" or pred == "keys" then
				return not s.padsMode and not s.keysPage -- cycle exits
			end
			return s.padsMode and s.padsLayout == "drum"
		end,
		padAllowed = {}, -- grid inert (notes routed to the MPC pads)
	},
	{
		name = "keys",
		seq = function()
			return { 97 }
		end,
		want = function(s, pred)
			if pred == "keys" then
				return not s.keysPage and not s.padsMode -- toggle leaves
			end
			return s.keysPage and s.padsMode
		end,
		padAllowed = {},
	},
}

for _, pred in ipairs(PREDS) do
	for _, opener in ipairs(OPENERS) do
		local label = pred.name .. " -> " .. opener.name
		L.OnUnload()
		L.OnLoad()
		for _, v in ipairs(pred.seq) do
			if v < 0 then
				pad(-v)
			else
				press(v)
			end
		end
		inv1("pred " .. pred.name)
		-- phase call-logs for INV2: reset() swaps in a fresh table each time, the
		-- captured references keep their phase's bindings (adds here, removes later)
		local predCalls = mock.calls
		mock.reset()

		for _, v in ipairs(opener.seq(pred.name)) do
			if v < 0 then
				pad(-v)
			else
				press(v)
			end
		end
		local openerCalls = mock.calls
		local s = L.STATE()
		inv1(label)
		check(opener.want(s, pred.name), label .. ": unexpected end state "
			.. "pads=" .. tostring(s.padsMode) .. " keys=" .. tostring(s.keysPage)
			.. " mixer=" .. tostring(s.mixerMode) .. " adjust=" .. tostring(s.adjustMode)
			.. " tempo=" .. tostring(s.tempoMode) .. " swing=" .. tostring(s.swingMode)
			.. " qlink=" .. tostring(s.qlinkMode))

		-- INV3: the owner decides. Two representative pads, bottom-left + top-right.
		mock.reset()
		mock.tracks[0].Volume.value = 0.5 -- normalize persisted writes
		mock.resetQlinkPositions() -- normalize persisted knob positions
		local volBefore = mock.tracks[0].Volume.value
		local endedClosed = not (s.mixerMode or s.adjustMode or s.tempoMode or s.swingMode
			or s.qlinkMode or s.padsMode)
		-- the opener's allowlist applies while its page owns the grid; a combo that
		-- ends closed must launch clips (that IS the owner's action)
		local allowed = endedClosed and { TriggerClip = true } or opener.padAllowed
		pad(11)
		pad(88)
		local fx = forbiddenCount(allowed)
		check(fx == 0, label .. ": INV3 pad press leaked another page's effect (" .. fx .. " forbidden calls)")
		if opener.name == "adjust" then
			check(mock.tracks[0].Volume.value ~= volBefore, label .. ": INV3 adjust pad did not write the volume")
		end
		if opener.name == "qlink" then
			check(mock.count("Twist") >= 1, label .. ": INV3 qlink pad did not twist")
		end
		if opener.name == "mixer" then
			check(mock.count("SetCurrentTrack") == 1, label .. ": INV3 mixer select row did not select")
		end
		if endedClosed then
			-- the clip grid must work again
			check(mock.count("TriggerClip") == 2, label .. ": INV3 closed state did not launch clips ("
				.. mock.count("TriggerClip") .. "/2)")
		end

		-- INV4: the window never moves while a page or pads own the grid.
		-- (The mixer is the documented exception: its columns follow the window.)
		mock.reset()
		press(91)
		press(92)
		press(93)
		press(94)
		if opener.name ~= "mixer" then
			local moves = mock.count("MoveUp") + mock.count("MoveDown")
				+ mock.count("MoveLeft") + mock.count("MoveRight")
			local pageOwns = s.mixerMode or s.adjustMode or s.tempoMode or s.swingMode or s.qlinkMode or s.padsMode
			if pageOwns then
				check(moves == 0, label .. ": INV4 window moved under a page (" .. moves .. ")")
			end
		end

		-- INV5: Session is the universal escape -> clean clip state.
		mock.reset()
		press(95)
		inv1(label .. " +session")
		local t = L.STATE()
		local anyOpen = t.mixerMode or t.adjustMode or t.tempoMode or t.swingMode or t.qlinkMode
			or t.padsMode or t.keysPage
		check(not anyOpen, label .. ": INV5 session left a page open")
		-- INV2 over checkpoint + current calls (reset() clears the log)
		local function total(name)
			return mock.countIn(predCalls, name) + mock.countIn(openerCalls, name) + mock.count(name)
		end
		check(total("AddNoteToMpcPad") == total("RemoveNoteToMpcPad"),
			label .. ": INV2 mpc-pad bindings unbalanced (+" .. total("AddNoteToMpcPad")
			.. "/-" .. total("RemoveNoteToMpcPad") .. ")")
		check(total("AddNoteToVirtualPad") == total("RemoveNoteToVirtualPad"),
			label .. ": INV2 virtual-pad bindings unbalanced (+" .. total("AddNoteToVirtualPad")
			.. "/-" .. total("RemoveNoteToVirtualPad") .. ")")
		mock.reset()
		pad(11)
		check(mock.count("TriggerClip") == 1, label .. ": INV5 clip grid broken after escape")
	end
end

if failed > 0 then
	error("test-state-matrix: " .. failed .. " invariant violation(s)")
end
print("test-state-matrix: PASS")
