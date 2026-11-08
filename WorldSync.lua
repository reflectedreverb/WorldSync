-- WorldSync: helps a party end up in the same world copy (layer / shard).
-- 1. A small list shows which party members are in another world, and why (UnitPhaseReason).
-- 2. When the game offers a world refresh (SHARD_TRANSFER_IMMINENT), a clear prompt shows the
--    countdown and a "Refresh now" button (C_PlayerInteractionManager.ShardTransferConfirm, the same
--    call Blizzard's popup uses), greyed out in combat.
-- 3. Optional auto-refresh once you're out of combat and on the ground.
-- 4. If someone stays apart with no refresh offered, the list shows the known workaround.
-- Commands: /worldsync or /ws | show (or list) | demo | options | diag

-- Grey footer at the end of the settings page. Set to "" to leave the spot blank.
local FOOTER = "ReflectedReverb Addons"

local STUCK_SECONDS = 60 -- apart this long with no refresh offered: show the workaround
local AUTO_DELAY = 3 -- seconds out of combat before an automatic refresh

-- Enum.PhaseReason
local REASON_TEXT = {
	[0] = "different phase (quest or area)",
	[1] = "different world copy",
	[2] = "different War Mode",
	[3] = "different timeline",
	[4] = "different event mode",
	[5] = "different ruleset",
}
local SHARDING = 1

local DEFAULTS = {
	-- "join": when you join a group or someone joins yours, and whenever someone is apart;
	-- "group": always in a group; "apart": only when someone is apart; "never".
	listMode = "never", -- minimal by default; /ws still opens it
	joinSeconds = 30,
	inRaids = false, -- show the list on joins in raid groups too
	prompt = true,
	autoRefresh = false,
	togetherAlert = true, -- chat line when everyone is together
	togetherSound = "none",
	moveAlert = true, -- chat line when you're moved to a new world copy
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
	{ key = "timeforkilling", label = "Grunt: \"Time for killing\"", file = 551331 },
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

local db
local listFrame, promptFrame
local category
local apartSince -- GetTime() when someone first went apart
local wasApart = false
local refreshOffered = false
local joinShowUntil -- GetTime() until which the join window keeps the list shown
local refreshEndsAt
local demo = false

local function say(...)
	print("|cff88ddaaWorldSync:|r", ...)
end

local function isSecret(value)
	return issecretvalue and issecretvalue(value)
end

-- Optional troubleshooting log (off unless turned on with /ws diag log). No names, only party slots.
local function log(kind, fields)
	if not db.debugLog then
		return
	end
	db.log = db.log or {}
	local entry = { time = date("%Y-%m-%d %H:%M:%S"), kind = kind }
	for k, v in pairs(fields or {}) do
		entry[k] = v
	end
	db.log[#db.log + 1] = entry
	while #db.log > 150 do
		table.remove(db.log, 1)
	end
end

local function classColored(name, unit)
	local _, class = UnitClass(unit)
	local color = class and (C_ClassColor and C_ClassColor.GetClassColor(class) or RAID_CLASS_COLORS[class])
	return color and color:WrapTextInColorCode(name) or name
end

----------------------------------------------------------------------------------------------------
-- Who's where
----------------------------------------------------------------------------------------------------

local function groupUnits()
	local units = {}
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			local unit = "raid" .. i
			if UnitExists(unit) and not UnitIsUnit(unit, "player") then
				units[#units + 1] = unit
			end
		end
	elseif IsInGroup() then
		for i = 1, GetNumSubgroupMembers() do
			units[#units + 1] = "party" .. i
		end
	end
	return units
end

-- Zone of each group member by full name, from the roster (works across zones, unlike phase checks).
local function rosterZones()
	local zones = {}
	for i = 1, GetNumGroupMembers() do
		local ok, name, _, _, _, _, _, zone = pcall(GetRaidRosterInfo, i)
		if ok and name and not isSecret(name) and zone and not isSecret(zone) then
			zones[name] = zone
			zones[(name:match("^[^-]+"))] = zones[(name:match("^[^-]+"))] or zone
		end
	end
	return zones
end

-- A unit's zone from its map position: walk up from the most detailed map to the zone level.
-- The game tracks group members' map positions across zones (they show on the world map).
local ZONE_MAP_TYPE = 3 -- Enum.UIMapType.Zone
local function mapZone(unit)
	local ok, mapID = pcall(C_Map.GetBestMapForUnit, unit)
	if not ok or not mapID or isSecret(mapID) then
		return nil
	end
	local info = C_Map.GetMapInfo(mapID)
	local guard = 0
	while info and info.mapType and info.mapType > ZONE_MAP_TYPE and info.parentMapID and info.parentMapID > 0
		and guard < 10 do
		info = C_Map.GetMapInfo(info.parentMapID)
		guard = guard + 1
	end
	if info and info.mapType == ZONE_MAP_TYPE then
		return info.mapID, info.name
	end
	return mapID, info and info.name
end

local function playerZone()
	local _, name = mapZone("player")
	if name then
		return name
	end
	local zone = GetRealZoneText()
	return zone ~= "" and zone or nil
end

-- Returns a list of { unit, name, zone, zoneSource, status, reason, visible } and whether anyone is apart.
-- UnitPhaseReason only reports a difference for members in the same zone, so a member only gets a
-- world-copy verdict once they're confirmed to be in your zone.
local function memberStates()
	local members, anyApart = {}, false
	local zones = rosterZones()
	local myZoneID, myZoneName = mapZone("player")
	local myRealZone = GetRealZoneText()
	for _, unit in ipairs(groupUnits()) do
		local name, realm = UnitName(unit)
		if isSecret(name) or not name then
			name, realm = "?", nil
		end
		local fullName = (realm and realm ~= "" and not isSecret(realm)) and (name .. "-" .. realm) or name
		local entry = { unit = unit, name = name }
		local zoneID, zoneName = mapZone(unit)
		local rosterZone = zones[fullName] or zones[name]
		local sameZone
		if zoneID and myZoneID then
			sameZone = zoneID == myZoneID
			entry.zone, entry.zoneSource = zoneName, "map"
		elseif rosterZone and myRealZone ~= "" then
			sameZone = rosterZone == myRealZone
			entry.zone, entry.zoneSource = rosterZone, "roster"
		end
		local visible = UnitIsVisible(unit)
		entry.visible = not isSecret(visible) and visible or false
		if entry.visible then
			sameZone = true -- you can see them, so they're here
		end
		if not UnitIsConnected(unit) then
			entry.status = "offline"
		elseif sameZone == nil then
			entry.status = "zoneUnknown"
		elseif not sameZone then
			entry.status = "otherZone"
		else
			local reason = UnitPhaseReason(unit)
			if isSecret(reason) then
				entry.status = "unknown"
			elseif reason then
				entry.status = "apart"
				entry.reason = reason
				anyApart = true
			elseif entry.visible then
				entry.status = "nearby"
			else
				entry.status = "sameZone"
			end
		end
		members[#members + 1] = entry
	end
	return members, anyApart
end

local demoMembers -- the demo's made-up party; statuses change as the demo plays out
local demoMoved -- set in the demo section; called when Refresh now is clicked during the demo

local DEMO_MEMBERS = {
	{ name = "Brakk", status = "nearby", zone = "Durotar", class = "WARRIOR" },
	{ name = "Elowen", status = "apart", reason = SHARDING, zone = "Durotar", class = "PRIEST" },
	{ name = "Thistle", status = "otherZone", zone = "The Barrens", class = "DRUID" },
	{ name = "Kaelys", status = "sameZone", zone = "Durotar", class = "MAGE" },
	{ name = "Mordrin", status = "offline", class = "WARLOCK" },
}

----------------------------------------------------------------------------------------------------
-- List frame
----------------------------------------------------------------------------------------------------

local LIST_WIDTH = 260
local ROW_H = 22
local DOT_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

-- Short label and colour per status; zone names stand in for "another zone".
local STATUS_STYLE = {
	nearby = { label = "Here", r = 0.35, g = 0.95, b = 0.4 },
	sameZone = { label = "Same zone", r = 0.6, g = 0.85, b = 0.6 },
	apart = { label = "Other world", r = 1, g = 0.6, b = 0.2 },
	otherZone = { r = 0.5, g = 0.7, b = 1 },
	zoneUnknown = { label = "?", r = 0.6, g = 0.6, b = 0.6 },
	offline = { label = "Offline", r = 0.45, g = 0.45, b = 0.45 },
	unknown = { label = "Hidden", r = 0.6, g = 0.6, b = 0.6 },
}
local STATUS_TIP = {
	nearby = "In your zone and close enough to see: you share a world copy.",
	sameZone = "In your zone, and the game reports no phase or world difference. At long range this "
		.. "may not always be accurate.",
	otherZone = "In another zone. The game only reports world-copy differences within a zone, so meet up to compare.",
	zoneUnknown = "The game isn't giving this member's location right now. Meet up in the same zone to compare.",
	offline = "Offline.",
	unknown = "The game hides this information here.",
}

local function setDotColor(texture, r, g, b)
	texture:SetColorTexture(r, g, b, 1)
end

local function createList()
	local ok, f = pcall(CreateFrame, "Frame", "WorldSyncList", UIParent, "DefaultPanelFlatTemplate")
	if not ok or not f then
		f = CreateFrame("Frame", "WorldSyncList", UIParent, "BackdropTemplate")
		f:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		f:SetBackdropColor(0.04, 0.05, 0.07, 0.9)
	end
	f:SetSize(LIST_WIDTH, 80)
	f:SetFrameStrata("MEDIUM")
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relativePoint, x, y = self:GetPoint(1)
		db.listPoint = { point, relativePoint, x, y }
	end)
	if db.listPoint then
		f:SetPoint(db.listPoint[1], UIParent, db.listPoint[2], db.listPoint[3], db.listPoint[4])
	else
		f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -220)
	end

	local titleText = f.TitleContainer and f.TitleContainer.TitleText
	if titleText then
		titleText:SetText("WorldSync")
	else
		titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		titleText:SetPoint("TOP", 0, -8)
		titleText:SetText("WorldSync")
	end
	f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	f.close:SetPoint("TOPRIGHT", 2, 1)
	f.close:SetScript("OnClick", function()
		f:Hide()
		f.dismissed = true
		f.pinned = false
	end)

	-- Summary: one coloured line you can read at a glance.
	f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontNormalMed2")
	f.summary:SetPoint("TOPLEFT", 14, -32)
	f.summary:SetPoint("RIGHT", -14, 0)
	f.summary:SetJustifyH("LEFT")
	f.you = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.you:SetPoint("TOPLEFT", f.summary, "BOTTOMLEFT", 0, -2)
	f.divider = f:CreateTexture(nil, "ARTWORK")
	f.divider:SetHeight(1)
	f.divider:SetColorTexture(1, 1, 1, 0.12)
	f.divider:SetPoint("TOPLEFT", f.you, "BOTTOMLEFT", 0, -6)
	f.divider:SetPoint("RIGHT", -14, 0)

	f.rows = {}
	f.none = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.none:SetText("Not in a group.")
	f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.hint:SetJustifyH("LEFT")
	f.hint:SetWordWrap(true)
	f.hint:SetWidth(LIST_WIDTH - 28)

	-- Countdown for the join window: a thin bar along the bottom, paused while hovered.
	f.countdown = CreateFrame("StatusBar", nil, f)
	f.countdown:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	f.countdown:SetStatusBarColor(0.5, 0.7, 1, 0.9)
	f.countdown:SetHeight(3)
	f.countdown:SetPoint("BOTTOMLEFT", 14, 10)
	f.countdown:SetPoint("BOTTOMRIGHT", -14, 10)
	f.countdown:SetMinMaxValues(0, 1)
	f.countdown.bg = f.countdown:CreateTexture(nil, "BACKGROUND")
	f.countdown.bg:SetAllPoints()
	f.countdown.bg:SetColorTexture(1, 1, 1, 0.08)
	f.countdownText = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.countdownText:SetPoint("BOTTOMLEFT", f.countdown, "TOPLEFT", 0, 3)
	f.countdown:SetScript("OnUpdate", function(bar, elapsed)
		if not joinShowUntil then
			return
		end
		if f:IsMouseOver() then
			joinShowUntil = joinShowUntil + elapsed -- pause while hovered
			f.countdownText:SetText("Paused while you hover")
		else
			f.countdownText:SetFormattedText("Closes in %ds  |cff777777- hover to keep open|r",
				math.ceil(math.max(0, joinShowUntil - GetTime())))
		end
		bar:SetValue(math.max(0, joinShowUntil - GetTime()) / math.max(1, f.joinTotal or db.joinSeconds))
	end)
	f.countdown:Hide()
	f.countdownText:Hide()
	f:Hide()
	return f
end

local function createRow(parent)
	local row = CreateFrame("Frame", nil, parent)
	row:SetSize(LIST_WIDTH - 28, ROW_H)
	row.hl = row:CreateTexture(nil, "BACKGROUND")
	row.hl:SetAllPoints()
	row.hl:SetColorTexture(1, 1, 1, 0)
	row.classIcon = row:CreateTexture(nil, "ARTWORK")
	row.classIcon:SetSize(16, 16)
	row.classIcon:SetPoint("LEFT", 2, 0)
	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.name:SetPoint("LEFT", row.classIcon, "RIGHT", 6, 0)
	row.name:SetJustifyH("LEFT")
	row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.label:SetPoint("RIGHT", -4, 0)
	row.label:SetJustifyH("RIGHT")
	row.dot = row:CreateTexture(nil, "ARTWORK")
	row.dot:SetSize(8, 8)
	row.dot:SetPoint("RIGHT", row.label, "LEFT", -5, 0)
	local mask = row:CreateMaskTexture()
	mask:SetTexture(DOT_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	mask:SetAllPoints(row.dot)
	row.dot:AddMaskTexture(mask)
	row.name:SetPoint("RIGHT", row.dot, "LEFT", -6, 0)
	row.name:SetWordWrap(false)
	row:SetScript("OnEnter", function(self)
		self.hl:SetColorTexture(1, 1, 1, 0.06)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(self.title or "", 1, 1, 1)
		if self.zone then
			GameTooltip:AddLine(self.zone, 0.7, 0.7, 0.7)
		end
		if self.tip then
			GameTooltip:AddLine(self.tip, 1, 0.82, 0, true)
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function(self)
		self.hl:SetColorTexture(1, 1, 1, 0)
		GameTooltip_Hide()
	end)
	-- A short flash when this member's status changes.
	row.flash = row:CreateTexture(nil, "BACKGROUND", nil, 1)
	row.flash:SetAllPoints()
	row.flash:SetColorTexture(1, 1, 1, 0)
	row.flashAnim = row.flash:CreateAnimationGroup()
	local fadeIn = row.flashAnim:CreateAnimation("Alpha")
	fadeIn:SetFromAlpha(0)
	fadeIn:SetToAlpha(1)
	fadeIn:SetDuration(0.15)
	fadeIn:SetOrder(1)
	local fadeOut = row.flashAnim:CreateAnimation("Alpha")
	fadeOut:SetFromAlpha(1)
	fadeOut:SetToAlpha(0)
	fadeOut:SetDuration(0.6)
	fadeOut:SetOrder(2)
	row.flashAnim:SetToFinalAlpha(true)
	return row
end

local function summaryText(members, anyApart)
	if #members == 0 then
		return "|cffaaaaaaNot in a group|r"
	end
	local apart, elsewhere, here = 0, 0, 0
	for _, m in ipairs(members) do
		if m.status == "apart" then
			apart = apart + 1
		elseif m.status == "otherZone" or m.status == "zoneUnknown" or m.status == "unknown" then
			elsewhere = elsewhere + 1
		elseif m.status == "nearby" or m.status == "sameZone" then
			here = here + 1
		end
	end
	if apart > 0 then
		return string.format("|cffff9933%d in another world copy|r", apart)
	elseif elsewhere > 0 then
		return string.format("|cff88aaff%d elsewhere|r |cffaaaaaa- meet up to compare|r", elsewhere)
	elseif here > 0 then
		return "|cff55ff55All together|r"
	end
	return "|cffaaaaaaEveryone's offline|r"
end

local function updateList(force)
	if not listFrame then
		return
	end
	local members, anyApart
	if demo then
		members, anyApart = demoMembers or DEMO_MEMBERS, false
		for _, m in ipairs(members) do
			if m.status == "apart" then
				anyApart = true
			end
		end
	else
		members, anyApart = memberStates()
	end

	-- Opened by hand (/ws) it stays until closed; otherwise it follows the list setting.
	if force then
		listFrame.pinned = true
	end
	local inJoinWindow = db.listMode == "join" and joinShowUntil and GetTime() < joinShowUntil
	local shouldShow = demo or listFrame.pinned
		or (db.listMode == "group" and #members > 0)
		or ((db.listMode == "apart" or db.listMode == "join") and anyApart)
		or (inJoinWindow and #members > 0)
	if not shouldShow or (listFrame.dismissed and not listFrame.pinned and not demo) then
		listFrame:Hide()
		return
	end

	listFrame.summary:SetText(summaryText(members, anyApart))
	listFrame.you:SetText("You: " .. (demo and "Durotar" or (playerZone() or "?")))

	local y = -70
	for i, m in ipairs(members) do
		local row = listFrame.rows[i] or createRow(listFrame)
		listFrame.rows[i] = row
		local class = m.class or (m.unit and select(2, UnitClass(m.unit)))
		if class and not isSecret(class) then
			row.classIcon:SetAtlas("classicon-" .. class:lower())
			row.classIcon:Show()
		else
			row.classIcon:Hide()
		end
		local color = class and (C_ClassColor and C_ClassColor.GetClassColor(class) or RAID_CLASS_COLORS[class])
		row.name:SetText(color and color:WrapTextInColorCode(m.name) or m.name)
		local style = STATUS_STYLE[m.status] or STATUS_STYLE.zoneUnknown
		local label = style.label or m.zone or "Elsewhere"
		if m.status == "apart" and m.reason ~= SHARDING then
			label = "Other phase"
		end
		row.label:SetText(label)
		row.label:SetTextColor(style.r, style.g, style.b)
		setDotColor(row.dot, style.r, style.g, style.b)
		row.title = m.name
		row.zone = m.zone
		row.tip = STATUS_TIP[m.status]
			or (m.status == "apart" and ("In your zone, but in a " .. (REASON_TEXT[m.reason] or "different phase")
				.. (m.reason == SHARDING and ". A world refresh should bring you together." or ".")))
		if row.lastStatus and row.lastStatus ~= m.status then
			row.flash:SetColorTexture(style.r, style.g, style.b, 0.25)
			row.flashAnim:Restart()
		end
		row.lastStatus = m.status
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 14, y)
		row:Show()
		y = y - ROW_H
	end
	for i = #members + 1, #listFrame.rows do
		listFrame.rows[i]:Hide()
		listFrame.rows[i].lastStatus = nil
	end
	if #members == 0 then
		listFrame.none:ClearAllPoints()
		listFrame.none:SetPoint("TOPLEFT", 16, y - 2)
		listFrame.none:Show()
		y = y - 18
	else
		listFrame.none:Hide()
	end

	local hint
	if refreshOffered then
		hint = "|cffffd100A world refresh is on offer.|r Use the prompt, or click Blizzard's message on the left."
	elseif anyApart and apartSince and GetTime() - apartSince > STUCK_SECONDS then
		hint = "No refresh offered yet. Try: the leader re-invites with /invite <name>, or the other player "
			.. "logs out and back in."
	elseif anyApart then
		hint = "Waiting for the game to offer a world refresh..."
	end
	if hint then
		listFrame.hint:SetText(hint)
		listFrame.hint:ClearAllPoints()
		listFrame.hint:SetPoint("TOPLEFT", 14, y - 6)
		listFrame.hint:Show()
		y = y - 10 - listFrame.hint:GetStringHeight()
	else
		listFrame.hint:Hide()
	end
	-- The countdown only shows when the join window is the only reason the list is open.
	local joinOnly = inJoinWindow and not demo and not listFrame.pinned and not anyApart and db.listMode == "join"
	listFrame.countdown:SetShown(joinOnly)
	listFrame.countdownText:SetShown(joinOnly)
	if joinOnly then
		y = y - 20
	end
	listFrame:SetHeight(-y + 12)
	listFrame:Show()
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
	f.status:SetPoint("BOTTOM", 0, 44)

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

	local autoAt
	f:SetScript("OnUpdate", function(self)
		local left = refreshEndsAt and math.max(0, refreshEndsAt - GetTime()) or 0
		if left > 0 then
			self.countdown:SetFormattedText("Automatic refresh in %d:%02d", math.floor(left / 60), left % 60)
		else
			self.countdown:SetText("Can happen at any time now.")
		end
		local ok, why = canRefreshNow()
		if demo then
			ok, why = true, nil
		end
		self.now:SetEnabled(ok)
		self.status:SetText(ok and "|cffaaaaaaBe somewhere safe before refreshing.|r" or why)
		if db.autoRefresh and not demo then
			if ok then
				autoAt = autoAt or (GetTime() + AUTO_DELAY)
				if GetTime() >= autoAt then
					autoAt = nil
					confirmRefresh("auto")
				else
					self.status:SetFormattedText("|cffffd100Refreshing automatically in %d...|r",
						math.ceil(autoAt - GetTime()))
				end
			else
				autoAt = nil
			end
		end
	end)
	f:SetScript("OnHide", function()
		autoAt = nil
	end)
	f:Hide()
	return f
end

local function showPrompt()
	if not db.prompt and not db.autoRefresh then
		return
	end
	local _, anyApart = memberStates()
	if demo then
		promptFrame.text:SetText("Demo: one party member is in another world copy.")
	elseif anyApart then
		promptFrame.text:SetText("Some of your party are in another world copy. Refreshing should put you together.")
	else
		promptFrame.text:SetText("The game is offering to move you to another world copy.")
	end
	promptFrame:Show()
end

----------------------------------------------------------------------------------------------------
-- Group checks
----------------------------------------------------------------------------------------------------

-- Joining a group, or someone joining yours, shows the list for a while ("join" mode).
local knownMembers -- GUIDs in the group at the last roster check; nil until the first check after login
local joinTimer

local function joinPopupAllowed()
	if db.listMode ~= "join" then
		return false
	end
	local inInstance = IsInInstance()
	if inInstance then
		return false -- dungeons, raids and battlegrounds don't use world copies
	end
	return db.inRaids or not IsInRaid()
end

local function scheduleJoinEnd()
	if joinTimer then
		joinTimer:Cancel()
	end
	joinTimer = C_Timer.NewTimer(math.max(0.1, joinShowUntil - GetTime()), function()
		joinTimer = nil
		-- Hovering pushes joinShowUntil back (see the countdown bar), so check again before closing.
		if GetTime() < joinShowUntil - 0.05 then
			scheduleJoinEnd()
			return
		end
		updateList()
	end)
end

local function startJoinWindow(why)
	if not joinPopupAllowed() then
		return
	end
	joinShowUntil = GetTime() + db.joinSeconds
	listFrame.joinTotal = db.joinSeconds
	listFrame.dismissed = false
	log("joinShow", { why = why })
	scheduleJoinEnd()
end

local function checkRoster()
	local current, newcomer = {}, false
	for _, unit in ipairs(groupUnits()) do
		local guid = UnitGUID(unit)
		if guid and not isSecret(guid) then
			current[guid] = true
			if knownMembers and not knownMembers[guid] then
				newcomer = true
			end
		end
	end
	local hadGroup = knownMembers and next(knownMembers) ~= nil
	local hasGroup = next(current) ~= nil
	if knownMembers and hasGroup then
		if not hadGroup then
			startJoinWindow("you joined a group")
		elseif newcomer then
			startJoinWindow("someone joined")
		end
	end
	knownMembers = current
end

-- Logging in or reloading can put you in a world copy straight away; that isn't news, so alerts
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
		say("everyone in your group is in the same world now.")
	end
	playAlertSound(db.togetherSound)
end

local function checkGroup()
	if demo then
		return
	end
	local members, anyApart = memberStates()
	-- In the join window, once everyone is confirmed together, close a few seconds later.
	if joinShowUntil and GetTime() < joinShowUntil and #members > 0 then
		local allHere = true
		for _, m in ipairs(members) do
			if m.status ~= "nearby" and m.status ~= "sameZone" and m.status ~= "offline" then
				allHere = false
			end
		end
		if allHere and joinShowUntil > GetTime() + 5 then
			joinShowUntil = GetTime() + 5
			listFrame.joinTotal = 5
			scheduleJoinEnd()
		end
	end
	if anyApart and not wasApart then
		apartSince = GetTime()
		if listFrame then
			listFrame.dismissed = false
		end
	end
	if wasApart and not anyApart and #members > 0 then
		apartSince = nil
		-- Only claim "together" when every online member is in your zone with no difference reported;
		-- someone leaving the zone also clears "apart", but proves nothing.
		local allHere = true
		for _, m in ipairs(members) do
			if m.status ~= "nearby" and m.status ~= "sameZone" and m.status ~= "offline" then
				allHere = false
			end
		end
		if allHere then
			announceTogether()
		end
	end
	if anyApart ~= wasApart then
		local reasons = {}
		for _, m in ipairs(members) do
			reasons[#reasons + 1] = m.unit .. "=" .. m.status .. (m.reason and ("/" .. m.reason) or "")
				.. (m.visible and "/visible" or "") .. "/zone:" .. tostring(m.zoneSource)
		end
		log("group", { anyApart = anyApart, members = table.concat(reasons, " ") })
	end
	wasApart = anyApart
	updateList()
end

local function onRefreshOffered()
	refreshOffered = true
	local left = GetEvictionTimeRemaining()
	refreshEndsAt = left and left > 0 and (GetTime() + left) or nil
	log("imminent", { evictionLeft = left, inGroup = IsInGroup() })
	showPrompt()
	updateList()
end

-- The move itself may come with a loading screen, so the alert waits for the world to load
-- (PLAYER_ENTERING_WORLD) or a few seconds, whichever comes first.
local pendingMoveAlert = false

local function moveAlert()
	if not pendingMoveAlert then
		return
	end
	pendingMoveAlert = false
	if db.moveAlert then
		say("you've moved to a new world copy.")
	end
	playAlertSound(db.moveSound)
end

local function onRefreshOver(event)
	refreshOffered = false
	refreshEndsAt = nil
	log(event == "SHARD_TRANSFER" and "transferred" or "cancelled", {})
	if event == "SHARD_TRANSFER" and not inLoadQuiet() then
		pendingMoveAlert = true
		C_Timer.After(4, moveAlert)
	end
	if promptFrame then
		promptFrame:Hide()
	end
	C_Timer.After(2, checkGroup)
end

----------------------------------------------------------------------------------------------------
-- Demo
----------------------------------------------------------------------------------------------------

-- The demo plays the whole sequence with a made-up party: someone apart and a refresh offered,
-- the move (at 6 s, or when you click Refresh now), everyone arriving (3 s later), then the end at 20 s.
-- Messages and sounds follow your settings; a message that's switched off is noted instead.
local demoRun = 0

local function demoNote(enabled, what)
	if not enabled then
		say("demo: (the \"" .. what .. "\" message is off in the settings)")
	end
end

local function demoTogether(run)
	if not demo or run ~= demoRun then
		return
	end
	for _, m in ipairs(demoMembers) do
		if m.status ~= "offline" then
			m.status, m.reason, m.zone = "nearby", nil, "Durotar"
		end
	end
	updateList()
	demoNote(db.togetherAlert, "Message when together")
	announceTogether(true)
end

demoMoved = function()
	if not demo or demoMembers.moved then
		return
	end
	demoMembers.moved = true
	refreshOffered = false
	refreshEndsAt = nil
	promptFrame:Hide()
	updateList()
	demoNote(db.moveAlert, "Message when moved")
	pendingMoveAlert = true
	moveAlert()
	local run = demoRun
	C_Timer.After(3, function()
		demoTogether(run)
	end)
end

local function runDemo()
	demoRun = demoRun + 1
	local run = demoRun
	demo = true
	demoMembers = {}
	for i, m in ipairs(DEMO_MEMBERS) do
		demoMembers[i] = { name = m.name, status = m.status, reason = m.reason, zone = m.zone, class = m.class }
	end
	refreshEndsAt = GetTime() + 125
	refreshOffered = true
	apartSince = GetTime() - STUCK_SECONDS - 1
	updateList()
	showPrompt()
	say("demo: a made-up party for 20 seconds. Click Refresh now, or wait, to see the move and the arrival.")
	C_Timer.After(6, function()
		if demo and run == demoRun then
			demoMoved()
		end
	end)
	C_Timer.After(20, function()
		if run ~= demoRun then
			return
		end
		demo = false
		demoMembers = nil
		refreshOffered = false
		refreshEndsAt = nil
		promptFrame:Hide()
		listFrame:Hide()
		checkGroup()
	end)
end

----------------------------------------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------------------------------------

local function buildPanel()
	local layout
	category, layout = Settings.RegisterVerticalLayoutCategory("WorldSync")
	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Group list"))

	local listSetting = Settings.RegisterAddOnSetting(category, "WORLDSYNC_LISTMODE", "listMode", db,
		Settings.VarType.String, "Show the list", DEFAULTS.listMode)
	listSetting:SetValueChangedCallback(function()
		updateList()
	end)
	local listInit = Settings.CreateDropdown(category, listSetting, function()
		local c = Settings.CreateControlTextContainer()
		c:Add("join", "On join, or when apart")
		c:Add("group", "Always in a group")
		c:Add("apart", "Only when apart")
		c:Add("never", "Never")
		return c:GetData()
	end, "A small, movable list of your group and whether each member is in your world copy.\n\n"
		.. "On join, or when apart: shows when you join a group or someone joins yours, and whenever someone in "
		.. "your zone is in another world copy.\nAlways in a group: shown whenever you're grouped.\n"
		.. "Only when apart: shown only while someone in your zone is in another world copy.\n\n"
		.. "Closing it with the X keeps it closed until the next join or the next time someone is apart. "
		.. "Never: it only opens when you type /ws.")
	-- The join options only matter for the first choice, so they grey out otherwise.
	local function joinModeSelected()
		return db.listMode == "join"
	end

	local joinSetting = Settings.RegisterAddOnSetting(category, "WORLDSYNC_JOINSECONDS", "joinSeconds", db,
		Settings.VarType.Number, "Show after joining for", DEFAULTS.joinSeconds)
	local joinInit = Settings.CreateDropdown(category, joinSetting, function()
		local c = Settings.CreateControlTextContainer()
		c:Add(15, "15 seconds")
		c:Add(30, "30 seconds")
		c:Add(60, "60 seconds")
		return c:GetData()
	end, "How long the list stays after you join a group or someone joins yours. It stays while you hover it, "
		.. "and closes a few seconds after everyone is confirmed together. Only used by \"On join, or when apart\".")
	joinInit:SetParentInitializer(listInit, joinModeSelected)

	local function checkbox(key, name, tooltip)
		local s = Settings.RegisterAddOnSetting(category, "WORLDSYNC_" .. key:upper(), key, db,
			Settings.VarType.Boolean, name, DEFAULTS[key])
		return Settings.CreateCheckbox(category, s, tooltip)
	end
	local raidInit = checkbox("inRaids", "Also for raid groups",
		"Show the list when joining raid groups too. Off by default: raid groups change often, and the list "
			.. "would keep popping up. Never shown inside dungeons, raids or battlegrounds. Only used by "
			.. "\"On join, or when apart\".")
	raidInit:SetParentInitializer(listInit, joinModeSelected)
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
		"A line in your chat window (only you see it) after a world refresh moves you to a new world copy.")
	soundDropdown("moveSound", "Sound when moved", "Plays after a world refresh moves you. Picking one plays it "
		.. "once so you can hear it.")
	checkbox("togetherAlert", "Message when together",
		"A line in your chat window (only you see it) once every group member is in your world copy.")
	soundDropdown("togetherSound", "Sound when together", "Plays once every group member is in your "
		.. "world copy. Picking one plays it once so you can hear it.")

	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("|cff8c8c8c" .. FOOTER .. "|r"))
	Settings.RegisterAddOnCategory(category)
end

----------------------------------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, ...)
	if event == "PLAYER_LOGIN" then
		quietUntil = GetTime() + LOAD_QUIET_SECONDS
		WorldSyncDB = WorldSyncDB or {}
		db = WorldSyncDB
		for key, value in pairs(DEFAULTS) do
			if db[key] == nil then
				db[key] = value
			end
		end
		listFrame = createList()
		promptFrame = createPrompt()
		local ok, err = pcall(buildPanel)
		if not ok then
			say("settings panel unavailable, use /ws commands.", err)
		end
		for _, e in ipairs({ "GROUP_ROSTER_UPDATE", "UNIT_PHASE", "UNIT_CONNECTION", "PLAYER_ENTERING_WORLD",
			"SHARD_TRANSFER_IMMINENT", "SHARD_TRANSFER_CANCELLED", "SHARD_TRANSFER", "PLAYER_REGEN_ENABLED" }) do
			self:RegisterEvent(e)
		end
		-- A refresh may already be pending from before a reload.
		local left = GetEvictionTimeRemaining()
		if left and left > 0 then
			onRefreshOffered()
		end
		C_Timer.NewTicker(5, function()
			if wasApart then
				updateList() -- moves the hint on to the workaround after STUCK_SECONDS
			end
		end)
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
		C_Timer.After(3, function()
			if not knownMembers then
				checkRoster() -- first look after login or reload: remember the group without popping up
			end
			checkGroup()
		end)
	elseif event == "GROUP_ROSTER_UPDATE" then
		if knownMembers then
			checkRoster()
		end
		checkGroup()
	else
		checkGroup()
	end
end)

----------------------------------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------------------------------

local function diag()
	local members, anyApart = memberStates()
	say("your zone:", tostring(playerZone()), "| in group:", tostring(IsInGroup()), "| members:", #members, "| anyone apart:", tostring(anyApart))
	for _, m in ipairs(members) do
		say(string.format("  %s: %s%s | zone: %s (%s) | visible: %s | UnitInPartyShard: %s", m.unit, m.status,
			m.reason and (" (reason " .. m.reason .. ")") or "", tostring(m.zone), tostring(m.zoneSource), tostring(m.visible),
			tostring(UnitInPartyShard(m.unit))))
	end
	say("eviction time remaining:", tostring(GetEvictionTimeRemaining()), "| refresh offered:",
		tostring(refreshOffered))
end

SLASH_WORLDSYNC1 = "/worldsync"
SLASH_WORLDSYNC2 = "/ws"
SlashCmdList.WORLDSYNC = function(input)
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
	elseif command == "" or command == "list" or command == "show" then
		listFrame.dismissed = false
		updateList(true)
	else
		say("commands: /ws or /ws show (show the list) | demo | options")
	end
end
