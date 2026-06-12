----------------------------------------------------------------------
-- ZugZug Keys — Group Key Info
-- Small movable/lockable frame that appears when you join a group via
-- Premade Group Finder. Shows the listing title and dungeon name and
-- stays open until you enter that instance — so the info survives the
-- group disbanding mid-form-up.
----------------------------------------------------------------------

local Keys = _G.ZugZugKeys

-- In-memory snapshot cache keyed by LFG resultID. We capture details when
-- the application is first seen (the listing is still in cache then) and
-- commit to DB only if the application becomes "joined".
local pendingApps = {}

local widget    -- the visible frame (created lazily)

----------------------------------------------------------------------
-- Teleport spell discovery
-- We auto-discover M+ teleport spells from the player's spellbook by
-- matching spell names against the dungeon's name (the same way the
-- player would search "Path of Saron" / "Teleport: Pit of Saron" / etc.).
-- The mapping is cached on PLAYER_LOGIN and refreshed when the spellbook
-- changes (e.g. learning a new teleport).
----------------------------------------------------------------------

-- [lowercased dungeon name] = spellID
local teleportByDungeonLower = {}
-- [mapID] = spellID  (filled best-effort from the same scan)
local teleportByMapID = {}

-- Spell ID table for current-season M+ dungeon teleports, keyed by the
-- challenge mapID. Dynamic name-based discovery isn't possible in 12.0:
--   * legacy global `GetSpellInfo` was removed
--   * `C_Spell.GetSpellInfo(name)` only accepts numeric IDs
--   * achievement-reward teleport spells don't show in C_SpellBook
--     iteration either
-- So we maintain this table by hand each season. Sourced from in-game
-- spell tooltips (verified 2026-06-11 for Midnight Season 1). When a
-- new season ships, the dungeon line-up and spell IDs change — update
-- the entries here and the addon will discover them on next /reload.
local TELEPORT_BY_MAPID = {
  [402] = 393273,   -- Path of the Draconic Diploma (Algeth'ar Academy)
  [239] = 1254551,  -- Path of Dark Dereliction     (Seat of the Triumvirate)
  [556] = 1254555,  -- Path of Unyielding Blight    (Pit of Saron)
  [161] = 159898,   -- Path of the Skies            (Skyreach)
  [560] = 1254559,  -- Path of Cavernous Depths     (Maisara Caverns)
  [559] = 1254563,  -- Path of the Fractured Core   (Nexus-Point Xenas)
  [558] = 1254572,  -- Path of Devoted Magistry     (Magisters' Terrace)
  [557] = 1254400,  -- Path of the Windrunners      (Windrunner Spire)
}

local function normalizeDungeonName(name)
  if type(name) ~= "string" then return "" end
  local s = name:lower()
  -- LFG activity names often include a parenthetical suffix like
  -- "Magisters' Terrace (Mythic Keystone)" — strip those so they
  -- compare equal to the clean dungeon name from C_ChallengeMode.
  s = s:gsub("%b()", "")
  s = s:gsub("'", ""):gsub("[%p]", " "):gsub("%s+", " ")
  s = s:gsub("^%s", ""):gsub("%s$", "")
  return s
end

--- Iterate every M+ challenge map name once so we can match against
--- spellbook entries. Returns { mapID = normalized name }.
local function getChallengeDungeonNames()
  local out = {}
  if not (C_ChallengeMode and C_ChallengeMode.GetMapTable) then return out end
  local ok, maps = pcall(C_ChallengeMode.GetMapTable)
  if not ok or type(maps) ~= "table" then return out end
  for _, mapID in ipairs(maps) do
    local okI, name = pcall(C_ChallengeMode.GetMapUIInfo, mapID)
    if okI and type(name) == "string" and name ~= "" then
      out[mapID] = normalizeDungeonName(name)
    end
  end
  return out
end

-- Words common to many dungeon names that, on their own, don't uniquely
-- identify a single dungeon. We don't fuzzy-match on these.
local TELEPORT_NAME_STOPWORDS = {
  ["the"]=true, ["of"]=true, ["and"]=true, ["to"]=true,
  ["pit"]=true, ["city"]=true, ["palace"]=true, ["chamber"]=true,
  ["temple"]=true, ["court"]=true, ["dawn"]=true, ["dusk"]=true,
  ["dark"]=true, ["high"]=true, ["lower"]=true, ["upper"]=true,
  ["new"]=true, ["old"]=true, ["nexus"]=true, -- ambiguous: Nexus-Point Xenas
  ["point"]=true,
}

--- Look up a spell ID from its display name. We try every API that
--- accepts a name string — different ones work for different categories
--- of spell (achievement rewards behave differently from class spells).
local function spellIDFromName(name)
  if type(name) ~= "string" or name == "" then return nil end
  -- Legacy global. Returns 7 values; the spellID is the 7th return value
  -- (or the last one across versions). Accepts a name string reliably.
  if _G.GetSpellInfo then
    local ok, _, _, _, _, _, _, spellID = pcall(GetSpellInfo, name)
    if ok and type(spellID) == "number" and spellID > 0 then return spellID end
  end
  -- Modern Spell mixin — typically the canonical path in 12.0.
  if _G.Spell and Spell.CreateFromSpellName then
    local ok, spell = pcall(Spell.CreateFromSpellName, name)
    if ok and spell and spell.GetSpellID then
      local id = spell:GetSpellID()
      if type(id) == "number" and id > 0 then return id end
    end
  end
  -- New namespace fallback. Doesn't always accept names but worth a shot.
  if C_Spell and C_Spell.GetSpellInfo then
    local ok, info = pcall(C_Spell.GetSpellInfo, name)
    if ok and type(info) == "table" and type(info.spellID) == "number"
        and info.spellID > 0 then
      return info.spellID
    end
  end
  return nil
end

--- Best-effort check that the player owns a spell. Several APIs report
--- ownership in different ways depending on how the spell was granted
--- (learned, achievement reward, expansion-feature unlock, etc.) so we
--- accept "owned" from any of them. As a last resort, a defined
--- non-zero cooldown duration is a reliable signal — Blizzard only
--- exposes CD for spells the player actually has.
local function isSpellOwned(spellID)
  if not spellID then return false end
  if IsPlayerSpell and IsPlayerSpell(spellID) then return true end
  if IsSpellKnown and IsSpellKnown(spellID) then return true end
  if IsSpellKnown and IsSpellKnown(spellID, true) then return true end
  if C_SpellBook and C_SpellBook.IsSpellInSpellBook
      and C_SpellBook.IsSpellInSpellBook(spellID, Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0) then
    return true
  end
  -- Cooldown-based fallback: a spell the player doesn't own returns a
  -- duration of 0 from GetSpellCooldown. M+ teleports have a 4-hour CD,
  -- so a non-trivial duration is a strong "owned" signal.
  if C_Spell and C_Spell.GetSpellCooldown then
    local info = C_Spell.GetSpellCooldown(spellID)
    if type(info) == "table" and (info.duration or 0) > 60 then
      return true
    end
  end
  return false
end

--- Bind every `TELEPORT_BY_MAPID` entry that the player actually owns
--- into the live lookup tables.
local function discoverTeleports()
  teleportByDungeonLower = {}
  teleportByMapID = {}

  local dungeons = getChallengeDungeonNames()
  for mapID, spellID in pairs(TELEPORT_BY_MAPID) do
    if isSpellOwned(spellID) then
      teleportByMapID[mapID] = spellID
      local dName = dungeons[mapID]
      if dName then teleportByDungeonLower[dName] = spellID end
    end
  end
end

--- Resolve a snapshot to a teleport spell ID, or nil.
local function teleportSpellIDForSnap(snap)
  if type(snap) ~= "table" then return nil end
  -- mapID match only works if the LFG activity's mapID happens to match
  -- the challenge map ID, which usually isn't the case (LFG IDs are in
  -- the 2000-3000 range, challenge IDs are smaller). Try it anyway,
  -- then fall through to dungeon-name matching.
  if snap.mapID and teleportByMapID[snap.mapID] then
    return teleportByMapID[snap.mapID]
  end
  if type(snap.dungeon) == "string" then
    local norm = normalizeDungeonName(snap.dungeon)
    -- Exact normalised match against the names we built at discovery.
    if teleportByDungeonLower[norm] then return teleportByDungeonLower[norm] end
    -- Substring fallback: an LFG listing might add extra qualifiers
    -- ("Magisters' Terrace +20", etc.) that our parenthetical strip
    -- doesn't catch. If either name contains the other, accept it.
    for storedName, spellID in pairs(teleportByDungeonLower) do
      if storedName ~= "" and (norm:find(storedName, 1, true)
          or storedName:find(norm, 1, true)) then
        return spellID
      end
    end
  end
  return nil
end

--- Returns true if the spell is currently usable (known + off CD).
--- Uses the same multi-fallback ownership check as discoverTeleports so
--- achievement-reward teleports — which fail IsPlayerSpell / IsSpellKnown
--- in 12.0 — are still recognised here.
local function isTeleportReady(spellID)
  if not spellID then return false end
  if not isSpellOwned(spellID) then return false end
  if C_Spell and C_Spell.GetSpellCooldown then
    local info = C_Spell.GetSpellCooldown(spellID)
    if type(info) == "table" then
      local remaining = (info.startTime or 0) + (info.duration or 0) - GetTime()
      if (info.duration or 0) > 1.5 and remaining > 0.1 then return false end
    end
  end
  return true
end

----------------------------------------------------------------------
-- Frame
----------------------------------------------------------------------

local function savePosition()
  if not widget then return end
  local point, _, relativePoint, x, y = widget:GetPoint()
  if not point then return end
  ZugZugKeysDB.groupKeyInfoPosition = {
    point = point, relativePoint = relativePoint, x = x, y = y,
  }
end

local function applyPosition()
  if not widget then return end
  widget:ClearAllPoints()
  local pos = ZugZugKeysDB.groupKeyInfoPosition
  if pos and pos.point then
    widget:SetPoint(pos.point, UIParent, pos.relativePoint or pos.point, pos.x or 0, pos.y or 0)
  else
    -- Default: flush against the top-center of the screen.
    widget:SetPoint("TOP", UIParent, "TOP", 0, 0)
  end
end

-- Frame heights: a compact version (title + dungeon text only) and a
-- taller version when a teleport button is showing so the button has
-- its own row without overlapping the dungeon name.
local FRAME_HEIGHT_NO_BUTTON = 76
local FRAME_HEIGHT_WITH_BUTTON = 108

local function buildFrame()
  local f = CreateFrame("Frame", "ZugZugKeysGroupInfo", UIParent, "BackdropTemplate")
  f:SetSize(380, FRAME_HEIGHT_NO_BUTTON)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:SetFrameStrata("MEDIUM")

  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      edgeSize = 14,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.05, 0.07, 0.05, 0.94)
    f:SetBackdropBorderColor(0.40, 0.52, 0.18, 1)  -- darkened ZugZug green
  end

  -- Subtle inner accent line at the top of the content area.
  f.accent = f:CreateTexture(nil, "BORDER")
  f.accent:SetColorTexture(0.56, 0.75, 0.25, 0.55)
  f.accent:SetHeight(1)
  f.accent:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -6)
  f.accent:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

  -- Title (group listing name) — centered, larger, outlined for punch.
  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.title:SetFont(STANDARD_TEXT_FONT, 16, "OUTLINE")
  f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 28, -14)
  f.title:SetPoint("TOPRIGHT", f, "TOPRIGHT", -28, -14)
  f.title:SetJustifyH("CENTER")
  f.title:SetWordWrap(false)
  f.title:SetTextColor(1, 0.96, 0.74)  -- warm cream

  -- Dungeon name — centered, ZugZug green.
  f.dungeon = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.dungeon:SetFont(STANDARD_TEXT_FONT, 14, "")
  f.dungeon:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -8)
  f.dungeon:SetPoint("TOPRIGHT", f.title, "BOTTOMRIGHT", 0, -8)
  f.dungeon:SetJustifyH("CENTER")
  f.dungeon:SetTextColor(0.56, 0.75, 0.25)

  -- Close button — skinned to match the frame
  f.close = CreateFrame("Button", nil, f, "BackdropTemplate")
  f.close:SetSize(20, 20)
  f.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
  if f.close.SetBackdrop then
    f.close:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      edgeSize = 1,
    })
    f.close:SetBackdropColor(0.08, 0.10, 0.08, 1)
    f.close:SetBackdropBorderColor(0.40, 0.52, 0.18, 1)
  end
  f.close.text = f.close:CreateFontString(nil, "OVERLAY")
  f.close.text:SetFont(STANDARD_TEXT_FONT, 14, "OUTLINE")
  f.close.text:SetPoint("CENTER", 0, 1)
  f.close.text:SetText("×")
  f.close.text:SetTextColor(0.85, 0.85, 0.85)
  f.close:SetScript("OnEnter", function(self)
    self:SetBackdropColor(0.18, 0.22, 0.14, 1)
    self.text:SetTextColor(1, 1, 1)
  end)
  f.close:SetScript("OnLeave", function(self)
    self:SetBackdropColor(0.08, 0.10, 0.08, 1)
    self.text:SetTextColor(0.85, 0.85, 0.85)
  end)
  f.close:SetScript("OnClick", function()
    ZugZugKeysDB.pendingKeyInfo = nil
    f:Hide()
  end)

  -- Teleport button — secure action button so it can cast a spell on click.
  -- Hidden unless we've resolved the snapshot's dungeon to a known M+
  -- teleport spell that's off cooldown.
  f.teleport = CreateFrame("Button", "ZugZugKeysTeleportBtn", f,
    "SecureActionButtonTemplate,BackdropTemplate")
  f.teleport:SetSize(110, 22)
  f.teleport:SetPoint("BOTTOM", f, "BOTTOM", 0, 10)
  f.teleport:RegisterForClicks("AnyDown", "AnyUp")
  if f.teleport.SetBackdrop then
    f.teleport:SetBackdrop({
      bgFile   = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      edgeSize = 1,
    })
    f.teleport:SetBackdropColor(0.40, 0.52, 0.18, 0.35)
    f.teleport:SetBackdropBorderColor(0.56, 0.75, 0.25, 0.85)
  end
  f.teleport.text = f.teleport:CreateFontString(nil, "OVERLAY")
  f.teleport.text:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
  f.teleport.text:SetPoint("CENTER")
  f.teleport.text:SetText("Teleport")
  f.teleport.text:SetTextColor(1, 0.96, 0.74)
  f.teleport:SetScript("OnEnter", function(self)
    self:SetBackdropColor(0.56, 0.75, 0.25, 0.55)
    if self.spellID then
      GameTooltip:SetOwner(self, "ANCHOR_LEFT")
      GameTooltip:SetSpellByID(self.spellID)
      GameTooltip:Show()
    end
  end)
  f.teleport:SetScript("OnLeave", function(self)
    self:SetBackdropColor(0.40, 0.52, 0.18, 0.35)
    GameTooltip:Hide()
  end)
  f.teleport:Hide()

  -- Drag handlers (no-op if locked)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self)
    if not ZugZugKeysDB.groupKeyInfoLocked then self:StartMoving() end
  end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    savePosition()
  end)

  f:Hide()
  widget = f
  applyPosition()
  return f
end

local function ensureWidget()
  if not widget then buildFrame() end
  return widget
end

--- Refresh the teleport button's visibility + bound spell. Combat-safe:
--- we only mutate secure attributes outside lockdown. When in combat we
--- leave the button state as-is and let the next out-of-combat refresh
--- catch up.
local function refreshTeleportButton()
  if not widget or not widget.teleport then return end
  local btn = widget.teleport
  if InCombatLockdown() then return end

  local snap = ZugZugKeysDB.pendingKeyInfo
  local spellID = snap and teleportSpellIDForSnap(snap)
  local ready = spellID and isTeleportReady(spellID)

  if ZugZugKeysDB.groupKeyInfoDebug then
    print(string.format(
      "|cffff8800ZZK refreshTeleportButton:|r snap.mapID=%s  snap.dungeon=%q  spellID=%s  ready=%s",
      tostring(snap and snap.mapID),
      tostring(snap and snap.dungeon or ""),
      tostring(spellID),
      tostring(ready)))
  end

  if ready then
    btn:SetAttribute("type", "spell")
    btn:SetAttribute("spell", spellID)
    btn.spellID = spellID
    btn:Show()
    -- Grow the parent frame so the centered button has its own row and
    -- doesn't sit on top of the dungeon-name text.
    widget:SetHeight(FRAME_HEIGHT_WITH_BUTTON)
  else
    btn:SetAttribute("type", nil)
    btn:SetAttribute("spell", nil)
    btn.spellID = nil
    btn:Hide()
    widget:SetHeight(FRAME_HEIGHT_NO_BUTTON)
  end
end

local function showSnapshot(snap)
  if not snap then return end
  ZugZugKeysDB.pendingKeyInfo = snap
  local w = ensureWidget()
  w.title:SetText(snap.title and snap.title ~= "" and snap.title or "[no title]")
  w.dungeon:SetText(snap.dungeon or "")
  w:Show()
  refreshTeleportButton()
end

local function hideKeyInfo()
  ZugZugKeysDB.pendingKeyInfo = nil
  if widget then widget:Hide() end
end

----------------------------------------------------------------------
-- LFG capture
----------------------------------------------------------------------

--- Resolve an activityID to a display name + mapID using whatever API the
--- current client exposes. Returns name, mapID (either may be nil).
local function resolveActivity(activityID)
  if not activityID or not C_LFGList then return nil, nil end
  local name, mapID
  if C_LFGList.GetActivityInfoTable then
    local ok, act = pcall(C_LFGList.GetActivityInfoTable, activityID)
    if ok and type(act) == "table" then
      name = act.fullName or act.shortName
      mapID = act.mapID
    end
  end
  if (not name or name == "") and C_LFGList.GetActivityFullName then
    local ok, n = pcall(C_LFGList.GetActivityFullName, activityID)
    if ok and type(n) == "string" and n ~= "" then name = n end
  end
  if (not name or name == "") and C_LFGList.GetActivityInfo then
    local ok, fullName, shortName = pcall(C_LFGList.GetActivityInfo, activityID)
    if ok then name = fullName or shortName end
  end
  return name, mapID
end

local function snapshotApplication(resultID)
  if not (C_LFGList and C_LFGList.GetSearchResultInfo) then return nil end
  local ok, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
  if not ok or type(info) ~= "table" then return nil end

  local title = info.name
  -- WoW 12.0 listings can expose either `activityID` or `activityIDs` (plural).
  local activityID = info.activityID
  if not activityID and type(info.activityIDs) == "table" then
    activityID = info.activityIDs[1]
  end
  local dungeon, mapID = resolveActivity(activityID)

  -- Final fallback so the dungeon line isn't blank when the listing's
  -- activity is a generic "Mythic+" with no per-dungeon name attached.
  if not dungeon or dungeon == "" then dungeon = "Mythic+" end

  if (not title or title == "") and not dungeon then return nil end
  return { title = title, dungeon = dungeon, mapID = mapID }
end

----------------------------------------------------------------------
-- Public API (called from Settings.lua and slash commands)
----------------------------------------------------------------------

function Keys.HideGroupKeyInfo()
  hideKeyInfo()
end

function Keys.ResetGroupKeyInfoPosition()
  ZugZugKeysDB.groupKeyInfoPosition = nil
  if widget then applyPosition() end
end

function Keys.UpdateGroupKeyInfoFeature()
  -- Called when the master toggle changes. Hide the widget if the feature
  -- was turned off; show stale info if turned back on.
  if not ZugZugKeysDB.groupKeyInfo then
    if widget then widget:Hide() end
    return
  end
  if ZugZugKeysDB.pendingKeyInfo then
    showSnapshot(ZugZugKeysDB.pendingKeyInfo)
  end
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------

local function isInTrackedInstance()
  local saved = ZugZugKeysDB.pendingKeyInfo
  if not saved then return false end
  local inInstance, instanceType = IsInInstance()
  if not (inInstance and instanceType == "party") then return false end
  if saved.mapID then
    local _, _, _, _, _, _, _, instanceMapID = GetInstanceInfo()
    return instanceMapID == saved.mapID
  end
  -- No mapID stored → hide on any party instance entry as a fallback.
  return true
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("LFG_LIST_APPLICATION_STATUS_UPDATED")
-- Hide the popup when the player finishes casting the teleport — that's
-- their explicit "I'm done with this popup" signal. We use a unit-filtered
-- registration so the event ONLY fires for the player's own casts (no
-- party-member noise), which is cheaper than registering globally and
-- filtering on the unit string ourselves.
if frame.RegisterUnitEvent then
  frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
end
frame:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_LOGIN" then
    -- Discover M+ teleport spells lazily so a discovery failure can't
    -- abort the rest of this handler. The popup must work even if no
    -- teleport ever resolves.
    pcall(discoverTeleports)
    -- Restore the box on reload if there's still a pending entry.
    if ZugZugKeysDB.groupKeyInfo and ZugZugKeysDB.pendingKeyInfo then
      showSnapshot(ZugZugKeysDB.pendingKeyInfo)
    end
    return
  end

  if event == "PLAYER_ENTERING_WORLD" then
    if isInTrackedInstance() then hideKeyInfo() end
    pcall(refreshTeleportButton)
    return
  end

  if event == "LFG_LIST_APPLICATION_STATUS_UPDATED" then
    local resultID, newStatus = ...
    if not ZugZugKeysDB.groupKeyInfo then return end
    if not resultID then return end
    if newStatus == "applied" or newStatus == "invited" then
      pendingApps[resultID] = snapshotApplication(resultID) or pendingApps[resultID]
    elseif newStatus == "inviteaccepted" or newStatus == "completed" then
      local snap = pendingApps[resultID] or snapshotApplication(resultID)
      if snap then showSnapshot(snap) end
      pendingApps[resultID] = nil
    elseif newStatus == "declined" or newStatus == "declined_full"
        or newStatus == "declined_delisted" or newStatus == "cancelled"
        or newStatus == "timedout" or newStatus == "failed"
        or newStatus == "invitedeclined" then
      pendingApps[resultID] = nil
    end
    return
  end

  if event == "UNIT_SPELLCAST_SUCCEEDED" then
    -- UNIT_SPELLCAST_SUCCEEDED fires with (unit, castGUID, spellID). We
    -- registered with RegisterUnitEvent("...", "player"), so unit is
    -- always "player" — no need to filter on it. Hide the popup when
    -- the cast was one of the M+ teleports we know about (the same
    -- table KeyInfo's teleport-button discovery uses), so a successful
    -- teleport closes the box automatically.
    local _, _, spellID = ...
    if spellID and TELEPORT_BY_MAPID then
      for _, teleSpellID in pairs(TELEPORT_BY_MAPID) do
        if spellID == teleSpellID then
          hideKeyInfo()
          return
        end
      end
    end
    return
  end
end)
