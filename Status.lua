----------------------------------------------------------------------
-- ZugZug Keys — BNet Broadcast (Key Start)
-- One-shot Battle.net custom-message broadcast posted right when the
-- key is started — before the challenge-mode chat lockdown kicks in.
-- Format:
--   "+14 Seat of the Triumvirate Started: 12:30 PM. Fin ~: 1:04 PM"
-- On key completion, restores the previous custom message after 60s.
--
-- The guild member note path was removed: in 12.0 the Club/GuildInfo
-- APIs accept writes but the server silently rejects self-edits.
----------------------------------------------------------------------

local Keys = _G.ZugZugKeys

local BNET_MSG_MAX = 120
local RESTORE_DELAY = 60        -- seconds before restoring the previous BNet message

-- The previous BNet custom message is persisted in ZugZugKeysDB._prevBnMessage
-- so it survives /reload and so a second key starting within RESTORE_DELAY of
-- the first finishing can't overwrite the user's original with our own text.

local function truncate(text, maxLen)
  if not text then return "" end
  if #text <= maxLen then return text end
  return text:sub(1, maxLen)
end

----------------------------------------------------------------------
-- Time helpers (server time via GetGameTime; format 12-hour AM/PM)
----------------------------------------------------------------------

local function format12h(h, m)
  local period = (h >= 12) and "PM" or "AM"
  local h12 = h % 12
  if h12 == 0 then h12 = 12 end
  return string.format("%d:%02d %s", h12, m, period)
end

local function formatStartBroadcast()
  local s = Keys.state
  if not s.keyTimeLimit then return nil end

  local h, m = GetGameTime()             -- realm/server time (current)
  if h == nil or m == nil then return nil end

  -- If we have a persisted epoch (real start time), back-compute the start
  -- hour/minute from elapsed minutes. This makes /zzk refresh and any
  -- post-/reload broadcast show the actual start time instead of "now".
  if ZugZugKeysDB._keyStartEpoch then
    local elapsedSec = time() - ZugZugKeysDB._keyStartEpoch
    if elapsedSec > 0 then
      local elapsedMin = math.floor(elapsedSec / 60)
      local startTotal = (h * 60 + m - elapsedMin) % (24 * 60)
      if startTotal < 0 then startTotal = startTotal + 24 * 60 end
      h = math.floor(startTotal / 60)
      m = startTotal % 60
    end
  end

  local startStr = format12h(h, m)
  local totalMin = h * 60 + m + math.floor(s.keyTimeLimit / 60)
  local fh = math.floor(totalMin / 60) % 24
  local fm = totalMin % 60
  local finStr = format12h(fh, fm)

  local label = s.keyName or "key"
  if s.keyLevel and s.keyLevel > 0 then label = "+" .. s.keyLevel .. " " .. label end

  return truncate(string.format("%s Started: %s. Finished~: %s", label, startStr, finStr), BNET_MSG_MAX)
end

local function formatCompleteBroadcast()
  local s = Keys.state
  -- Prefer the persisted epoch (survives /reload). Fall back to in-memory
  -- GetTime() only if the epoch is somehow missing.
  local elapsed = 0
  if ZugZugKeysDB._keyStartEpoch then
    elapsed = time() - ZugZugKeysDB._keyStartEpoch
  elseif s.keyStartTime then
    elapsed = GetTime() - s.keyStartTime
  end
  local label = s.keyName or "key"
  if s.keyLevel and s.keyLevel > 0 then label = "+" .. s.keyLevel .. " " .. label end
  local mins = math.floor(elapsed / 60)
  local secs = math.floor(elapsed % 60)
  return truncate(string.format("%s Done in %d:%02d (ZugZug Keys)", label, mins, secs), BNET_MSG_MAX)
end

----------------------------------------------------------------------
-- BNet send / read (pcall-guarded)
----------------------------------------------------------------------

local function setBnMessage(text)
  if BNSetCustomMessage and text then pcall(BNSetCustomMessage, text) end
end

--- Best-effort read of the current custom message so we can restore it.
--- BNGetInfo's return shape has drifted across patches — pick the longest
--- non-tag string in the returns as a heuristic for the broadcast text.
local function readBnMessage()
  if not BNGetInfo then return nil end
  local ok, returns = pcall(function() return { BNGetInfo() } end)
  if not ok or type(returns) ~= "table" then return nil end
  local best
  for i = 1, #returns do
    local v = returns[i]
    if type(v) == "string" and not v:find("#") and #v > 0 then
      if not best or #v > #best then best = v end
    end
  end
  return best
end

--- Detect a ZugZug-shaped broadcast so we don't capture one of our own
--- (left over from a crashed/interrupted session) as the "previous"
--- message we'd later restore.
local function looksLikeZugZugBroadcast(text)
  if type(text) ~= "string" then return false end
  if text:match("^%+%d+.+Started:.+Finished~:") then return true end
  if text:match("^%+%d+.+Done in.+%(ZugZug") then return true end
  return false
end

----------------------------------------------------------------------
-- Lifecycle hooks
----------------------------------------------------------------------

local function onKeyStart()
  if not ZugZugKeysDB.bnStatus then return end
  -- Dedupe: only broadcast once per active key run. Persists across /reload
  -- so a recovery path can't accidentally fire a second broadcast with the
  -- wrong "Started:" timestamp.
  if ZugZugKeysDB._startBroadcastSent then return end
  -- Compute the text first. If we can't build a valid broadcast (no key data
  -- yet, /zzk refresh outside a key, etc.) bail out BEFORE touching state so
  -- we don't capture a stale _prevBnMessage that'd later overwrite the real
  -- user message.
  local text = formatStartBroadcast()
  if not text then return end
  -- Capture the user's prior message now that we know we'll overwrite it.
  -- Skip if it already looks like a ZugZug broadcast — that means a previous
  -- session crashed or didn't clean up, and restoring it would just leak a
  -- stale "Started:/Done in" line back onto the status. Don't overwrite a
  -- previously-saved value either (handles a second key starting inside the
  -- previous key's RESTORE_DELAY window).
  if not ZugZugKeysDB._prevBnMessage then
    local current = readBnMessage()
    if current and not looksLikeZugZugBroadcast(current) then
      ZugZugKeysDB._prevBnMessage = current
    end
  end
  setBnMessage(text)
  ZugZugKeysDB._startBroadcastSent = true
end

local function onKeyComplete()
  -- Snapshot whether WE set a message during this run before we clear the
  -- flag. If we never broadcasted (toggle was off the whole time), there is
  -- nothing to restore even if a stale _prevBnMessage exists in the DB.
  local weBroadcasted = ZugZugKeysDB._startBroadcastSent
  ZugZugKeysDB._startBroadcastSent = nil

  -- Only broadcast "Done in" if we also broadcasted "Started:" for this run.
  -- Otherwise the completion message would appear without context (e.g. user
  -- toggled bnStatus on mid-key) and we'd have no _prevBnMessage to restore.
  if weBroadcasted and ZugZugKeysDB.bnStatus then
    local text = formatCompleteBroadcast()
    if text then setBnMessage(text) end
  end

  -- Always clean up the BNet status if we set anything earlier — restore the
  -- captured pre-key message if we have one, otherwise clear to blank. We
  -- never want to leave a stale "Started:" / "Done in" line sitting on the
  -- user's broadcast. Gate on inActiveKey so a new key starting within
  -- RESTORE_DELAY doesn't get its start broadcast clobbered.
  if weBroadcasted then
    C_Timer.After(RESTORE_DELAY, function()
      if Keys.state.inActiveKey then return end
      local restore = ZugZugKeysDB._prevBnMessage
      if restore and looksLikeZugZugBroadcast(restore) then restore = nil end
      setBnMessage(restore or "")
      ZugZugKeysDB._prevBnMessage = nil
    end)
  end
end

local function onKeyReset()
  local weBroadcasted = ZugZugKeysDB._startBroadcastSent
  ZugZugKeysDB._startBroadcastSent = nil
  -- Reset/abandon → clean up immediately. Same restore-or-clear logic as
  -- onKeyComplete.
  if weBroadcasted then
    local restore = ZugZugKeysDB._prevBnMessage
    if restore and looksLikeZugZugBroadcast(restore) then restore = nil end
    setBnMessage(restore or "")
    ZugZugKeysDB._prevBnMessage = nil
  end
end

Keys.on("keyStart",    onKeyStart)
Keys.on("keyComplete", onKeyComplete)
Keys.on("keyReset",    onKeyReset)

----------------------------------------------------------------------
-- Exposed for /zzk commands
----------------------------------------------------------------------

--- Re-fire the start broadcast on demand (uses current key state). Clears
--- the dedupe flag first so /zzk refresh always re-sends, even mid-key.
function Keys.refreshStatus()
  ZugZugKeysDB._startBroadcastSent = nil
  onKeyStart()
end

