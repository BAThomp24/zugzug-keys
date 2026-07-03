----------------------------------------------------------------------
-- ZugZug Keys — Forces-bar lust marks
-- Draws vertical ticks on the Blizzard M+ tracker's Enemy Forces
-- progress bar at each planned lust's forces %, so the whole plan is
-- visible at a glance instead of only in chat.
--
-- How it attaches (verified against 12.0 live Blizzard_ObjectiveTracker):
--   * The forces bar is a ScenarioProgressBarTemplate frame acquired by
--     ScenarioObjectiveTracker:GetProgressBar(line, criteriaIndex) and
--     tracked in ScenarioObjectiveTracker.usedProgressBars.
--   * progressBar.Bar is a StatusBar with min 0 / max 100 whose value IS
--     the forces percentage — so a mark at pct sits at width*pct/100.
--   * We parent one overlay frame per bar and draw ticks on it. Never
--     writes fields onto Blizzard frames; hooksecurefunc + HookScript
--     only, so no taint.
--
-- Only %-based targets (MDT route pulls) carry a forces %; WCL boss /
-- pack-after-boss calls are event-anchored and get no tick.
----------------------------------------------------------------------

local Keys = _G.ZugZugKeys

local currentList   -- array of { pct = number, fired = bool } | nil when idle
local refreshQueued = false
local hooked        = false

-- One overlay frame per Blizzard bar StatusBar. Weak keys so pooled
-- frames Blizzard drops can be collected.
local overlays = setmetatable({}, { __mode = "k" })

local TICK_R, TICK_G, TICK_B = 0.56, 0.75, 0.25 -- ZugZug green

local function scheduleRefresh()
  if refreshQueued then return end
  refreshQueued = true
  C_Timer.After(0, function()
    refreshQueued = false
    Keys.__applyForcesBarMarks()
  end)
end

--- Hook the scenario module's progress-bar acquisition so marks re-apply
--- whenever the tracker lays the bar out (zone-in, criteria updates,
--- collapse/expand, edit-mode changes). Retried until the module exists.
local function ensureHook()
  if hooked then return end
  local module = _G.ScenarioObjectiveTracker
  if not (module and type(module.GetProgressBar) == "function") then return end
  hooksecurefunc(module, "GetProgressBar", scheduleRefresh)
  hooked = true
end

--- Every currently-active progress bar in the scenario module. During an
--- M+ key exactly one exists: Enemy Forces (weighted criteria are the
--- only ones that get bars, and marks only render while a key is live).
local function activeBars()
  local out = {}
  local module = _G.ScenarioObjectiveTracker
  local used = module and module.usedProgressBars
  if type(used) == "table" then
    for _, pb in pairs(used) do
      if type(pb) == "table" and pb.Bar and pb.IsShown and pb:IsShown() then
        table.insert(out, pb.Bar)
      end
    end
  end
  return out
end

local function getOverlay(bar)
  local ov = overlays[bar]
  if not ov then
    ov = CreateFrame("Frame", nil, bar)
    ov:SetAllPoints(bar)
    ov:SetFrameLevel(bar:GetFrameLevel() + 2)
    ov.ticks = {}
    overlays[bar] = ov
    -- Bar size is template-fixed (191px) but re-layout on any resize to
    -- stay correct if Blizzard ever makes it fluid.
    bar:HookScript("OnSizeChanged", scheduleRefresh)
  end
  return ov
end

local function layoutOverlay(ov, bar, list)
  local width = bar:GetWidth() or 0
  local shown = 0
  if width > 2 then
    for _, mark in ipairs(list) do
      local pct = mark.pct
      if type(pct) == "number" and pct >= 0 and pct <= 100 then
        shown = shown + 1
        local tick = ov.ticks[shown]
        if not tick then
          tick = ov:CreateTexture(nil, "OVERLAY")
          tick:SetWidth(2)
          ov.ticks[shown] = tick
        end
        -- Clamp so 0%/100% marks stay inside the frame art.
        local x = width * pct / 100
        if x < 1 then x = 1 elseif x > width - 1 then x = width - 1 end
        tick:ClearAllPoints()
        tick:SetPoint("TOP", bar, "TOPLEFT", x, 1)
        tick:SetPoint("BOTTOM", bar, "BOTTOMLEFT", x, -1)
        tick:SetColorTexture(TICK_R, TICK_G, TICK_B, mark.fired and 0.35 or 0.95)
        tick:Show()
      end
    end
  end
  for i = shown + 1, #ov.ticks do ov.ticks[i]:Hide() end
  ov:Show()
end

--- Internal: (re)draw ticks on every active bar, or hide everything when
--- there's nothing to show. Exposed on Keys only so the timer closure
--- above can reach it without an upvalue-ordering dance.
function Keys.__applyForcesBarMarks()
  ensureHook()
  local list = currentList
  if list and ZugZugKeysDB and ZugZugKeysDB.lustReminderBarMarks == false then
    list = nil
  end
  for _, ov in pairs(overlays) do ov:Hide() end
  if not list then return end
  for _, bar in ipairs(activeBars()) do
    layoutOverlay(getOverlay(bar), bar, list)
  end
end

--- Public: LustReminder pushes the current %-based targets here whenever
--- they load, fire, or clear. Pass nil/{} to remove all marks.
function Keys.UpdateForcesBarMarks(list)
  currentList = (type(list) == "table" and #list > 0) and list or nil
  scheduleRefresh()
end

--- Public: re-apply with the last-pushed list (settings toggle flips).
function Keys.RefreshForcesBarMarks()
  scheduleRefresh()
end

--- Diagnostic line for /zzk lust.
function Keys.ForcesBarMarksInfo()
  local bars = activeBars()
  return string.format("bar marks: %s, hook=%s, bars found=%d, marks=%d",
    (ZugZugKeysDB and ZugZugKeysDB.lustReminderBarMarks ~= false) and "on" or "off",
    tostring(hooked), #bars, currentList and #currentList or 0)
end
