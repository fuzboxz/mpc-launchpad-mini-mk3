-- tests/test-pad-modes.lua: MPC pads mode (CC 96 drums).
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

-- Grid notes of pads mode: the bottom-left 4x4 quadrant.
local PAD_NOTES = { 11, 12, 13, 14, 21, 22, 23, 24, 31, 32, 33, 34, 41, 42, 43, 44 }

L.OnLoad()

-- The drums button is available (lighter grey); the user button is off without qlinks in use.
assert_eq(mock.leds[96][1], 60, "drums button available")

-- Enter pads mode (CC 96): the 16 quadrant notes move from the script to the MPC pads.
-- A stopped clip sits under note 85 (grid col 4, MPC row 0) so the mode visibly darks it;
-- two timer ticks land the enter on an even tick.
mock.clips[4] = { [0] = "stopped" }
L.HandleTimer()
L.HandleTimer()
mock.reset()
L.HandleMIDICC(0, 96, 127)
assert_eq(mock.count("AddNoteToMpcPad"), 16, "16 pads bound")
-- notes STAY script-bound now: the script binding consumes them from the host's
-- MIDI-input feed (device report: pads double-fed a track listening on our port)
assert_eq(mock.count("RemoveNoteToScript"), 0, "notes stay bound to the script")
for i, note in ipairs(PAD_NOTES) do
	local add = mock.find("AddNoteToMpcPad")[i]
	assert_eq(add.args[1], 0, "pads enter channel " .. i)
	assert_eq(add.args[2], note, "pads enter note " .. i)
	assert_eq(add.args[3], i - 1, "pads enter pad index " .. i)
end
assert_eq(mock.leds[96][1], 127, "drums button white in pads mode")
assert_eq(mock.leds[85][1], 0, "pad outside the quadrant went dark")

-- LED mirror: the refresh runs on even ticks (every 2 ticks = 100 ms).
mock.mpc.controlSurface.pads[0].Colour.value = 0x00FF0000 -- red
mock.mpc.controlSurface.pads[5].Colour.value = 0x11223344 -- alpha byte ignored
L.HandleTimer() -- tick 3 (odd): no mirror refresh yet (pad 0 stays dark from mode enter)
assert_eq(mock.leds[11] and mock.leds[11][1] or -1, 0, "mirror waits for the 100 ms refresh (no resend)")
L.HandleTimer() -- tick 4 (even): mirror refresh
assert_eq(mock.leds[11][1], 127, "pad 0 red mirrored")
assert_eq(mock.leds[22][1], 16, "pad 5 r scaled")
assert_eq(mock.leds[22][2], 25, "pad 5 g scaled")
assert_eq(mock.leds[22][3], 33, "pad 5 b scaled")

-- Diff-only sends: changing one pad resends only that pad.
mock.reset()
mock.mpc.controlSurface.pads[0].Colour.value = 0x0000FF00 -- green
L.HandleTimer() -- tick 5 (odd)
L.HandleTimer() -- tick 6 (even): only pad 0 changed
assert_eq(mock.leds[11][2], 127, "pad 0 now green")
assert_eq(mock.leds[22], nil, "unchanged pad 5 not resent (diff-only)")

-- The scene column keeps working; grid pads are inert in pads mode.
mock.reset()
L.HandleMIDICC(0, 89, 127)
assert_eq(mock.count("TriggerRow"), 1, "scene launch works in pads mode")
L.HandleMIDINoteOn(0, 85, 100)
assert_eq(mock.count("TriggerClip"), 0, "grid pads inert in pads mode")

-- Mutual exclusion: opening the mixer exits pads mode...
mock.reset()
L.HandleMIDICC(0, 19, 127)
assert_eq(mock.count("RemoveNoteToMpcPad"), 16, "mixer exits pads mode")
assert_eq(mock.leds[96][1], 60, "drums button back to available")
-- ...and the mixer's volume pad opens the fader menu
local v0 = mock.tracks[0].Volume.value
L.HandleMIDINoteOn(0, 81, 100) -- volume
L.HandleMIDICC(0, 91, 127)
assert_eq(mock.count("MoveUp"), 0, "up is a menu nudge while the menu is open")
assert(mock.tracks[0].Volume.value ~= v0, "menu nudge changed the volume")

-- ...and entering pads mode closes the fader menu.
L.HandleMIDICC(0, 96, 127)
assert_eq(mock.count("AddNoteToMpcPad"), 16, "pads mode re-entered from the menu")
assert_eq(L.STATE().adjustMode, nil, "pads mode closes the fader menu")
-- the window must not move under pads mode either (the grid is not the window)
L.HandleMIDICC(0, 91, 127)
L.HandleMIDICC(0, 93, 127)
assert_eq(mock.count("MoveUp") + mock.count("MoveLeft"), 0, "window frozen while pads mode owns the grid")

-- Drums cycles the layout in place: quadrant -> 64 pads -> off.
mock.reset()
L.HandleMIDICC(0, 96, 127) -- still in quadrant mode: flip to 64 pads
assert_eq(mock.count("AddNoteToVirtualPad"), 64, "flip binds all 64 virtual pads")
assert_eq(mock.count("RemoveNoteToMpcPad"), 16, "flip releases the quadrant bindings")
assert_eq(mock.leds[96][3], 127, "drums button cyan in the 64-pad layout")
L.HandleMIDINoteOn(0, 85, 100) -- grid pads play virtual pads, not clips
assert_eq(mock.count("TriggerClip"), 0, "64-pad grid does not launch clips")
L.HandleMIDICC(0, 96, 127) -- second in-mode press: exit
assert_eq(mock.count("RemoveNoteToMpcPad"), 16, "exit releases the quadrant bindings")
assert_eq(mock.count("RemoveNoteToVirtualPad"), 64, "exit releases the virtual bindings")
assert_eq(mock.count("AddNoteToScript"), 0, "script bindings were never removed")
assert_eq(mock.leds[96][1], 60, "drums button back to available")
L.HandleMIDINoteOn(0, 11, 100)
assert_eq(mock.count("TriggerClip"), 1, "clip launch restored after pads exit")

-- Degrade: without mappings.pads the drums button stays off and nothing breaks.
local padsMapping = mock.dev.mappings.pads
mock.dev.mappings.pads = nil
mock.reset()
L.HandleMIDICC(0, 96, 127)
assert_eq(mock.leds[96][1], 0, "drums button off without mappings.pads")
assert_eq(mock.count("AddNoteToMpcPad"), 0, "no pad binding without mappings.pads")
L.HandleMIDINoteOn(0, 11, 100)
assert_eq(mock.count("TriggerClip"), 1, "clip launch still works after failed pads mode")
mock.dev.mappings.pads = padsMapping

-- Unload while pads mode is active: the notes are handed back before unmapping.
L.HandleMIDICC(0, 96, 127)
mock.reset()
L.OnUnload()
assert_eq(mock.count("RemoveNoteToMpcPad"), 16, "unload exits pads mode")
assert_eq(mock.count("AddNoteToScript"), 0, "unload does not re-add (notes were never unbound)")
assert_eq(mock.count("RemoveNoteToScript"), 64, "unload unmaps the grid notes")

-- CC 97 opens the MPC's Pad Perform page AND takes the grid into pads mode,
-- so the surface matches the screen (no clip launches from the grid).
L.OnUnload() -- zero the LED cache; reload with a clean slate
L.OnLoad()
mock.reset()
L.HandleMIDICC(0, 97, 127) -- keys -> pads mode (drum track: plain kit play)
assert_eq(mock.count("padPerform.Press"), 0, "no Pad Perform on a drum track (chords mangle kits)")
assert_eq(mock.count("AddNoteToMpcPad"), 16, "keys enters pads mode (quadrant)")
L.HandleMIDINoteOn(0, 11, 100)
assert_eq(mock.count("TriggerClip"), 0, "grid plays pads, not clips, on the keys page")
-- pressing Keys again leaves: Pad Perform toggled OFF, pads mode off, Main
L.HandleMIDICC(0, 97, 127)
assert_eq(mock.count("RemoveNoteToMpcPad"), 16, "keys exit releases the quadrant bindings")
assert_eq(mock.count("AddNoteToScript"), 0, "script bindings were never removed")
assert_eq(mock.count("padPerform.Press"), 0, "drum-track keys never touches Pad Perform")
assert_eq(mock.count("main.Press"), 2, "main pressed on keys enter (pad view) and exit")

-- Melodic track (Plugin): Keys engages Pad Perform chords, exit toggles them off.
-- The virtual press opens the Pad Perform DIALOG on 3.10.1, which blocks every
-- other button via the popup guard — it must be closed (and ONLY ours).
mock.mpc.tracks.currentTrack.Type:set("Plugin")
mock.reset()
local function tick2()
	L.HandleTimer()
	L.HandleTimer() -- the deferred padPerform press lands two ticks later
end
L.HandleMIDICC(0, 97, 127) -- keys -> pads mode + Pad Perform
tick2()
assert_eq(mock.count("padPerform.Press"), 1, "melodic keys engages Pad Perform (deferred)")
assert_eq(mock.count("CloseCurrentPopup"), 0, "the Pad Perform page STAYS OPEN on enter (it is the feature's UI)")
-- with the page open, OUR dialog must not block other buttons (guard carve-out):
-- drums from the keys page sweeps Pad Perform away and leaves pads mode (keys
-- pre-arms the exit), all through the open "Pad Perform" popup
mock.setPopup("Pad Perform")
mock.reset()
L.HandleMIDICC(0, 96, 127)
assert_eq(mock.count("RemoveNoteToMpcPad"), 16, "drums leaves the keys page despite our open page")
assert_eq(mock.count("padPerform.Press"), 1, "the sweep toggles the mode off")
assert_eq(mock.count("CloseCurrentPopup"), 1, "the sweep closes our page")
assert_eq(mock.mpc.engineMode.GetCurrentPopup(), "No Popup", "page closed")
-- re-enter keys from the clip grid (the 'from any other place' repro): engages again
L.HandleMIDICC(0, 97, 127)
tick2()
assert_eq(mock.count("padPerform.Press"), 2, "re-entry engages Pad Perform again")
assert_eq(mock.count("CloseCurrentPopup"), 1, "still no close on enter")
L.HandleMIDICC(0, 97, 127) -- leave
tick2()
assert_eq(mock.count("padPerform.Press"), 3, "exit toggles off (deferred)")
assert_eq(mock.count("CloseCurrentPopup"), 2, "exit closes the page")

-- THE DEVICE RULE: the page stays open only while keys owns AND the track is
-- melodic. Switching to a drum track while the page is open drops the chords
-- (kit play remains) and closes the page.
mock.mpc.tracks.currentTrack.Type:set("Plugin")
L.HandleMIDICC(0, 97, 127) -- enter keys (melodic)
tick2()
local closedBefore = mock.count("CloseCurrentPopup")
mock.setPopup("Pad Perform") -- our page is open
L.HandleTimer() -- tick: still melodic -> stays open
assert_eq(mock.count("CloseCurrentPopup"), closedBefore, "page stays open on a melodic track")
mock.mpc.tracks.currentTrack.Type:set("Drum") -- the track becomes a kit
L.HandleTimer() -- tick: demotion fires
assert_eq(mock.count("padPerform.Press") >= 1, true, "chords toggled off on the drum switch")
assert_eq(mock.count("CloseCurrentPopup"), closedBefore + 1, "page closed on the drum switch")
assert_eq(L.STATE().keysPage, true, "keys page still owns (kit play)")
L.HandleMIDICC(0, 97, 127) -- leave the (now drum-track) keys page for the sections below
tick2()
mock.setPopup("No Popup")
mock.mpc.tracks.currentTrack.Type:set("Drum")
-- with the dialog closed, the other buttons stay live
assert_eq(L.STATE().keysPage, false, "keys page left")
L.HandleMIDICC(0, 95, 127)
assert_eq(mock.count("TriggerClip"), 0, "session works after the keys round trip")
-- a dialog we did NOT open is never dismissed
mock.setPopup("New Project")
mock.reset()
L.HandleMIDICC(0, 19, 127)
assert_eq(mock.count("CloseCurrentPopup"), 0, "foreign dialogs are never closed")
assert_eq(mock.mpc.engineMode.GetCurrentPopup(), "New Project", "New Project dialog stays")
mock.setPopup("No Popup")
mock.mpc.tracks.currentTrack.Type:set("Drum")

-- ASYNC dialog (the device report): the dialog opens a beat AFTER the exit
-- press. The watch window closes it, and the surface stays live.
mock.mpc.tracks.currentTrack.Type:set("Plugin")
mock.reset()
L.HandleMIDICC(0, 97, 127) -- keys -> chords
tick2()
L.HandleMIDICC(0, 97, 127) -- leave
tick2()
assert_eq(mock.count("padPerform.Press"), 2, "on+off presses")
mock.setPopup("Pad Perform") -- the dialog lands late, AFTER the keys page ended
L.HandleTimer() -- watcher tick: inside the window
assert_eq(mock.mpc.engineMode.GetCurrentPopup(), "No Popup", "late dialog closed by the watcher")
L.HandleMIDICC(0, 95, 127) -- session works: no guard block
assert_eq(L.STATE().keysPage, false, "no keys page")

-- PROACTIVE SWEEP (fault tolerance): a desynced/stuck Pad Perform (popup open,
-- our flags already clear) is swept away by ANY mode switch — session, drums,
-- user, menu — while the clean path presses nothing extra.
mock.setPopup("Pad Perform") -- stuck: flags clear, dialog owns the UI
mock.reset()
L.HandleMIDICC(0, 95, 127) -- session
assert_eq(mock.count("CloseCurrentPopup"), 1, "session sweeps the stuck dialog")
assert_eq(mock.count("padPerform.Press"), 1, "session toggles the stuck mode off")
assert_eq(mock.mpc.engineMode.GetCurrentPopup(), "No Popup", "popup cleared")
-- drums sweep
mock.setPopup("Pad Perform")
mock.reset()
L.HandleMIDICC(0, 96, 127)
assert_eq(mock.count("CloseCurrentPopup"), 1, "drums sweeps the stuck dialog")
-- user sweep
mock.setPopup("Pad Perform")
mock.reset()
L.HandleMIDICC(0, 98, 127)
assert_eq(mock.count("CloseCurrentPopup"), 1, "user sweeps the stuck dialog")
-- clean path: no popup, no flags -> no extra presses
mock.reset()
L.HandleMIDICC(0, 95, 127)
assert_eq(mock.count("padPerform.Press"), 0, "clean path presses nothing")
mock.mpc.tracks.currentTrack.Type:set("Drum")
L.HandleMIDINoteOn(0, 11, 100)
assert_eq(mock.count("TriggerClip"), 1, "clip launch restored after keys exit")

-- Session still returns to the clip grid from the keys page (page exclusivity).
mock.reset()
L.HandleMIDICC(0, 97, 127) -- keys page again
L.HandleMIDICC(0, 95, 127) -- session -> clip mode
assert_eq(mock.count("RemoveNoteToMpcPad"), 16, "session exits the keys pads mode")
assert_eq(mock.count("TriggerClip"), 0, "session did not trigger anything")

L.OnUnload()
print("test-pad-modes: PASS")
