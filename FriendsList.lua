----------------------------------------------------------------------
-- ZugZug Keys — Friends List Overlay
-- Reads each WoW-playing BNet friend's custom message, parses our key
-- broadcast format ("+19 Seat of the Triumvirate Started: 8:48 PM.
-- Finished~: 9:22 PM"), and shows the keystone level + estimated
-- finish time on the friends list entry.
--
-- Defensive: WoW's friends list internals have moved across patches,
-- so this module degrades silently if expected refs/methods are missing.
----------------------------------------------------------------------

local Keys = _G.ZugZugKeys

local OVERLAY_KEY = "_zzkOverlay"
local WOW_CLIENT  = BNET_CLIENT_WOW or "WoW"
local THROTTLE    = 0.25     -- coalesce bursts of refresh calls

----------------------------------------------------------------------
-- Parse the broadcast string into { level, dungeon, finish }
----------------------------------------------------------------------

--- Parse a ZugZug broadcast. Returns:
---   running: { state="running", level, dungeon, finish }   (in-progress key)
---   done:    { state="done",    level, dungeon, time }     (just-completed key)
---   nil if neither format matches.
local function parseBroadcast(text)
  if type(text) ~= "string" or text == "" then return nil end

  -- In-progress: "+<lvl> <dungeon> Started: <start>. Finished~: <finish>"
  local level, dungeon, finish = text:match(
    "^%+(%d+)%s+(.-)%s+Started:%s+.-%.%s+Finished~:%s+(.+)$"
  )
  if level then
    return { state = "running", level = tonumber(level), dungeon = dungeon, finish = finish }
  end

  -- Completed: "+<lvl> <dungeon> Done in <m:ss> (ZugZug ...)"
  -- The trailing "(ZugZug M+)" / "(ZugZug Keys)" disambiguates our own
  -- broadcasts from other addons' or user-typed messages.
  local lvl, dung, took = text:match(
    "^%+(%d+)%s+(.-)%s+Done in%s+([%d:]+)%s+%(ZugZug"
  )
  if lvl then
    return { state = "done", level = tonumber(lvl), dungeon = dung, time = took }
  end

  return nil
end

Keys.parseBroadcast = parseBroadcast  -- exposed for tests / other modules

----------------------------------------------------------------------
-- Per-button overlay management
----------------------------------------------------------------------

local function ensureOverlay(button)
  local fs = button[OVERLAY_KEY]
  if fs then return fs end
  fs = button:CreateFontString(nil, "OVERLAY")
  fs:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
  fs:SetJustifyH("RIGHT")
  fs:SetWordWrap(false)
  -- Sit to the left of the game-icon column (W badge + favorite/social
  -- buttons take ~50px on the right). Right-anchored + right-justified so
  -- variable-length strings always end at the same x.
  fs:SetPoint("RIGHT", button, "RIGHT", -56, 0)
  fs:SetDrawLayer("OVERLAY", 7)
  button[OVERLAY_KEY] = fs
  return fs
end

local function setOverlay(button, text)
  if text then
    local fs = ensureOverlay(button)
    fs:SetText(text)
    fs:Show()
  elseif button[OVERLAY_KEY] then
    button[OVERLAY_KEY]:Hide()
  end
end

local function formatOverlay(parsed)
  if parsed.state == "done" then
    -- Muted level + soft green completion time so it reads as past-tense.
    return string.format("|cff888888+%d|r |cff7ea832done %s|r", parsed.level, parsed.time)
  end
  -- Bright level + warm yellow finish time for an in-progress key.
  return string.format("|cff8fbf3f+%d|r |cffffd078~%s|r", parsed.level, parsed.finish)
end

----------------------------------------------------------------------
-- Resolve a button → BNet account info
----------------------------------------------------------------------

local FRIENDS_BUTTON_TYPE_BNET_VALUE = _G.FRIENDS_BUTTON_TYPE_BNET or 2

local function accountInfoFromData(data)
  if not data then return nil end
  -- In modern WoW the friends-list entry stores the 1-based BNet friend
  -- INDEX in data.id (with buttonType == FRIENDS_BUTTON_TYPE_BNET == 2).
  -- GetFriendAccountInfo correctly reads whoever currently occupies that
  -- index, which is what we want when the list reorders.
  if data.buttonType == FRIENDS_BUTTON_TYPE_BNET_VALUE
      and data.id and C_BattleNet and C_BattleNet.GetFriendAccountInfo then
    local info = C_BattleNet.GetFriendAccountInfo(data.id)
    if info then return info end
  end
  -- Explicit BNet account-ID fields (some entry shapes).
  local accountID = data.bnetIDAccount or data.bnetAccountID
  if accountID and C_BattleNet and C_BattleNet.GetAccountInfoByID then
    local info = C_BattleNet.GetAccountInfoByID(accountID)
    if info then return info end
  end
  -- Generic index fallback.
  local index = data.index or data.buttonIndex or data.friendIndex
  if index and C_BattleNet and C_BattleNet.GetFriendAccountInfo then
    return C_BattleNet.GetFriendAccountInfo(index)
  end
end

local function accountInfoForButton(button)
  if button.GetElementData then
    local data = button:GetElementData()
    -- Some scroll views nest the real data under .data
    local info = accountInfoFromData(data) or accountInfoFromData(data and data.data)
    if info then return info end
  end
  -- Legacy / fallback: button might carry the index directly.
  local idx = button.index or button.friendIndex
  if idx and C_BattleNet and C_BattleNet.GetFriendAccountInfo then
    return C_BattleNet.GetFriendAccountInfo(idx)
  end
end

----------------------------------------------------------------------
-- Annotate one visible button
----------------------------------------------------------------------

local function annotateButton(button)
  local info = accountInfoForButton(button)
  if not info then return setOverlay(button, nil) end

  local game = info.gameAccountInfo
  if not game or game.clientProgram ~= WOW_CLIENT then
    return setOverlay(button, nil)
  end

  local parsed = parseBroadcast(info.customMessage)
  if not parsed then return setOverlay(button, nil) end

  setOverlay(button, formatOverlay(parsed))
end

----------------------------------------------------------------------
-- Find the friends list scroll box across WoW versions
----------------------------------------------------------------------

--- Candidate paths in priority order. Each entry is a list of keys to walk
--- starting from _G. The first path that resolves to a frame with a
--- ScrollBox child wins. We return (scrollBox, container).
local SCROLLBOX_PATHS = {
  { "FriendsListFrame" },                          -- TWW
  { "FriendsFrame", "FriendsList" },               -- some intermediate patches
  { "ContactsFrame" },                             -- Midnight rename (best guess)
  { "ContactsFrame", "FriendsList" },              -- Midnight nested
  { "ContactsFrame", "Contents" },                 -- Midnight nested alt
  { "ContactsFrame", "Contents", "FriendsList" },  -- Midnight nested alt 2
}

local function resolvePath(path)
  local node = _G
  for _, key in ipairs(path) do
    node = node and rawget(node, key)
    if not node then return nil end
  end
  return node
end

local function findFriendsScrollBox()
  for _, path in ipairs(SCROLLBOX_PATHS) do
    local container = resolvePath(path)
    if container then
      local sb = rawget(container, "ScrollBox")
      if sb and sb.ForEachFrame then return sb, container end
      -- Some containers nest a level deeper.
      if container.Contents and container.Contents.ScrollBox and container.Contents.ScrollBox.ForEachFrame then
        return container.Contents.ScrollBox, container.Contents
      end
    end
  end
end

----------------------------------------------------------------------
-- Refresh visible buttons (throttled)
----------------------------------------------------------------------

local pendingRefresh, lastRefreshAt = false, 0

local function refreshNow()
  pendingRefresh = false
  lastRefreshAt = GetTime()
  if not ZugZugKeysDB or not ZugZugKeysDB.friendsListOverlay then return end
  local sb = findFriendsScrollBox()
  if not sb then return end
  sb:ForEachFrame(annotateButton)
end

local function scheduleRefresh()
  if pendingRefresh then return end
  pendingRefresh = true
  local since = GetTime() - lastRefreshAt
  local delay = (since >= THROTTLE) and 0 or (THROTTLE - since)
  C_Timer.After(delay, refreshNow)
end

Keys.RefreshFriendsListOverlay = refreshNow

----------------------------------------------------------------------
-- Hookup
----------------------------------------------------------------------

local hooked = false
local function tryHook()
  if hooked then return end
  local sb, container = findFriendsScrollBox()
  if not sb then return end

  -- Primary hook: ScrollUtil fires this for every button bound to (or
  -- recycled to display) a different element. This is critical — without
  -- it, when the scrollbox reuses a button for a different friend, the
  -- previous occupant's overlay text stays visible.
  if _G.ScrollUtil and ScrollUtil.AddInitializedFrameCallback then
    local ok = pcall(ScrollUtil.AddInitializedFrameCallback, sb, function(frame)
      annotateButton(frame)
    end, "ZugZugKeys", true)  -- 4th arg = callOnRecycle
    if ok then hooked = true end
  end

  -- Secondary hook: catches data-range changes (scrolling). Cheap insurance
  -- in case the rebind callback misses a case.
  if sb.RegisterCallback then
    if sb.Event and sb.Event.OnDataRangeChanged then
      pcall(sb.RegisterCallback, sb, sb.Event.OnDataRangeChanged, scheduleRefresh, "ZugZugKeys")
    end
    pcall(sb.RegisterCallback, sb, "OnDataRangeChanged", scheduleRefresh, "ZugZugKeys")
  end
  if container and container.HookScript then
    container:HookScript("OnShow", function() scheduleRefresh() end)
  end
  if _G.FriendsFrame_Update then
    hooksecurefunc("FriendsFrame_Update", scheduleRefresh)
  end
  hooked = true
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("FRIENDLIST_UPDATE")
frame:RegisterEvent("BN_FRIEND_INFO_CHANGED")
frame:RegisterEvent("BN_CUSTOM_MESSAGE_CHANGED")
frame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    -- Friends UI typically loads on first open. Try now (works if it's
    -- already loaded by another addon) and again whenever any event below
    -- fires after the user opens it.
    if _G.SocialFrame_LoadUI then pcall(SocialFrame_LoadUI) end
    tryHook()
    return
  end
  tryHook()
  scheduleRefresh()
end)
