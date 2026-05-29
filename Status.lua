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

local prevBnMessage = nil       -- saved before we overwrite, restored after key

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

  local h, m = GetGameTime()             -- realm/server time
  if h == nil or m == nil then return nil end

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
  local elapsed = s.keyStartTime and (GetTime() - s.keyStartTime) or 0
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

----------------------------------------------------------------------
-- Lifecycle hooks
----------------------------------------------------------------------

local function onKeyStart()
  if not ZugZugKeysDB.bnStatus then return end
  -- Dedupe: only broadcast once per active key run. Persists across /reload
  -- so a recovery path can't accidentally fire a second broadcast with the
  -- wrong "Started:" timestamp.
  if ZugZugKeysDB._startBroadcastSent then return end
  prevBnMessage = readBnMessage()
  local text = formatStartBroadcast()
  if ZugZugKeysDB.mpDebug then
    print("|cffFFAA00ZZK key start broadcast:|r " .. tostring(text))
  end
  if text then
    setBnMessage(text)
    ZugZugKeysDB._startBroadcastSent = true
  end
end

local function onKeyComplete()
  ZugZugKeysDB._startBroadcastSent = nil
  if not ZugZugKeysDB.bnStatus then return end
  local text = formatCompleteBroadcast()
  if text then setBnMessage(text) end
  -- Restore the previous BNet message after a short delay so the "Done" line
  -- lingers briefly but doesn't stay forever.
  C_Timer.After(RESTORE_DELAY, function()
    if prevBnMessage then setBnMessage(prevBnMessage) end
    prevBnMessage = nil
  end)
end

local function onKeyReset()
  ZugZugKeysDB._startBroadcastSent = nil
  if not ZugZugKeysDB.bnStatus then return end
  if prevBnMessage then setBnMessage(prevBnMessage) end
  prevBnMessage = nil
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

--- Send arbitrary text via BNet, regardless of key state. Used by
--- /zzk forcebcast to verify the pipeline outside a key.
function Keys.sendStatusNow(text)
  if not text or text == "" or not ZugZugKeysDB.bnStatus then return false end
  setBnMessage(truncate(text, BNET_MSG_MAX))
  return true
end
