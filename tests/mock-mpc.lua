-- tests/mock-mpc.lua: a minimal MPC 3.10.1 API mock for the controller script.
-- Records every call; decodes the LPMINI LED sysex into M.leds[index] = {r,g,b}.
local M = { calls = {}, leds = {} }

local function record(name, ...)
	M.calls[#M.calls + 1] = { name = name, args = { ... } }
end
M.record = record

local function prop(v)
	local p = { value = v, listeners = {} }
	function p:listen(fn, name)
		record("listen", name)
		self.listeners[#self.listeners + 1] = fn
	end
	function p:stopListening(name)
		record("stopListening", name)
		self.listeners = {}
	end
	function p:set(v)
		self.value = v
		for _, fn in ipairs(self.listeners) do
			fn(v)
		end
	end
	return p
end
M.prop = prop

-- clip matrix
local clips = {}
M.clips = clips
local clipMatrix = {
	HasClip = function(gc, gr)
		return clips[gc] and clips[gc][gr] ~= nil
	end,
	ClipIsPlaying = function(gc, gr)
		return clips[gc] and clips[gc][gr] == "playing"
	end,
	TrackIsRecording = function(gc)
		for _, row in pairs(clips[gc] or {}) do
			if row == "recording" then
				return true
			end
		end
		return false
	end,
	ClipIsRecording = function(gc, gr)
		return clips[gc] and clips[gc][gr] == "recording"
	end,
	ClipIsStopped = function(gc, gr)
		return clips[gc] and clips[gc][gr] == "stopped"
	end,
	GetClipColour = function(gc, gr)
		return 0xFF0000
	end,
	StopAllClips = function()
		record("StopAllClips")
	end,
	DeleteClip = function(gc, gr)
		record("DeleteClip", gc, gr)
	end,
	CopyClip = function(fc, fr, tc, tr)
		record("CopyClip", fc, fr, tc, tr)
	end,
	InsertRowAndCapture = function()
		record("InsertRowAndCapture")
		return true
	end,
}

-- tracks
local tracks = {}
local mockCurrentTrackIndex = 0
-- per-key MIDI input port; the MPC default is the "All Inputs" sentinel
-- (observed on device as 2147483645). SetTrackInputPort updates it so the
-- script's guard discovery loop can read back what it set.
local trackInputPorts = {}
for i = 0, 7 do
	local t = {
		RecArm = prop(false),
		Mute = prop(false),
		Solo = prop(false),
		Colour = prop(0x00FF00),
		Name = prop("Track " .. i),
		Volume = prop(0.5),
		Pan = prop(0.5),
		Send1 = prop(0),
		Send2 = prop(0),
		Send3 = prop(0),
		Send4 = prop(0),
	}
	t.SetRecArm = function(v)
		record("SetRecArm", i, v)
		t.RecArm:set(v)
	end
	t.SetMute = function(v)
		record("SetMute", i, v)
		t.Mute:set(v)
	end
	t.SetSolo = function(v)
		record("SetSolo", i, v)
		t.Solo:set(v)
	end
	tracks[i] = t
end

-- sequencer
local mockBpm = 120
local mockSwing = 50
local sequencer = {
	Play = function()
		record("Play")
	end,
	TogglePlay = function()
		record("TogglePlay")
	end,
	Stop = function()
		record("Stop")
	end,
	Record = function()
		record("Record")
	end,
	Overdub = function()
		record("Overdub")
	end,
	IsPlaying = function()
		return false
	end,
	Loop = prop(false),
	JumpToBeginning = function()
		record("JumpToBeginning")
	end,
	Playing = prop(false),
	RecordState = prop(false),
	OverdubState = prop(false),
	SetMetronomeEnabled = function(v)
		record("SetMetronomeEnabled", v)
	end,
	MetronomeEnabled = prop(false),
	SetBPM = function(bpm)
		record("SetBPM", bpm)
		mockBpm = bpm
	end,
	GetBPM = function()
		return mockBpm
	end,
	quantiser = {
		Enabled = prop(true),
		GetSwing = function()
			return mockSwing
		end,
		SetSwing = function(v)
			record("SetSwing", v)
			mockSwing = v
		end,
		GetEnabled = function()
			return true
		end,
		SetEnabled = function(v)
			record("SetEnabled", v)
		end,
		GetStrength = function()
			return 100
		end,
		SetStrength = function(v)
			record("SetStrength", v)
		end,
		GetTimeDivision = function()
			return "1/16"
		end,
		SetTimeDivision = function(v)
			record("SetTimeDivision", v)
		end,
		GetWindow = function()
			return 100
		end,
		SetWindow = function(v)
			record("SetWindow", v)
		end,
		GetShift = function()
			return 0
		end,
		SetShift = function(v)
			record("SetShift", v)
		end,
	},
}

-- command manager
local commandManager = {
	Undo = function()
		record("Undo")
	end,
	Redo = function()
		record("Redo")
	end,
}

-- per-qlink target names; nil = the default "target<i>" (assigned)
local qlinkTargets = {}
function M.setQlinkTarget(i, name)
	qlinkTargets[i] = name
end

-- mark a qlink as a binary/flip parameter (Thru below 96, Kill above)
local qlinkBinary = {}
function M.setQlinkBinary(i)
	qlinkBinary[i] = true
end

-- Q-Links (mpc.controlSurface.qlinks, 0-based, 16 knobs); SetPosition writes the position,
-- Twist moves it by a delta (clamped 0-127), Touch records a touch.
local qlinkPositions = {}
local qlinks = {}
for i = 0, 15 do
	qlinks[i] = {
		GetPosition = function()
			return qlinkPositions[i] or 0
		end,
		SetPosition = function(pos)
			qlinkPositions[i] = pos
			record("SetPosition", i, pos)
		end,
		Twist = function(delta)
			qlinkPositions[i] = math.max(0, math.min(127, (qlinkPositions[i] or 0) + delta))
			record("Twist", i, delta)
		end,
		Touch = function()
			record("Touch", i)
		end,
		GetValue = function()
			return (qlinkPositions[i] or 0) / 127
		end,
		GetValueString = function()
			local p = qlinkPositions[i] or 0
			if qlinkBinary[i] then
				return p >= 96 and "Kill" or "Thru"
			end
			return tostring(p)
		end,
		GetTargetName = function()
			return qlinkTargets[i] or ("target" .. i)
		end,
	}
end
qlinks.GetNumQLinks = function()
	return 16
end

-- virtual Force buttons (mpc.force.<name>.Press/Release)
local force = {}
for _, name in ipairs({ "copy", "delete" }) do
	force[name] = {
		Press = function()
			record("force." .. name .. ".Press")
		end,
		Release = function()
			record("force." .. name .. ".Release")
		end,
	}
end

-- virtual MPC pad bank (mpc.controlSurface.pads[i].Colour, ARGB int)
local padsControl = {
	Tap = function() end,
	Press = function() end,
	Release = function() end,
	virtual = {},
}
for i = 0, 127 do
	local pcol = prop(0)
	padsControl.virtual[i] = {
		Colour = pcol,
		GetColour = function()
			return pcol.value
		end,
	}
end
for i = 0, 15 do
	local pcol = prop(0)
	padsControl[i] = {
		Colour = pcol,
		GetColour = function()
			return pcol.value
		end,
	}
end

-- aperture + clip properties
local clipProperties = {}
for c = 0, 7 do
	clipProperties[c] = {}
	for r = 0, 7 do
		clipProperties[c][r] = { Colour = prop(0xFF0000), State = prop(2), Selected = prop(false) }
	end
end

local sceneProperties = {}
for r = 0, 7 do
	sceneProperties[r] = { State = prop(2) }
end

local originCol = 0
local originRow = 0
local activeMatrix = "Normal"
local aperture = {
	SetColumns = function(n)
		record("SetColumns", n)
	end,
	SetRows = function(n)
		record("SetRows", n)
	end,
	SetLabel = function(s)
		record("SetLabel", s)
	end,
	SetFollowsTUI = function(b)
		record("SetFollowsTUI", b)
	end,
	Show = function()
		record("Show")
	end,
	Hide = function()
		record("Hide")
	end,
	TriggerClip = function(c, r)
		record("TriggerClip", c, r)
	end,
	TriggerRow = function(r)
		record("TriggerRow", r)
	end,
	StopClipsOnTrack = function(c)
		record("StopClipsOnTrack", c)
	end,
	SelectClip = function(c, r)
		record("SelectClip", c, r)
	end,
	SelectTrack = function(i)
		record("SelectTrack", i)
	end,
	MoveLeft = function(n)
		originCol = originCol - n
		record("MoveLeft", n)
	end,
	MoveRight = function(n)
		originCol = originCol + n
		record("MoveRight", n)
	end,
	MoveUp = function(n)
		originRow = originRow - n
		record("MoveUp", n)
	end,
	MoveDown = function(n)
		originRow = originRow + n
		record("MoveDown", n)
	end,
	-- follow current track: SetActiveMatrix picks the matrix, MoveToColumn takes
	-- a window-local track column
	SetActiveMatrix = function(m)
		activeMatrix = m
		record("SetActiveMatrix", m)
	end,
	MoveToColumn = function(n)
		originCol = n
		record("MoveToColumn", n)
	end,
	ToGlobalColumn = function(c)
		return c + originCol
	end,
	ToGlobalRow = function(r)
		return r + originRow
	end,
	ToLocalColumn = function(i)
		return i - originCol
	end,
	ToLocalRow = function(i)
		return i - originRow
	end,
	clipProperties = clipProperties,
	sceneProperties = sceneProperties,
}

-- mappings
local mappings = {
	script = {
		AddNoteToScript = function(ch, n)
			record("AddNoteToScript", ch, n)
		end,
		AddCCToScript = function(ch, cc)
			record("AddCCToScript", ch, cc)
		end,
		RemoveNoteToScript = function(ch, n)
			record("RemoveNoteToScript", ch, n)
		end,
		RemoveCCToScript = function(ch, cc)
			record("RemoveCCToScript", ch, cc)
		end,
		SetHandleSysex = function(b)
			record("SetHandleSysex", b)
		end,
	},
	pads = {
		AddNoteToMpcPad = function(ch, note, pad)
			record("AddNoteToMpcPad", ch, note, pad)
		end,
		RemoveNoteToMpcPad = function(ch, note, pad)
			record("RemoveNoteToMpcPad", ch, note, pad)
		end,
		AddNoteToVirtualPad = function(ch, note, vpad)
			record("AddNoteToVirtualPad", ch, note, vpad)
		end,
		RemoveNoteToVirtualPad = function(ch, note)
			record("RemoveNoteToVirtualPad", ch, note)
		end,
	},
	tracks = {
		mutes = {
			AddNoteToTrackMute = function(ch, note, track)
				record("AddNoteToTrackMute", ch, note, track)
			end,
			RemoveNoteToTrackMute = function(ch, note, track)
				record("RemoveNoteToTrackMute", ch, note, track)
			end,
		},
	},
	-- MPC-side control routing (e.g. the native Tap Tempo control)
	controlSurface = {
		AddCCToControl = function(ch, cc, name)
			record("AddCCToControl", ch, cc, name)
		end,
		RemoveCCToControl = function(ch, cc)
			record("RemoveCCToControl", ch, cc)
		end,
	},
}

-- midi out
local midiOut = {
	SendMIDINoteOn = function(ch, n, v, p)
		record("SendMIDINoteOn", ch, n, v, p)
	end,
	SendMIDICC = function(ch, cc, v, p)
		record("SendMIDICC", ch, cc, v, p)
	end,
	SendMIDISysex = function(bytes, p)
		record("SendMIDISysex", bytes, p)
		-- decode the LPMINI LED sysex payload: 00 20 29 02 0E 03 <specs>
		if bytes:sub(1, 6) == string.char(0x00, 0x20, 0x29, 0x02, 0x0D, 0x03) then
			local i = 7
			while i <= #bytes do
				local typ = bytes:byte(i)
				local idx = bytes:byte(i + 1)
				if typ == 3 then
					M.leds[idx] = { bytes:byte(i + 2), bytes:byte(i + 3), bytes:byte(i + 4) }
					i = i + 5
				elseif typ == 0 or typ == 2 then
					M.leds[idx] = { typ, bytes:byte(i + 2) }
					i = i + 3
				elseif typ == 1 then
					M.leds[idx] = { typ, bytes:byte(i + 2), bytes:byte(i + 3) }
					i = i + 4
				else
					break
				end
			end
		end
	end,
}

-- timer
local mockNow = 0
local timer = {
	Start = function(ms)
		record("timer.Start", ms)
	end,
	Stop = function()
		record("timer.Stop")
	end,
	Now = function()
		return mockNow
	end,
}

-- assemble
local popupProp = prop("No Popup")
local normalTrackCount = 8
local currentIndex = prop(0)
local mpc = {
	clipMatrix = clipMatrix,
	project = {
		AdvanceGlobalAutomationFilterType = function()
			record("AdvanceGlobalAutomationFilterType")
		end,
	},
	tracks = {
		normalTracks = tracks,
		SizeNormalTracks = function()
			return normalTrackCount
		end,
		GetTrackInputPort = function(key)
			return trackInputPorts[key] or 2147483645 -- All-Inputs sentinel, as read on device
		end,
		SetTrackInputPort = function(key, value)
			record("SetTrackInputPort", key, value)
			trackInputPorts[key] = value
		end,
		GetTrackInputChannel = function(key)
			return 0
		end,
		SetTrackInputChannel = function(key, value)
			record("SetTrackInputChannel", key, value)
		end,
		IsTrackMidiTriggered = function(key)
			return true
		end,
		GetTrackMonitorState = function(key)
			return 2
		end,
		SetTrackMonitorState = function(key, value)
			record("SetTrackMonitorState", key, value)
		end,
		GetCurrentTrackName = function(i)
			return "Track " .. i
		end,
		SetCurrentTrack = function(idx)
			record("SetCurrentTrack", idx)
			currentIndex.value = idx
		end,
		currentTrack = {
			Index = currentIndex,
			Type = prop("Drum"),
			Previous = function()
				record("currentTrack.Previous")
			end,
			Next = function()
				record("currentTrack.Next")
			end,
			PrevPluginPreset = function()
				record("currentTrack.PrevPluginPreset")
			end,
			NextPluginPreset = function()
				record("currentTrack.NextPluginPreset")
			end,
		},
		SizeNormalTracks = function()
			return normalTrackCount
		end,
		GetCount = function()
			return normalTrackCount
		end,
	},
	currentSequence = {
		GetBPM = function()
			return mockBpm
		end,
		SetBPM = function(bpm)
			record("SetBPM", bpm)
			mockBpm = bpm
		end,
		events = {},
	},
	sequencer = sequencer,
	commandManager = commandManager,
	force = force,
	controlSurface = {
		pads = padsControl,
		qlinks = qlinks,
		record = {
			Press = function()
				record("record.Press")
				sequencer.RecordState.value = not sequencer.RecordState.value
			end,
			Release = function()
				record("record.Release")
			end,
		},
		quantizeApply = {
			Press = function()
				record("quantizeApply.Press")
			end,
			Release = function()
				record("quantizeApply.Release")
			end,
		},
		noteRepeat = {
			Press = function()
				record("noteRepeat.Press")
			end,
			Release = function()
				record("noteRepeat.Release")
			end,
		},
		fullLevel = {
			Press = function()
				record("fullLevel.Press")
			end,
			Release = function()
				record("fullLevel.Release")
			end,
		},
		keyboardControl = {
			Press = function()
				record("keyboardControl.Press")
			end,
			Release = function()
				record("keyboardControl.Release")
			end,
		},
		padPerform = {
			Press = function()
				record("padPerform.Press")
				-- device behaviour: the press opens the Pad Perform dialog
				popupProp.value = "Pad Perform"
			end,
			Release = function()
				record("padPerform.Release")
			end,
		},
		main = {
			Press = function()
				record("main.Press")
			end,
			Release = function()
				record("main.Release")
			end,
		},
		stepSeq = {
			Press = function()
				record("stepSeq.Press")
			end,
			Release = function()
				record("stepSeq.Release")
			end,
		},
		stepSeqNext = {
			Press = function()
				record("stepSeqNext.Press")
			end,
			Release = function()
				record("stepSeqNext.Release")
			end,
		},
		save = {
			Press = function()
				record("save.Press")
			end,
			Release = function()
				record("save.Release")
			end,
		},
		bank1 = {
			Press = function()
				record("bank1.Press")
			end,
			Release = function()
				record("bank1.Release")
			end,
		},
	},
	ui = {
		ShowTUIFeedback = function(s)
			record("ShowTUIFeedback", s)
		end,
	},
	engineMode = {
		CurrentMode = prop("clip"),
		CurrentPopup = popupProp,
		GetCurrentMode = function()
			return "clip"
		end,
		GetCurrentPopup = function()
			return popupProp.value
		end,
	},
}

-- settable popup name for tests (the Pad Perform dialog simulation)
popupProp = popupProp or prop("No Popup")
-- ui.popups: CloseCurrentPopup only touches the popup the tests opened
local uiPopups = {
	CloseCurrentPopup = function()
		record("CloseCurrentPopup")
		popupProp.value = "No Popup"
	end,
}
mpc.ui = { popups = uiPopups }

--- set the popup the script will see (tests simulate the Pad Perform dialog)
function M.setPopup(name)
	popupProp.value = name
end

local dev = {
	clipMatrixAperture = aperture,
	clipProperties = clipProperties,
	mappings = mappings,
	midiOut = midiOut,
	timer = timer,
}

M.mpc = mpc
M.dev = dev
M.aperture = aperture
function M.getActiveMatrix()
	return activeMatrix
end
M.clipProperties = clipProperties
M.tracks = tracks
function M.setNormalTrackCount(n)
	normalTrackCount = n
end
M.sequencer = sequencer
M.commandManager = commandManager
M.force = force
M.qlinks = qlinks
M.midiOut = midiOut
M.timer = timer
function M.setNow(n)
	mockNow = n
end

function M.countIn(t, name)
	local n = 0
	for _, c in ipairs(t) do
		if c.name == name then
			n = n + 1
		end
	end
	return n
end

-- set a qlink's target name (tests simulate the MPC's default global
-- Q-Link assignments vs. user-assigned fader parameters)
function M.setQlinkTarget(i, name)
	qlinkTargets[i] = name
end

-- qlink positions persist across script reloads in the mock (like the real
-- device); tests normalize them before asserting Twist behaviour
function M.resetQlinkPositions()
	for k in pairs(qlinkPositions) do
		qlinkPositions[k] = nil
	end
end

function M.reset()
	M.calls = {}
	M.leds = {}
	for k in pairs(qlinkTargets) do
		qlinkTargets[k] = nil
	end
	for k in pairs(qlinkBinary) do
		qlinkBinary[k] = nil
	end
end

function M.find(name)
	local out = {}
	for _, c in ipairs(M.calls) do
		if c.name == name then
			out[#out + 1] = c
		end
	end
	return out
end

function M.count(name)
	return #M.find(name)
end

return M
