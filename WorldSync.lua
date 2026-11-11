-- WorldSync: helps you and your group end up on the same layer (world copy / shard).
-- 1. When the game offers a world refresh (SHARD_TRANSFER_IMMINENT), a clear prompt shows the
--    countdown and a "Refresh now" button (C_PlayerInteractionManager.ShardTransferConfirm, the same
--    call Blizzard's popup uses), greyed out in combat. Blizzard's own message is never hidden.
-- 2. Optional auto-refresh once you're out of combat and on the ground.
-- 3. A chat line (and an optional sound) when a refresh moves you, and when your whole group is on one layer.
-- The group list was removed in v1.1.0 (Blizzard's party frames already mark members on another layer).
-- Commands: /worldsync or /ws (settings) | demo | diag

-- Grey footer at the end of the settings page. Set to "" to leave the spot blank.
local FOOTER = "ReflectedReverb Addons"

-- The footer row: a section header without the hover tooltip every header gets (it would only repeat
-- the text). The settings list reuses rows for other headers, so the row's mouse settings come back when it lets go.
local function footerInitializer()
	local init = CreateSettingsListSectionHeaderInitializer("|cff8c8c8c" .. FOOTER .. "|r")
	local initFrame, resetter = init.InitFrame, init.Resetter
	local mouse = {} -- row -> its mouse settings before the footer turned them off
	function init:InitFrame(frame)
		initFrame(self, frame)
		if not mouse[frame] then
			mouse[frame] = { frame:IsMouseClickEnabled(), frame:IsMouseMotionEnabled() }
		end
		frame:EnableMouse(false)
	end
	function init:Resetter(frame)
		local was = mouse[frame]
		if was then -- put back exactly what the row had, for the header that reuses it
			frame:SetMouseClickEnabled(was[1])
			frame:SetMouseMotionEnabled(was[2])
			mouse[frame] = nil
		end
		resetter(self, frame)
	end
	return init
end

local AUTO_DELAY = 3 -- seconds out of combat before an automatic refresh
local STALE_OFFER = 120 -- seconds past the countdown before an offer the game never ended is let go


local DEFAULTS = {
	prompt = true,
	autoRefresh = false,
	togetherAlert = true, -- chat line when everyone is together
	togetherSound = "none",
	moveAlert = true, -- chat line when you're moved to a new layer
	moveSound = "none",
}

-- Alert sounds. "kit" plays a SoundKit ID with PlaySound; "file" plays a sound file ID with PlaySoundFile.
-- Picking one in the settings plays it once as a preview.
local SOUNDS = {
	{ key = "none", label = "No sound" },
	{ key = "jobsdone", label = "Peon: \"Work complete\"", file = 558132 },
	{ key = "readytowork", label = "Peon: \"Ready to work\"", file = 558137 },
	{ key = "peonyes1", label = "Peon: \"I can do that\"", file = 558136 },
	{ key = "peonyes2", label = "Peon: \"Be happy to\"", file = 558139 },
	{ key = "peonyes3", label = "Peon: \"Work work\"", file = 558147 },
	{ key = "peonyes4", label = "Peon: \"Okie dokie\"", file = 558140 },
	{ key = "zugzug", label = "Orc: \"Zug zug\"", file = 541399 },
	{ key = "dabu", label = "Orc: \"Dabu\"", file = 541424 },
	{ key = "timeforkilling", label = "Grunt: \"For killing\"", file = 551331 },
	{ key = "coins", label = "Coins", file = 567413 },
	{ key = "readycheck", label = "Ready check chime", kit = 8960 },
	{ key = "raidwarning", label = "Raid warning", kit = 8959 },
}
local SOUND_BY_KEY = {}
for _, sound in ipairs(SOUNDS) do
	SOUND_BY_KEY[sound.key] = sound
end

local function playAlertSound(key)
	local sound = SOUND_BY_KEY[key]
	if not sound then
		return
	end
	if sound.kit then
		PlaySound(sound.kit, "Master")
	elseif sound.file then
		PlaySoundFile(sound.file, "Master")
	end
end

-- Saved settings of the group list, removed on 2026-11-11: deleted at login so nothing is left behind.
-- Phase reasons that mean "on another layer": Sharding (1), and RuleSet (5, new in Forever 1.60.1, undocumented).
-- Which one Forever reports for a member on another layer isn't confirmed yet (/ws diag prints it), so both count.
local LAYER_REASON = { [1] = true, [5] = true }
local REMOVED_SETTINGS = { "listMode", "joinSeconds", "inRaids", "listPoint" }

local db
local promptFrame
local category
local wasApart = false
local refreshOffered = false
local refreshEndsAt
local demo = false
local endDemo -- set in the demo section

local function say(...)
	print("|cff88ddaaWorldSync:|r", ...)
end

local function isSecret(value)
	return issecretvalue and issecretvalue(value)
end

-- Dev builds (the local copy) log everything. The packager comments the block below out of release
-- zips, so players' builds keep DEV = false. Normal code must never depend on anything in a debug block.
local DEV = false
--@debug@
DEV = true
--@end-debug@
local LOG_MAX = 300

-- Troubleshooting log, saved with the settings (written on /reload or logout). Always on in dev builds;
-- players can turn it on with /ws diag log for a bug report. Never names: unit slots and classes only.
local function log(kind, fields)
	if not (DEV or db.debugLog) then
		return
	end
	if type(db.log) ~= "table" then -- (saved data is untrusted: start a fresh log rather than fail)
		db.log = {}
	end
	local _, instanceType = IsInInstance()
	local entry = {
		time = date("%Y-%m-%d %H:%M:%S"), kind = kind,
		combat = InCombatLockdown() or nil,
		dead = UnitIsDeadOrGhost("player") or nil,
		instance = instanceType ~= "none" and instanceType or nil,
		group = IsInRaid() and "raid" or (IsInGroup() and "party" or nil),
	}
	for k, v in pairs(fields or {}) do
		entry[k] = v
	end
	db.log[#db.log + 1] = entry
	-- Trim in batches (let it reach 375, cut back to 300 in one move) rather than shifting every entry each time.
	local n = #db.log
	if n > LOG_MAX * 1.25 then
		local excess = n - LOG_MAX
		for i = 1, n - excess do -- a plain loop: WoW's Lua 5.1 has no table-move function
			db.log[i] = db.log[i + excess]
		end
		for i = n - excess + 1, n do
			db.log[i] = nil
		end
	end
end

-- Whether log() will record anything. Check this before building log-only data, so players pay nothing.
local function logging()
	return DEV or (db and db.debugLog) or false
end

-- Fail-safes. Every entry point (game events, timers, the prompt's buttons and countdown, the AddOns
-- menu) runs through Guard. A part that errors switches itself off for the rest of the session and is logged;
-- nothing else stops. Only the prompt says so in chat, because Blizzard's own refresh message is then the way
-- to refresh (WorldSync never hides it). /ws diag lists what's off; /reload tries again.
local Guard = { off = {}, errors = 0 }
function Guard.fail(part, err)
	Guard.errors = Guard.errors + 1
	if Guard.off[part] then
		return
	end
	Guard.off[part] = tostring(err)
	pcall(log, "error", { part = part, err = tostring(err):sub(1, 240) })
	if part == "prompt" then
		if promptFrame then
			pcall(promptFrame.Hide, promptFrame)
		end
		say("the refresh prompt hit a problem and is off until you /reload. Blizzard's own message on the left "
			.. "of the screen still works.")
	end
end
-- fn wrapped for `part`: does nothing once that part is off; an error switches the part off.
function Guard.wrap(part, fn)
	if type(fn) ~= "function" then
		return fn
	end
	return function(...)
		if Guard.off[part] then
			return
		end
		local ok, err = pcall(fn, ...)
		if not ok then
			Guard.fail(part, err)
		end
	end
end
-- Wraps a frame's existing scripts.
function Guard.scripts(frame, part, ...)
	for i = 1, select("#", ...) do
		local name = select(i, ...)
		if frame and frame:GetScript(name) then
			frame:SetScript(name, Guard.wrap(part, frame:GetScript(name)))
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Group: is anyone on another layer?
----------------------------------------------------------------------------------------------------

local demoMoved -- set in the demo section; called when Refresh now is clicked during the demo
local checkEvents -- dev log only: events behind the group check now running (see scheduleGroupCheck)

-- One cheap pass, only on group events (bursts merged) and only while you're in a group: the game's phase
-- reason for each member, and the roster's zone names (no map lookups). The game only reports a phase
-- difference for members in your zone, so "together" also needs every online member in your zone.
-- Returns: anyone apart, everyone here (in your zone with no difference), number of other members.
local function groupState()
	if not IsInGroup() then
		return false, false, 0, 0
	end
	local raid = IsInRaid()
	local n = raid and GetNumGroupMembers() or GetNumSubgroupMembers()
	local myZone = GetRealZoneText()
	local zones -- party only: roster zone by name, filled only when someone isn't visible
	local anyApart, allHere, others, offline = false, true, 0, 0
	for i = 1, n do
		local unit = raid and ("raid" .. i) or ("party" .. i)
		if UnitExists(unit) and not UnitIsUnit(unit, "player") then
			others = others + 1
			if not UnitIsConnected(unit) then
				offline = offline + 1
			else
				local reason = UnitPhaseReason(unit)
				if isSecret(reason) then
					allHere = false
				elseif LAYER_REASON[reason] then -- another layer: what a world refresh fixes
					anyApart, allHere = true, false
				elseif reason then -- quest phasing, War Mode, a different ruleset: not ours to fix, nor "together"
					allHere = false
				else
					local visible = UnitIsVisible(unit)
					if (isSecret(visible) or not visible) and raid then
						local ok, _, _, _, _, _, _, zone = pcall(GetRaidRosterInfo, i) -- raidN is roster index N
						if not ok or not zone or isSecret(zone) or zone ~= myZone or myZone == "" then
							allHere = false
						end
					elseif isSecret(visible) or not visible then
						if not zones then
							zones = {}
							for r = 1, GetNumGroupMembers() do
								local ok, name, _, _, _, _, _, zone = pcall(GetRaidRosterInfo, r)
								if ok and name and zone and not isSecret(name) and not isSecret(zone) then
									zones[name] = zone
									zones[(name:match("^[^-]+"))] = zones[(name:match("^[^-]+"))] or zone
								end
							end
						end
						local name, realm = UnitName(unit)
						local zone
						if name and not isSecret(name) then
							zone = (realm and realm ~= "" and not isSecret(realm) and zones[name .. "-" .. realm])
								or zones[name]
						end
						if not zone or zone ~= myZone or myZone == "" then
							allHere = false
						end
					end
				end
			end
		end
	end
	return anyApart, allHere and others > 0, others, offline
end

----------------------------------------------------------------------------------------------------
-- Refresh prompt
----------------------------------------------------------------------------------------------------

local function canRefreshNow()
	if UnitAffectingCombat("player") then
		return false, "You're in combat."
	elseif IsFlying() then
		return false, "You're flying. Land first."
	elseif IsFalling() then
		return false, "You're falling."
	end
	return true
end

local function confirmRefresh(how)
	if demo then
		demoMoved()
		return
	end
	local ok, err = pcall(C_PlayerInteractionManager.ShardTransferConfirm)
	log("confirm", { how = how, callOk = ok, error = not ok and tostring(err) or nil,
		evictionLeft = GetEvictionTimeRemaining() })
	if not ok then
		say("couldn't refresh:", tostring(err), "- use Blizzard's message at the left of the screen.")
	end
end
confirmRefresh = Guard.wrap("prompt", confirmRefresh)

local function createPrompt()
	local f = CreateFrame("Frame", "WorldSyncPrompt", UIParent, "BackdropTemplate")
	f:SetSize(340, 132)
	f:SetPoint("TOP", UIParent, "TOP", 0, -150)
	f:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		edgeSize = 24, insets = { left = 6, right = 6, top = 6, bottom = 6 },
	})
	f:SetBackdropColor(0.05, 0.06, 0.1, 0.95)
	f:SetFrameStrata("DIALOG")
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)

	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	f.title:SetPoint("TOP", 0, -16)
	f.title:SetText("World refresh available")
	f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.text:SetPoint("TOP", f.title, "BOTTOM", 0, -8)
	f.text:SetWidth(300)
	f.countdown = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.countdown:SetPoint("TOP", f.text, "BOTTOM", 0, -4)
	f.status = f:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
	f.status:SetPoint("TOP", f.countdown, "BOTTOM", 0, -6) -- follows the text; the frame is sized in showPrompt

	f.now = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.now:SetSize(130, 24)
	f.now:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -6, 16)
	f.now:SetText("Refresh now")
	f.now:SetScript("OnClick", function()
		confirmRefresh("button")
	end)
	f.later = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.later:SetSize(130, 24)
	f.later:SetPoint("BOTTOMLEFT", f, "BOTTOM", 6, 16)
	f.later:SetText("Later")
	f.later:SetScript("OnClick", function()
		f:Hide()
	end)

	-- The checks below run every frame, so the button and auto-refresh react at once. The two text lines
	-- are only redrawn when what they say changes: the countdown once a second, the status line when its
	-- reason or the auto-refresh second changes.
	local SAFE_TEXT = "|cffaaaaaaBe somewhere safe before refreshing.|r"
	local AUTO_RETRY = 15 -- after an automatic try, wait this long before trying again (the move takes a moment)
	local autoAt, shownLeft, shownStatus, shownOK
	f:SetScript("OnUpdate", function(self)
		local left = refreshEndsAt and math.max(0, refreshEndsAt - GetTime()) or 0
		local leftSeconds = left > 0 and math.floor(left) or -1
		if leftSeconds ~= shownLeft then
			shownLeft = leftSeconds
			if left > 0 then
				self.countdown:SetFormattedText("Automatic refresh in %d:%02d", math.floor(left / 60), left % 60)
			else
				self.countdown:SetText("Can happen at any time now.")
			end
		end
		-- Safety net: after the countdown the move can still come at any time (Blizzard's toast says so too),
		-- but if the game never ends the offer, don't leave the prompt up forever: 2 minutes past the end.
		if left <= 0 and refreshEndsAt and not demo and GetTime() > refreshEndsAt + STALE_OFFER
			and (GetEvictionTimeRemaining() or 0) <= 0 then
			log("offerStale", {})
			refreshOffered, refreshEndsAt = false, nil
			self:Hide()
			return
		end
		local ok, why = canRefreshNow()
		if demo then
			ok, why = true, nil
		end
		if ok ~= shownOK then
			shownOK = ok
			self.now:SetEnabled(ok)
		end
		local status = ok and SAFE_TEXT or why -- a string, or the auto-refresh countdown's seconds
		if db.autoRefresh and not demo then
			if ok then
				autoAt = autoAt or (GetTime() + AUTO_DELAY)
				if GetTime() >= autoAt then
					autoAt = GetTime() + AUTO_RETRY -- one try now; another only if the game hasn't moved you by then
					confirmRefresh("auto")
				else
					status = math.ceil(autoAt - GetTime())
				end
			else
				autoAt = nil
			end
		end
		if status ~= shownStatus then
			shownStatus = status
			if type(status) == "number" then
				self.status:SetFormattedText("|cffffd100Refreshing automatically in %d...|r", status)
			else
				self.status:SetText(status)
			end
		end
	end)
	f:SetScript("OnHide", function()
		autoAt, shownLeft, shownStatus, shownOK = nil, nil, nil, nil
	end)
	f:Hide()
	return f
end

local function showPrompt()
	if not db.prompt and not db.autoRefresh and not demo then
		return
	end
	local scanned, anyApart = pcall(groupState) -- (only the wording depends on it; never let it stop the prompt)
	anyApart = scanned and anyApart
	if demo then
		promptFrame.text:SetText("Demo: one party member is on another layer.")
	elseif anyApart then
		promptFrame.text:SetText("Refreshing should put your group together.")
	else
		promptFrame.text:SetText("The game can move you to another layer.")
	end
	-- Fit the frame to its text: a message that wraps onto two lines makes the prompt taller instead of
	-- pushing the countdown into the line below. The countdown and status are one line each.
	local f = promptFrame
	f:SetHeight(16 + f.title:GetStringHeight() + 8 + f.text:GetStringHeight() + 4 + 14 + 6 + 12 + 12 + 24 + 16)
	promptFrame:Show()
end
showPrompt = Guard.wrap("prompt", showPrompt)

----------------------------------------------------------------------------------------------------
-- Group checks and alerts
----------------------------------------------------------------------------------------------------

-- Logging in or reloading can put you on a layer straight away; that isn't news, so alerts
-- stay quiet for a short while after the first load.
local LOAD_QUIET_SECONDS = 10
local quietUntil = 0

local function inLoadQuiet()
	return GetTime() < quietUntil
end

local function announceTogether(force)
	if inLoadQuiet() and not force then
		return
	end
	if db.togetherAlert then
		say("everyone in your group is on the same layer now.")
	end
	playAlertSound(db.togetherSound)
end
announceTogether = Guard.wrap("alerts", announceTogether)

local apartOffline -- members offline at the last check while someone was apart
local function checkGroup()
	if demo then
		return
	end
	local anyApart, allHere, others, offline = groupState()
	-- Only claim "together" when every online member is in your zone with no difference reported;
	-- someone leaving the zone, or going offline, also clears "apart", but proves nothing.
	if wasApart and not anyApart and allHere and offline <= (apartOffline or 0) then
		announceTogether()
	end
	if anyApart then
		apartOffline = offline
	end
	if anyApart ~= wasApart then
		log("group", { anyApart = anyApart, allHere = allHere, members = others, events = checkEvents })
	end
	wasApart = anyApart
end
checkGroup = Guard.wrap("group", checkGroup)

-- Group events often arrive in bursts (a raid forming, several phase updates at once): handle a burst
-- with one check a moment later instead of one per event. Solo, nothing runs.
local groupCheckPending = false
local pendingEvents = {} -- dev log only: which events led to the next check
local function scheduleGroupCheck(event)
	if not IsInGroup() and not wasApart then
		return
	end
	if event and logging() then
		pendingEvents[event] = (pendingEvents[event] or 0) + 1
	end
	if groupCheckPending then
		return
	end
	groupCheckPending = true
	C_Timer.After(0.2, function()
		groupCheckPending = false
		checkEvents = nil -- set fresh for every check, even if an earlier one errored
		if logging() and next(pendingEvents) then
			local parts = {}
			for name, count in pairs(pendingEvents) do
				parts[#parts + 1] = count > 1 and (name .. "x" .. count) or name
			end
			table.sort(parts)
			checkEvents = table.concat(parts, " ")
		end
		wipe(pendingEvents)
		checkGroup()
		checkEvents = nil
	end)
end
scheduleGroupCheck = Guard.wrap("group", scheduleGroupCheck)

local function onRefreshOffered()
	if demo and endDemo then
		endDemo() -- a real offer beats the demo: real text, real Refresh now
	end
	refreshOffered = true
	local left = GetEvictionTimeRemaining()
	refreshEndsAt = left and left > 0 and (GetTime() + left) or nil
	log("imminent", { evictionLeft = left, inGroup = IsInGroup() })
	showPrompt()
end
onRefreshOffered = Guard.wrap("prompt", onRefreshOffered)

-- The move itself may come with a loading screen, so the alert waits for the world to load
-- (PLAYER_ENTERING_WORLD) or a few seconds, whichever comes first.
local pendingMoveAlert = false
local lastMove = {} -- when and where a refresh last moved you (for the AddOns menu's hover status)

local function moveAlert()
	if not pendingMoveAlert then
		return
	end
	pendingMoveAlert = false
	if not demo then -- (the demo's move isn't a real one)
		lastMove.at, lastMove.zone = GetTime(), GetRealZoneText()
	end
	if db.moveAlert then
		say("you've moved to a new layer.")
	end
	playAlertSound(db.moveSound)
end
moveAlert = Guard.wrap("alerts", moveAlert)

local function onRefreshOver(event)
	refreshOffered = false
	refreshEndsAt = nil
	if promptFrame then
		pcall(promptFrame.Hide, promptFrame)
	end
	log(event == "SHARD_TRANSFER" and "transferred" or "cancelled", {})
	-- (Quiet for 10 s after login or a reload: the game reports landing on a layer as a move, which isn't news.
	-- A refresh accepted within those 10 s goes unannounced; rare, and better than a false line at every login.)
	if event == "SHARD_TRANSFER" and not inLoadQuiet() then
		pendingMoveAlert = true
		C_Timer.After(4, moveAlert)
	end
	C_Timer.After(2, checkGroup)
end
onRefreshOver = Guard.wrap("transfer", onRefreshOver)

----------------------------------------------------------------------------------------------------
-- Demo
----------------------------------------------------------------------------------------------------

-- The demo plays the sequence without a group: a refresh offered (the prompt), the move (at 6 s, or when you
-- click Refresh now) with its message, everyone together 3 s later, then the end at 20 s.
-- Messages and sounds follow your settings; a message that's switched off is noted instead.
local demoRun = 0
local demoMovedOnce = false

local function demoNote(enabled, what)
	if not enabled then
		say("demo: (the \"" .. what .. "\" message is off in the settings)")
	end
end

local function demoTogether(run)
	if not demo or run ~= demoRun then
		return
	end
	demoNote(db.togetherAlert, "Message when together")
	announceTogether(true)
end
demoTogether = Guard.wrap("demo", demoTogether)

local function demoMovedRun()
	if not demo or demoMovedOnce then
		return
	end
	demoMovedOnce = true
	refreshOffered = false
	refreshEndsAt = nil
	promptFrame:Hide()
	demoNote(db.moveAlert, "Message when moved")
	pendingMoveAlert = true
	moveAlert()
	local run = demoRun
	C_Timer.After(3, function()
		demoTogether(run)
	end)
end
demoMoved = Guard.wrap("demo", demoMovedRun)

endDemo = function()
	demoRun = demoRun + 1 -- the demo's pending steps see a newer run and do nothing
	demo, demoMovedOnce = false, false
end

local function runDemo()
	if refreshOffered and not demo then
		say("a real world refresh is on offer right now; try the demo after it.")
		return
	end
	demoRun = demoRun + 1
	local run = demoRun
	demo, demoMovedOnce = true, false
	refreshEndsAt = GetTime() + 125
	refreshOffered = true
	showPrompt()
	say("demo: 20 seconds. Click Refresh now, or wait, to see the move and the messages. Nothing really moves you.")
	C_Timer.After(6, function()
		if demo and run == demoRun then
			demoMoved()
		end
	end)
	C_Timer.After(20, Guard.wrap("demo", function()
		if run ~= demoRun then
			return
		end
		demo = false
		refreshOffered = false
		refreshEndsAt = nil
		promptFrame:Hide()
		checkGroup()
	end))
end
runDemo = Guard.wrap("demo", runDemo)

----------------------------------------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------------------------------------

local function buildPanel()
	local layout
	category, layout = Settings.RegisterVerticalLayoutCategory("WorldSync")
	local function checkbox(key, name, tooltip)
		local s = Settings.RegisterAddOnSetting(category, "WORLDSYNC_" .. key:upper(), key, db,
			Settings.VarType.Boolean, name, DEFAULTS[key])
		return Settings.CreateCheckbox(category, s, tooltip)
	end
	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("World refresh"))
	checkbox("prompt", "Refresh prompt",
		"When the game offers a world refresh, show a centred prompt with the countdown and a Refresh now "
			.. "button, alongside Blizzard's small message on the left.")
	checkbox("autoRefresh", "Auto-refresh when safe",
		"Accepts the world refresh 3 seconds after you're out of combat and not flying or falling. "
			.. "Off by default: a refresh can move you somewhere unexpected.")
	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Alerts"))
	local function soundDropdown(key, name, tooltip)
		local s = Settings.RegisterAddOnSetting(category, "WORLDSYNC_" .. key:upper(), key, db,
			Settings.VarType.String, name, DEFAULTS[key])
		s:SetValueChangedCallback(function(_, value)
			playAlertSound(value) -- preview
		end)
		Settings.CreateDropdown(category, s, function()
			local c = Settings.CreateControlTextContainer()
			for _, sound in ipairs(SOUNDS) do
				c:Add(sound.key, sound.label)
			end
			return c:GetData()
		end, tooltip)
	end
	checkbox("moveAlert", "Message when moved",
		"A line in your chat window (only you see it) after a world refresh moves you to a new layer.")
	soundDropdown("moveSound", "Sound when moved", "Plays after a world refresh moves you. Picking one plays it "
		.. "once so you can hear it.")
	checkbox("togetherAlert", "Message when together",
		"A line in your chat window (only you see it) once every group member is on your layer.")
	soundDropdown("togetherSound", "Sound when together", "Plays once every group member is on your "
		.. "layer. Picking one plays it once so you can hear it.")

	layout:AddInitializer(footerInitializer())
	Settings.RegisterAddOnCategory(category)
end

----------------------------------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------------------------------

--@debug@
-- Dev only (2026-11-11): which copy of the zone nearby NPCs belong to, read from the zone part of their GUID
-- (Creature-0-<server>-<instance>-<zoneUID>-<npcID>-<spawn>), to learn whether a layer change at a zone border
-- can be detected. Logs the first sighting of each zone ID, the "current" one once two different NPCs agree
-- and the old one has been quiet for 3 s (HopAway's rule), zone changes, and refreshes. Event-driven only;
-- commented out of players' builds by the packager. Normal code never depends on it.
do
	local probe = CreateFrame("Frame")
	local uids, count, current = {}, 0, nil -- uids[zoneUID] = { last = t, n = different NPCs, npcs = {} }
	local function observe(unit, source)
		if not db or not unit or not UnitExists(unit) or UnitIsPlayer(unit) then
			return
		end
		local guid = UnitGUID(unit)
		if type(guid) ~= "string" or isSecret(guid) then
			return
		end
		local kind, server, instance, zoneUID, npcID, spawn = guid:match("^(%a+)%-%d+%-(%d+)%-(%d+)%-(%d+)%-(%d+)%-(%x+)$")
		if kind ~= "Creature" and kind ~= "Vehicle" then
			return
		end
		zoneUID = server .. "-" .. instance .. "-" .. zoneUID -- one key for all three, so a change in any shows
		local now = GetTime()
		local u = uids[zoneUID]
		if not u then
			if count >= 60 then -- keep it small on long sessions
				uids, count = {}, 0
			end
			u = { last = now, n = 0, npcs = {} }
			uids[zoneUID] = u
			count = count + 1
			-- (server and instance too: sources disagree on which part holds the layer)
			log("zoneid-new", { id = zoneUID, server = server, instance = instance, current = current,
				zone = GetRealZoneText(), source = source })
		end
		u.last = now
		local key = npcID .. "-" .. spawn
		if not u.npcs[key] then
			u.npcs[key] = true
			u.n = u.n + 1
		end
		local old = current and uids[current]
		if zoneUID ~= current and u.n >= 2 and (not old or now - old.last >= 3) then
			log("zoneid-current", { id = zoneUID, was = current, zone = GetRealZoneText(), npcs = u.n })
			current = zoneUID
		end
	end
	for _, e in ipairs({ "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED",
		"ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD", "SHARD_TRANSFER" }) do
		probe:RegisterEvent(e)
	end
	probe:SetScript("OnEvent", Guard.wrap("probe", function(_, event, unit)
		if event == "PLAYER_TARGET_CHANGED" then
			observe("target", "target")
		elseif event == "UPDATE_MOUSEOVER_UNIT" then
			observe("mouseover", "mouseover")
		elseif event == "NAME_PLATE_UNIT_ADDED" then
			observe(unit, "nameplate")
		elseif db then -- zone change, loading screen or refresh: note which zone ID was current
			log("zoneid-" .. (event == "SHARD_TRANSFER" and "refresh" or "zone"),
				{ event = event, current = current, zone = GetRealZoneText() })
		end
	end))
end
--@end-debug@

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
local onEvent -- below; run through Guard by part (a group-check error never stops the refresh prompt)
-- The end of a refresh is its own part: with the prompt switched off, a move still gets its message and the
-- state ("refresh offered") still clears.
local EVENT_PART = { SHARD_TRANSFER_IMMINENT = "prompt", SHARD_TRANSFER_CANCELLED = "transfer",
	SHARD_TRANSFER = "transfer", PLAYER_LOGIN = "login", PLAYER_LOGOUT = "login" }
local guardedEvents = {}
local function lateGroupCheck() -- a few seconds after a loading screen, once the group's data has arrived
	scheduleGroupCheck("PLAYER_ENTERING_WORLD (3s later)")
end
events:SetScript("OnEvent", function(self, event, ...)
	local part = EVENT_PART[event] or "group"
	local run = guardedEvents[part]
	if not run then
		run = Guard.wrap(part, function(...) return onEvent(...) end)
		guardedEvents[part] = run
	end
	run(self, event, ...)
end)
onEvent = function(self, event, ...)
	if event == "PLAYER_LOGOUT" then
		for key, default in pairs(DEFAULTS) do
			if rawget(db, key) == default then
				db[key] = nil
			end
		end
		return
	end
	if event == "PLAYER_LOGIN" then
		quietUntil = GetTime() + LOAD_QUIET_SECONDS
		-- Saved settings hold only real choices: a setting the player never changed isn't stored, and reads
		-- fall back to the current default. Saved data is untrusted (a crash can damage the file): anything of
		-- the wrong type is dropped. Values equal to their default are dropped here and at logout.
		if type(WorldSyncDB) ~= "table" then
			WorldSyncDB = {}
		end
		db = WorldSyncDB
		for _, key in ipairs(REMOVED_SETTINGS) do
			db[key] = nil
		end
		for key, default in pairs(DEFAULTS) do
			local value = rawget(db, key)
			if value ~= nil and (type(value) ~= type(default) or value == default
				or (type(default) == "string" and key:match("Sound$") and not SOUND_BY_KEY[value])) then
				db[key] = nil
			end
		end
		if db.debugLog ~= nil and type(db.debugLog) ~= "boolean" then
			db.debugLog = nil
		end
		if db.log ~= nil and type(db.log) ~= "table" then
			db.log = nil
		end
		setmetatable(db, { __index = DEFAULTS })
		promptFrame = createPrompt()
		Guard.scripts(promptFrame, "prompt", "OnUpdate", "OnHide", "OnDragStop")
		Guard.scripts(promptFrame.now, "prompt", "OnClick")
		Guard.scripts(promptFrame.later, "prompt", "OnClick")
		local ok, err = pcall(buildPanel)
		if not ok then
			say("settings panel unavailable, use /ws commands.", err)
		end
		-- ZONE_CHANGED_NEW_AREA: crossing into another zone with no loading screen (flying or walking).
		for _, e in ipairs({ "GROUP_ROSTER_UPDATE", "UNIT_PHASE", "UNIT_CONNECTION", "PLAYER_ENTERING_WORLD",
			"ZONE_CHANGED_NEW_AREA", "SHARD_TRANSFER_IMMINENT", "SHARD_TRANSFER_CANCELLED", "SHARD_TRANSFER",
			"PLAYER_LOGOUT" }) do
			self:RegisterEvent(e)
		end
		-- A refresh may already be pending from before a reload.
		local left = GetEvictionTimeRemaining()
		if left and left > 0 then
			onRefreshOffered()
		end
		return
	end
	if event == "SHARD_TRANSFER_IMMINENT" then
		onRefreshOffered()
	elseif event == "SHARD_TRANSFER_CANCELLED" or event == "SHARD_TRANSFER" then
		onRefreshOver(event)
	elseif event == "PLAYER_ENTERING_WORLD" then
		local isInitialLogin, isReloadingUi = ...
		if isInitialLogin or isReloadingUi then
			quietUntil = GetTime() + LOAD_QUIET_SECONDS
			pendingMoveAlert = false
		end
		if pendingMoveAlert then
			C_Timer.After(1, moveAlert)
		end
		C_Timer.After(3, lateGroupCheck)
	else
		scheduleGroupCheck(event)
	end
end

----------------------------------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------------------------------

local function diag()
	local scanned, anyApart, allHere, others = pcall(groupState)
	if not scanned then
		anyApart, allHere, others = "?", "?", "?"
	end
	say("your zone:", tostring(GetRealZoneText()), "| in group:", tostring(IsInGroup()), "| other members:", others,
		"| anyone on another layer:", tostring(anyApart), "| everyone here:", tostring(allHere))
	local raid = IsInRaid()
	for i = 1, (raid and GetNumGroupMembers() or GetNumSubgroupMembers()) do
		local unit = raid and ("raid" .. i) or ("party" .. i)
		if UnitExists(unit) and not UnitIsUnit(unit, "player") then
			say(string.format("  %s: online %s | phase reason %s | visible %s | UnitInPartyShard %s", unit,
				tostring(UnitIsConnected(unit)), tostring(UnitPhaseReason(unit)), tostring(UnitIsVisible(unit)),
				tostring(UnitInPartyShard(unit))))
		end
	end
	say("eviction time remaining:", tostring(GetEvictionTimeRemaining()), "| refresh offered:",
		tostring(refreshOffered))
	local off = {}
	for part, err in pairs(Guard.off) do
		off[#off + 1] = part .. " (" .. err:sub(1, 80) .. ")"
	end
	say("switched off after an error:", #off > 0 and table.concat(off, "; ") or "nothing")
end

SLASH_WORLDSYNC1 = "/worldsync"
SLASH_WORLDSYNC2 = "/ws"
local function runCommand(input)
	local command = strtrim(input or ""):lower()
	if command == "demo" then
		runDemo()
	elseif command == "options" and category then
		Settings.OpenToCategory(category:GetID())
	elseif command == "diag" then
		diag()
	elseif command == "diag log" then
		db.debugLog = not db.debugLog
		say("troubleshooting log:", db.debugLog and "on (saved with your settings; no names)" or "off")
	elseif command == "" and category then
		Settings.OpenToCategory(category:GetID())
	--@debug@
	elseif command == "log" then
		local entries = db.log or {}
		say(#entries, "log entries (newest last; /reload saves them for review):")
		for i = math.max(1, #entries - 19), #entries do
			local e, extra = entries[i], {}
			for k, v in pairs(e) do
				if k ~= "time" and k ~= "kind" then
					extra[#extra + 1] = k .. "=" .. tostring(v)
				end
			end
			table.sort(extra)
			say(e.time:sub(12), e.kind, table.concat(extra, " "))
		end
	elseif command == "log clear" then
		db.log = {}
		say("log cleared.")
	--@end-debug@
	else
		say("commands: /ws (settings) | /ws demo | /ws diag")
	end
end
-- Commands never switch themselves off (they include /ws diag, the way to see what's off): an error is
-- reported and logged, and the next command runs as usual.
SlashCmdList.WORLDSYNC = function(input)
	local ok, err = pcall(runCommand, input)
	if not ok then
		Guard.errors = Guard.errors + 1
		pcall(log, "error", { part = "commands", err = tostring(err):sub(1, 240) })
		say("that command hit a problem:", tostring(err):sub(1, 120))
	end
end

----------------------------------------------------------------------------------------------------
-- Minimap "AddOns" menu (the addon compartment). The TOC names these functions, so they're global.
----------------------------------------------------------------------------------------------------

function WorldSync_OnAddonCompartmentClick()
	if category then
		Settings.OpenToCategory(category:GetID())
	end
end

function WorldSync_OnAddonCompartmentEnter(_, menuButton)
	GameTooltip:SetOwner(menuButton, "ANCHOR_LEFT")
	GameTooltip:SetText("WorldSync", 1, 1, 1)
	if refreshOffered then
		local left = refreshEndsAt and math.max(0, refreshEndsAt - GetTime()) or 0
		GameTooltip:AddLine(left > 0 and string.format("World refresh offered: %d:%02d left", math.floor(left / 60),
			left % 60) or "World refresh offered", 1, 0.82, 0)
	end
	if IsInGroup() then
		local anyApart, allHere = groupState()
		GameTooltip:AddLine(anyApart and "|cffff9933Someone in your group is on another layer|r"
			or (allHere and "|cff55ff55Your group is on your layer|r" or "Group: not everyone is in your zone"))
	else
		GameTooltip:AddLine("Not in a group", 0.6, 0.6, 0.6)
	end
	if lastMove.at then
		local mins = math.floor((GetTime() - lastMove.at) / 60)
		GameTooltip:AddLine(string.format("Last layer change: %s%s", mins < 1 and "just now" or (mins .. " min ago"),
			lastMove.zone and lastMove.zone ~= "" and (", " .. lastMove.zone) or ""), 0.8, 0.8, 0.8)
	end
	GameTooltip:AddLine("Click: settings", 0.6, 0.8, 1)
	GameTooltip:Show()
end

function WorldSync_OnAddonCompartmentLeave()
	GameTooltip:Hide()
end
WorldSync_OnAddonCompartmentClick = Guard.wrap("menu", WorldSync_OnAddonCompartmentClick)
WorldSync_OnAddonCompartmentEnter = Guard.wrap("menu", WorldSync_OnAddonCompartmentEnter)
