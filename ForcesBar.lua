----------------------------------------------------------------------
-- ZugZug Keys — bar lust marks
-- Draws vertical ticks marking the planned lusts on the M+ HUD:
--   * %-based calls (MDT route pulls)  → on the Enemy Forces bar
--   * time-based calls (WCL medians)   → on the key TIMER bar
--
-- Hosts (whichever is visible gets decorated):
--
--  * Blizzard tracker (verified against 12.0 live Blizzard_ObjectiveTracker):
--      forces: ScenarioProgressBarTemplate frames from
--        ScenarioObjectiveTracker:GetProgressBar(...) tracked in
--        .usedProgressBars; progressBar.Bar is a StatusBar 0..100 whose
--        value IS the forces %.
--      timer:  ScenarioObjectiveTracker.ChallengeModeBlock.StatusBar —
--        min/max 0..timeLimit but DRAINING (SetValue(timeLeft)), so a
--        moment T sits at width × (1 - T/limit) from the left.
--
--  * EllesmereUI Mythic+ Timer (replaces the Blizzard tracker outright —
--    it reparents ObjectiveTrackerFrame into a hidden container):
--      forces: frame._enemyBarBg texture (full-width = 0..100%).
--      timer:  frame._barBg texture; the fill grows left→right with
--        elapsed/maxTime, so a moment T sits at width × T/limit.
--
-- We parent one overlay frame per host region and draw ticks on it. No
-- fields are written onto other addons'/Blizzard's frames; hooksecurefunc
-- only, so no taint. Because Ellesmere re-sizes its bars on settings
-- changes and builds its frame lazily, a slow in-key ticker re-scans and
-- re-lays-out (each pass is a handful of table lookups + SetPoints).
----------------------------------------------------------------------

local Keys = _G.ZugZugKeys

local pctList    -- array of { pct = number,  fired = bool } | nil
local timeList   -- array of { atMs = number, fired = bool } | nil
local refreshQueued = false
local hooked        = false
local ticker        -- slow re-scan while any marks are active

-- One overlay frame per host region (StatusBar frame or bar texture).
-- Weak keys so pooled/rebuilt frames the host drops can be collected.
local overlays = setmetatable({}, { __mode = "k" })

local TICK_R, TICK_G, TICK_B = 0.56, 0.75, 0.25 -- ZugZug green

local function scheduleRefresh()
  if refreshQueued then return end
  refreshQueued = true
  C_Timer.After(0, function()
    refreshQueued = false
    Keys.__applyBarMarks()
  end)
end

--- Hook the Blizzard scenario module's progress-bar acquisition so marks
--- re-apply whenever the tracker lays the bar out. Retried until the
--- module exists. (With EllesmereUI's timer active this never fires — the
--- ticker below covers that host instead.)
local function ensureHook()
  if hooked then return end
  local module = _G.ScenarioObjectiveTracker
  if not (module and type(module.GetProgressBar) == "function") then return end
  hooksecurefunc(module, "GetProgressBar", scheduleRefresh)
  hooked = true
end

--- The active key's time limit in ms (Core caches seconds on key start).
local function keyTimeLimitMs()
  local s = Keys.state and Keys.state.keyTimeLimit
  return (type(s) == "number" and s > 0) and (s * 1000) or nil
end

--- Collect every visible bar region we know how to decorate.
--- Each spec: { region, channel = "pct"|"time", drains = bool }.
local function collectBarSpecs()
  local out = {}

  -- Blizzard forces bar(s): active progress bars in the scenario module.
  -- During an M+ key exactly one exists (Enemy Forces — weighted criteria
  -- are the only ones that get bars, and marks only render in a live key).
  local module = _G.ScenarioObjectiveTracker
  local used = module and module.usedProgressBars
  if type(used) == "table" then
    for _, pb in pairs(used) do
      if type(pb) == "table" and pb.Bar and pb.IsShown and pb:IsShown() then
        table.insert(out, { region = pb.Bar, channel = "pct" })
      end
    end
  end

  -- Blizzard key timer bar (drains right→left).
  local cmBlock = module and module.ChallengeModeBlock
  local cmBar = cmBlock and cmBlock.StatusBar
  if cmBar and cmBar.IsVisible and cmBar:IsVisible() then
    table.insert(out, { region = cmBar, channel = "time", drains = true })
  end

  -- EllesmereUI Mythic+ Timer bars (both plain textures on the frame).
  local emt = _G.EllesmereUIMythicTimerStandalone
  if emt then
    local ebg = emt._enemyBarBg
    if ebg and ebg.IsVisible and ebg:IsVisible() then
      table.insert(out, { region = ebg, channel = "pct" })
    end
    local tbg = emt._barBg
    if tbg and tbg.IsVisible and tbg:IsVisible() then
      table.insert(out, { region = tbg, channel = "time" })
    end
  end

  return out
end

local function getOverlay(region)
  local ov = overlays[region]
  if not ov then
    -- A texture region can't parent a frame — hang the overlay off the
    -- frame that owns it and mirror the region's rect via SetAllPoints.
    local isTexture = region.GetObjectType and region:GetObjectType() == "Texture"
    local parent = isTexture and region:GetParent() or region
    ov = CreateFrame("Frame", nil, parent)
    ov:SetAllPoints(region)
    ov:SetFrameLevel(parent:GetFrameLevel() + 5)
    ov.ticks = {}
    overlays[region] = ov
    -- The overlay mirrors the host bar's rect, so the host resizing (edit
    -- mode, Ellesmere bar-width settings) fires this — re-place the ticks.
    ov:SetScript("OnSizeChanged", scheduleRefresh)
  end
  return ov
end

--- Place ticks on one overlay. Each mark is an x-fraction (0..1) of the
--- bar's width plus a fired flag; drains flips the axis (Blizzard's key
--- timer fills with time REMAINING, so elapsed moments sit mirrored).
local function layoutOverlay(ov, marks, drains)
  local width = ov:GetWidth() or 0
  local shown = 0
  if width > 2 then
    for _, mark in ipairs(marks) do
      local frac = mark.frac
      if type(frac) == "number" and frac >= 0 and frac <= 1 then
        if drains then frac = 1 - frac end
        shown = shown + 1
        local tick = ov.ticks[shown]
        if not tick then
          tick = ov:CreateTexture(nil, "OVERLAY")
          tick:SetWidth(2)
          ov.ticks[shown] = tick
        end
        -- Clamp so 0%/100% marks stay inside the frame art.
        local x = width * frac
        if x < 1 then x = 1 elseif x > width - 1 then x = width - 1 end
        tick:ClearAllPoints()
        tick:SetPoint("TOP", ov, "TOPLEFT", x, 1)
        tick:SetPoint("BOTTOM", ov, "BOTTOMLEFT", x, -1)
        tick:SetColorTexture(TICK_R, TICK_G, TICK_B, mark.fired and 0.35 or 0.95)
        tick:Show()
      end
    end
  end
  for i = shown + 1, #ov.ticks do ov.ticks[i]:Hide() end
  ov:Show()
end

--- Convert the pushed lists into per-channel x-fraction marks.
local function marksForChannel(channel)
  if channel == "pct" then
    if not pctList then return nil end
    local out = {}
    for _, m in ipairs(pctList) do
      if type(m.pct) == "number" and m.pct >= 0 and m.pct <= 100 then
        table.insert(out, { frac = m.pct / 100, fired = m.fired })
      end
    end
    return #out > 0 and out or nil
  end
  -- "time": needs the key's timer to translate ms → bar fraction.
  if not timeList then return nil end
  local limitMs = keyTimeLimitMs()
  if not limitMs then return nil end
  local out = {}
  for _, m in ipairs(timeList) do
    if type(m.atMs) == "number" and m.atMs > 0 and m.atMs < limitMs then
      table.insert(out, { frac = m.atMs / limitMs, fired = m.fired })
    end
  end
  return #out > 0 and out or nil
end

--- Slow re-scan while marks are active: catches hosts that build their
--- frames lazily (Ellesmere creates its timer frame on first render, and
--- discards + rebuilds it on profile changes) and bar-geometry changes
--- that produce no event we can hook.
local function ensureTicker()
  local wantTicker = (pctList or timeList) and true or false
  if wantTicker and not ticker then
    ticker = C_Timer.NewTicker(2, scheduleRefresh)
  elseif not wantTicker and ticker then
    ticker:Cancel()
    ticker = nil
  end
end

--- Internal: (re)draw ticks on every visible bar, or hide everything when
--- there's nothing to show. Exposed on Keys only so the timer closures
--- above can reach it without an upvalue-ordering dance.
function Keys.__applyBarMarks()
  ensureHook()
  ensureTicker()
  local enabled = not (ZugZugKeysDB and ZugZugKeysDB.lustReminderBarMarks == false)
  for _, ov in pairs(overlays) do ov:Hide() end
  if not enabled then return end
  for _, spec in ipairs(collectBarSpecs()) do
    local marks = marksForChannel(spec.channel)
    if marks then
      layoutOverlay(getOverlay(spec.region), marks, spec.drains)
    end
  end
end

--- Public: LustReminder pushes the current targets here whenever they
--- load, fire, or clear. pcts: { {pct=N, fired=bool} } for %-based calls;
--- times: { {atMs=N, fired=bool} } for WCL time-median calls. Pass nil to
--- clear a channel (or both).
function Keys.UpdateForcesBarMarks(pcts, times)
  pctList = (type(pcts) == "table" and #pcts > 0) and pcts or nil
  timeList = (type(times) == "table" and #times > 0) and times or nil
  scheduleRefresh()
end

--- Public: re-apply with the last-pushed lists (settings toggle flips).
function Keys.RefreshForcesBarMarks()
  scheduleRefresh()
end

--- Diagnostic line for /zzk lust.
function Keys.ForcesBarMarksInfo()
  local specs = collectBarSpecs()
  local hosts = {}
  for _, s in ipairs(specs) do
    local isTexture = s.region.GetObjectType and s.region:GetObjectType() == "Texture"
    table.insert(hosts, (isTexture and "eui-" or "blizz-") .. s.channel)
  end
  return string.format("bar marks: %s, hook=%s, bars=%d%s, pct marks=%d, time marks=%d",
    (ZugZugKeysDB and ZugZugKeysDB.lustReminderBarMarks ~= false) and "on" or "off",
    tostring(hooked), #specs,
    #hosts > 0 and (" (" .. table.concat(hosts, ", ") .. ")") or "",
    pctList and #pctList or 0, timeList and #timeList or 0)
end
