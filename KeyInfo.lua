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

local function normalizeDungeonName(name)
  if type(name) ~= "string" then return "" end
  local s = name:lower()
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

--- Walk the player's spellbook and bind dungeon names to teleport spell
--- IDs. Match heuristic: the spell name contains the dungeon name as a
--- substring (after normalising punctuation). We also require the spell
--- name to contain a teleport-flavour keyword ("path", "teleport", "warp")
--- so we don't false-match other dungeon-themed spells.
local function discoverTeleports()
  teleportByDungeonLower = {}
  teleportByMapID = {}

  local dungeons = getChallengeDungeonNames()
  if next(dungeons) == nil then return end

  -- Spellbook iteration uses the modern C_SpellBook namespace where
  -- available; the legacy API name still exists in 12.0 as a fallback.
  if not C_SpellBook or not C_SpellBook.GetNumSpellBookSkillLines
      or not C_SpellBook.GetSpellBookSkillLineInfo
      or not C_SpellBook.GetSpellBookItemInfo
      or not Enum or not Enum.SpellBookSpellBank then
    return
  end

  local bank = Enum.SpellBookSpellBank.Player
  local lineCount = C_SpellBook.GetNumSpellBookSkillLines()
  for line = 1, (lineCount or 0) do
    local lineOk, lineInfo = pcall(C_SpellBook.GetSpellBookSkillLineInfo, line)
    if lineOk and type(lineInfo) == "table"
        and type(lineInfo.numSpellBookItems) == "number"
        and type(lineInfo.itemIndexOffset) == "number" then
      for i = 1, lineInfo.numSpellBookItems do
        local slot = lineInfo.itemIndexOffset + i
        local infoOk, info = pcall(C_SpellBook.GetSpellBookItemInfo, slot, bank)
        if infoOk and type(info) == "table" and info.spellID
            and type(info.name) == "string" and info.name ~= "" then
          local lowerName = normalizeDungeonName(info.name)
          if lowerName:find("path", 1, true)
              or lowerName:find("teleport", 1, true)
              or lowerName:find("warp", 1, true) then
            for mapID, dName in pairs(dungeons) do
              if dName ~= "" and lowerName:find(dName, 1, true) then
                teleportByDungeonLower[dName] = info.spellID
                teleportByMapID[mapID] = info.spellID
                break
              end
            end
          end
        end
      end
    end
  end
end

--- Resolve a snapshot to a teleport spell ID, or nil.
local function teleportSpellIDForSnap(snap)
  if type(snap) ~= "table" then return nil end
  if snap.mapID and teleportByMapID[snap.mapID] then
    return teleportByMapID[snap.mapID]
  end
  if type(snap.dungeon) == "string" then
    local norm = normalizeDungeonName(snap.dungeon)
    return teleportByDungeonLower[norm]
  end
  return nil
end

--- Returns true if the spell is currently usable (known + off CD).
local function isTeleportReady(spellID)
  if not spellID then return false end
  if IsPlayerSpell and not IsPlayerSpell(spellID)
      and IsSpellKnown and not IsSpellKnown(spellID) then
    return false
  end
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

local function buildFrame()
  local f = CreateFrame("Frame", "ZugZugKeysGroupInfo", UIParent, "BackdropTemplate")
  f:SetSize(380, 76)
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
  f.teleport:SetSize(78, 20)
  f.teleport:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 8)
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
  if spellID and isTeleportReady(spellID) then
    btn:SetAttribute("type", "spell")
    btn:SetAttribute("spell", spellID)
    btn.spellID = spellID
    btn:Show()
  else
    btn:SetAttribute("type", nil)
    btn:SetAttribute("spell", nil)
    btn.spellID = nil
    btn:Hide()
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
end)
