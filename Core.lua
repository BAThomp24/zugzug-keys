----------------------------------------------------------------------
-- ZugZug Keys — Core
-- Shared key state, dungeon-info cache, and event wiring used by the
-- TimeReply and Status feature modules.
----------------------------------------------------------------------

local ADDON_NAME = ...

ZugZugKeysDB = ZugZugKeysDB or {}

-- Public addon namespace. Feature modules read Keys.state and call Keys.fire().
local Keys = {}
_G.ZugZugKeys = Keys
Keys.addonName = ADDON_NAME

----------------------------------------------------------------------
-- Defaults
----------------------------------------------------------------------

local DEFAULTS = {
  bnStatus = true,                  -- broadcast key start to your Battle.net custom message
  groupKeyInfo = true,              -- show group-title/dungeon box when joining via LFG
  groupKeyInfoLocked = true,        -- lock the group-info box against dragging
  groupKeyInfoPosition = nil,       -- { point, relativePoint, x, y }
  friendsListOverlay = true,        -- show +level/~finish overlay on BNet friends list
  -- Lust Reminder
  lustReminder = false,             -- master toggle (off by default — opt-in via /zzk settings)
  lustReminderLeadPct = 3,          -- fire alert when current forces % >= target - lead
  lustReminderSound = true,         -- play a sound on alert
  lustReminderCuratedFallback = true, -- use curated boss-N fallback when MDT route has no marker
  lustReminderDebug = false,        -- chat-print diagnostic info
  lustReminderSource = "wcl",       -- which call source wins when both exist: "wcl" | "mdt"
  lustReminderAnnounce = true,      -- announce the lust plan to the group on ready check
  lustReminderBarMarks = true,      -- tick marks on the tracker's forces bar at planned lust %s
}
Keys.DEFAULTS = DEFAULTS

local function ensureDefaults()
  for k, v in pairs(DEFAULTS) do
    if ZugZugKeysDB[k] == nil then ZugZugKeysDB[k] = v end
  end
end

----------------------------------------------------------------------
-- Helpers (shared)
----------------------------------------------------------------------

--- Return v only if it's a plain, non-secret number (12.0 Secret Values
--- can pass type() checks in some contexts but explode on use).
function Keys.safeNum(v)
  if issecretvalue and issecretvalue(v) then return nil end
  return (type(v) == "number") and v or nil
end

----------------------------------------------------------------------
-- Shared key state. Feature modules read this; Core owns the updates.
----------------------------------------------------------------------

Keys.state = {
  inActiveKey  = false,
  keyStartTime = nil,     -- GetTime() at CHALLENGE_MODE_START
  keyName      = nil,     -- dungeon name (plain string)
  keyLevel     = nil,     -- keystone level (plain number)
  keyTimeLimit = nil,     -- seconds (plain number)
}

----------------------------------------------------------------------
-- Lightweight pub/sub so feature modules can react to lifecycle events
-- without having to register their own challenge-mode handlers.
----------------------------------------------------------------------

local subscribers = {}

function Keys.on(eventName, fn)
  subscribers[eventName] = subscribers[eventName] or {}
  table.insert(subscribers[eventName], fn)
end

function Keys.fire(eventName, ...)
  local list = subscribers[eventName]
  if not list then return end
  for _, fn in ipairs(list) do
    pcall(fn, ...)
  end
end

----------------------------------------------------------------------
-- Dungeon-info cache: populated from clean reads (out of lockdown) so
-- the time limit + name stay available even if live calls go secret.
----------------------------------------------------------------------

local function cacheMapInfo()
  if not (C_ChallengeMode and C_ChallengeMode.GetMapTable and C_ChallengeMode.GetMapUIInfo) then return end
  ZugZugKeysDB.mapInfoCache = ZugZugKeysDB.mapInfoCache or {}
  local ok, maps = pcall(C_ChallengeMode.GetMapTable)
  if not ok or type(maps) ~= "table" then return end
  for _, mapID in ipairs(maps) do
    local ok2, name, _, timeLimit = pcall(C_ChallengeMode.GetMapUIInfo, mapID)
    if ok2 and Keys.safeNum(timeLimit) and timeLimit > 0 then
      ZugZugKeysDB.mapInfoCache[mapID] = { name = name, limit = timeLimit }
    end
  end
end

--- Capture the active key's static info into plain locals on the state table.
local function captureKeyInfo()
  local s = Keys.state
  s.keyStartTime = GetTime()
  s.inActiveKey = true
  s.keyName, s.keyLevel, s.keyTimeLimit = nil, nil, nil

  -- Persist epoch start so elapsed time on completion survives /reload.
  -- Only set if absent so recovery preserves the real start instead of
  -- overwriting with the reload moment.
  if not ZugZugKeysDB._keyStartEpoch then
    ZugZugKeysDB._keyStartEpoch = time()
  end

  local mapID
  local ok, id = pcall(C_ChallengeMode.GetActiveChallengeMapID)
  if ok then mapID = Keys.safeNum(id) end

  local okL, lvl = pcall(C_ChallengeMode.GetActiveKeystoneInfo)
  if okL then s.keyLevel = Keys.safeNum(lvl) end

  if mapID then
    local okI, name, _, timeLimit = pcall(C_ChallengeMode.GetMapUIInfo, mapID)
    if okI then
      s.keyName = (type(name) == "string") and name or s.keyName
      s.keyTimeLimit = Keys.safeNum(timeLimit) or s.keyTimeLimit
    end
    local cached = ZugZugKeysDB.mapInfoCache and ZugZugKeysDB.mapInfoCache[mapID]
    if cached then
      s.keyName = s.keyName or cached.name
      s.keyTimeLimit = s.keyTimeLimit or cached.limit
    end
  end
end

----------------------------------------------------------------------
-- Lifecycle events
----------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CHALLENGE_MODE_START")
frame:RegisterEvent("CHALLENGE_MODE_RESET")
frame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
frame:SetScript("OnEvent", function(_, event, arg1, ...)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    ensureDefaults()
    return
  end

  if event == "PLAYER_LOGIN" then
    cacheMapInfo()
    return
  end

  if event == "PLAYER_ENTERING_WORLD" then
    local inInstance, instanceType = IsInInstance()
    local s = Keys.state
    if inInstance and instanceType == "party" then
      -- Recover key state if we reloaded mid-key.
      -- Do NOT re-fire keyStart here — BNet's custom message persists across
      -- our own /reloads, so re-broadcasting would just send a duplicate with
      -- the wrong start time (the reload moment instead of the real start).
      -- keyRecovered lets feature modules (LustReminder) re-arm without the
      -- broadcast side effects of keyStart.
      if not s.inActiveKey then
        local ok, id = pcall(C_ChallengeMode.GetActiveChallengeMapID)
        if ok and Keys.safeNum(id) then
          captureKeyInfo()
          Keys.fire("keyRecovered")
        end
      end
    else
      -- If we had a key going (either in-memory or persisted from a prior
      -- session that crashed), treat leaving the dungeon as an abandon so
      -- feature modules can clean up (restore BNet message, etc.).
      if s.inActiveKey or ZugZugKeysDB._keyStartEpoch then
        Keys.fire("keyReset")
      end
      s.inActiveKey = false
      s.keyStartTime = nil
      ZugZugKeysDB._startBroadcastSent = nil
      ZugZugKeysDB._keyStartEpoch = nil
      cacheMapInfo()
    end
    return
  end

  if event == "CHALLENGE_MODE_START" then
    -- Fresh key → reset the persisted epoch so captureKeyInfo records the
    -- real start, not a stale value from a previous run.
    ZugZugKeysDB._keyStartEpoch = nil
    captureKeyInfo()
    Keys.fire("keyStart")
    return
  end

  if event == "CHALLENGE_MODE_COMPLETED" then
    Keys.fire("keyComplete")
    Keys.state.inActiveKey = false
    Keys.state.keyStartTime = nil
    ZugZugKeysDB._keyStartEpoch = nil
    return
  end

  if event == "CHALLENGE_MODE_RESET" then
    Keys.fire("keyReset")
    Keys.state.inActiveKey = false
    Keys.state.keyStartTime = nil
    ZugZugKeysDB._keyStartEpoch = nil
    return
  end
end)
