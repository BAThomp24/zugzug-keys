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

local function showSnapshot(snap)
  if not snap then return end
  ZugZugKeysDB.pendingKeyInfo = snap
  local w = ensureWidget()
  w.title:SetText(snap.title and snap.title ~= "" and snap.title or "[no title]")
  w.dungeon:SetText(snap.dungeon or "")
  w:Show()
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
    -- Restore the box on reload if there's still a pending entry.
    if ZugZugKeysDB.groupKeyInfo and ZugZugKeysDB.pendingKeyInfo then
      showSnapshot(ZugZugKeysDB.pendingKeyInfo)
    end
    return
  end

  if event == "PLAYER_ENTERING_WORLD" then
    if isInTrackedInstance() then hideKeyInfo() end
    return
  end

  if event == "LFG_LIST_APPLICATION_STATUS_UPDATED" then
    if not ZugZugKeysDB.groupKeyInfo then return end
    local resultID, newStatus = ...
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
