----------------------------------------------------------------------
-- ZugZug Keys — Targeted Spells
-- Shows an icon on a party member's DandersFrames frame when an enemy
-- starts a cast targeting them, so healers/dps see incoming danger.
--
-- 12.0 Midnight makes the obvious approach impossible: you cannot ask
-- "is this cast targeting THIS specific ally?" — UnitIsUnit on a
-- compound token (e.g. "nameplate3target" vs "party2") was hotfixed to
-- return nil on 2026-04-07, and UnitGUID/UnitName on nameplates are
-- secret in instance combat.
--
-- The working technique (reverse-engineered from EllesmereUI's
-- EUI_RF_TargetedSpells, which ships this for live M+): Blizzard
-- restricted *identity* but left *description* readable. We read the
-- caster's target's class / role / race / sex — all non-secret even on
-- the compound token — and match against the known party roster. If
-- exactly one member fits, that's the target. If two members are
-- indistinguishable (same class+role+race+sex) we show nothing rather
-- than guess. In a 5-person key with distinct classes this resolves
-- almost every cast uniquely.
--
-- The player's own targeting is special-cased via UnitIsUnit(..,"player")
-- ("player" stays on the always-allowed list) for 100% reliability.
--
-- Frames come from DandersFrames' public API; if DF isn't loaded the
-- feature silently no-ops.
----------------------------------------------------------------------

local Keys = _G.ZugZugKeys

local pairs, ipairs, wipe, tremove = pairs, ipairs, wipe, table.remove
local GetTime = GetTime
local UnitExists, UnitClass, UnitRace, UnitSex = UnitExists, UnitClass, UnitRace, UnitSex
local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local UnitIsUnit, UnitCanAttack = UnitIsUnit, UnitCanAttack
local UnitCastingInfo, UnitChannelInfo = UnitCastingInfo, UnitChannelInfo
local UnitCastingDuration = UnitCastingDuration
local UnitChannelDuration = UnitChannelDuration
local IsInGroup, IsInInstance = IsInGroup, IsInInstance
local C_Spell, C_NamePlate, C_Timer = C_Spell, C_NamePlate, C_Timer

-- issecretvalue is 12.0+; on older clients treat everything as non-secret.
local issecret = issecretvalue or function() return false end

local FALLBACK_ICON = 134400 -- question mark

-- Engine timing: at UNIT_SPELLCAST_START the cast/target data isn't linked
-- yet (returns zero values); it settles a few frames later. Some abilities
-- also report the TANK as the target for the first ~quarter second before
-- flipping to the real one ("tank-lock" bug). We resolve twice.
local PICKUP_DELAY   = 0.1
local VERIFY_DELAY   = 0.15
local RETARGET_DELAY = 0.05

----------------------------------------------------------------------
-- Settings access
----------------------------------------------------------------------

local function S(key) return ZugZugKeysDB and ZugZugKeysDB[key] end

local function debug(msg)
  if ZugZugKeysDB and ZugZugKeysDB.targetedSpellsDebug then
    print("|cffFF8800ZZK TS:|r " .. tostring(msg))
  end
end

----------------------------------------------------------------------
-- DandersFrames integration
----------------------------------------------------------------------

local function DFReady()
  return _G.DandersFrames_IsReady and DandersFrames_IsReady()
end

local function DFFrameForUnit(unit)
  if not _G.DandersFrames_GetFrameForUnit then return nil end
  return DandersFrames_GetFrameForUnit(unit)
end

----------------------------------------------------------------------
-- Roster cache — class/role/race/sex per party unit, for deductive
-- target identification. Rebuilt on roster / role changes.
----------------------------------------------------------------------

local rosterByClass = {} -- classToken -> { unitToken, ... }
local rosterRole    = {} -- unitToken -> "TANK"/"HEALER"/"DAMAGER"
local rosterRace    = {} -- unitToken -> raceToken
local rosterSex     = {} -- unitToken -> 2/3
local lastRosterSync = 0

local UNITS = { "player", "party1", "party2", "party3", "party4" }

local function RebuildRoster()
  wipe(rosterByClass); wipe(rosterRole); wipe(rosterRace); wipe(rosterSex)
  for _, u in ipairs(UNITS) do
    local ex = UnitExists(u)
    if not issecret(ex) and ex == true then
      local _, token = UnitClass(u)
      if not issecret(token) and type(token) == "string" then
        local list = rosterByClass[token]
        if not list then list = {}; rosterByClass[token] = list end
        list[#list + 1] = u
      end
      local role = UnitGroupRolesAssigned(u)
      if not issecret(role) and type(role) == "string" and role ~= "NONE" then
        rosterRole[u] = role
      end
      local _, raceToken = UnitRace(u)
      if not issecret(raceToken) and type(raceToken) == "string" then
        rosterRace[u] = raceToken
      end
      local sex = UnitSex(u)
      if not issecret(sex) and type(sex) == "number" then
        rosterSex[u] = sex
      end
    end
  end
  lastRosterSync = GetTime()
end

----------------------------------------------------------------------
-- Deductive identification
----------------------------------------------------------------------

local matchBuf = {}

-- Drop candidates whose value differs from the target's — but only when
-- at least one candidate matches exactly (otherwise the attribute is
-- unhelpful here, e.g. a late-cached value, and we skip the pass rather
-- than wrongly emptying the set).
local function Narrow(targetVal, rosterMap)
  if targetVal == nil or #matchBuf <= 1 then return end
  local exact = 0
  for i = 1, #matchBuf do
    if rosterMap[matchBuf[i]] == targetVal then exact = exact + 1 end
  end
  if exact == 0 then return end
  for i = #matchBuf, 1, -1 do
    if rosterMap[matchBuf[i]] ~= targetVal then tremove(matchBuf, i) end
  end
end

-- Returns { unitToken } (exactly one) or nil.
local function Classify(caster)
  local tgt = caster .. "target"

  -- Reliable self-path first: "player" stays on UnitIsUnit's allowed list.
  local isMe = UnitIsUnit(tgt, "player")
  if not issecret(isMe) and isMe == true then
    wipe(matchBuf); matchBuf[1] = "player"; return matchBuf
  end

  local _, cls = UnitClass(tgt)
  if issecret(cls) or type(cls) ~= "string" then return nil end

  wipe(matchBuf)
  local cands = rosterByClass[cls]
  if cands then
    for i = 1, #cands do matchBuf[i] = cands[i] end
  end
  if #matchBuf == 0 then
    -- Stale cache (member/role learned after last rebuild). Throttled so an
    -- off-roster target (another enemy, a pet) doesn't force a rebuild per cast.
    if GetTime() - lastRosterSync > 1 then
      RebuildRoster()
      cands = rosterByClass[cls]
      if cands then for i = 1, #cands do matchBuf[i] = cands[i] end end
    end
    if #matchBuf == 0 then return nil end
  end

  -- If we conclusively know it's NOT the player, drop player from candidates.
  if not issecret(isMe) and isMe == false then
    for i = #matchBuf, 1, -1 do
      if matchBuf[i] == "player" then tremove(matchBuf, i) end
    end
    if #matchBuf == 0 then return nil end
  end

  local role = UnitGroupRolesAssigned(tgt)
  if issecret(role) or role == "NONE" then role = nil end
  Narrow(role, rosterRole)

  -- Race/sex on a compound token are pcall-guarded: some APIs reject
  -- compound tokens outright; degrade to "filter skipped", not an error.
  local okR, _, raceToken = pcall(UnitRace, tgt)
  if not okR or issecret(raceToken) or type(raceToken) ~= "string" then raceToken = nil end
  Narrow(raceToken, rosterRace)

  local okS, sex = pcall(UnitSex, tgt)
  if not okS or issecret(sex) or type(sex) ~= "number" then sex = nil end
  Narrow(sex, rosterSex)

  -- Ambiguity rule: exactly one confirmed target, or nothing.
  if #matchBuf ~= 1 then return nil end
  return matchBuf
end

----------------------------------------------------------------------
-- Important-spell filter. Fail-open: if we can't read the spellID or the
-- importance flag (secret/unavailable), show the cast rather than hide a
-- potentially-dangerous one.
----------------------------------------------------------------------

local function CastIsRelevant(caster, channeling)
  if S("targetedSpellsShowAll") then return true end
  local spellId
  if channeling then
    spellId = select(8, UnitChannelInfo(caster)) -- channel: spellID is 8th
  else
    spellId = select(9, UnitCastingInfo(caster))  -- cast: spellID is 9th
  end
  if spellId == nil or issecret(spellId) then return true end
  if C_Spell and C_Spell.IsSpellImportant then
    local ok, important = pcall(C_Spell.IsSpellImportant, spellId)
    if ok and not issecret(important) then return important == true end
  end
  return true
end

----------------------------------------------------------------------
-- Icon pool — frames parented to DF buttons (DF's own external-overlay
-- pattern). Per-button state lives in a weak-keyed table.
----------------------------------------------------------------------

local buttonIcons = setmetatable({}, { __mode = "k" }) -- btn -> { icon, ... }

local function StyleIcon(icon)
  local sz = S("targetedSpellsSize") or 28
  icon:SetSize(sz, sz)
end

local function CreateIcon(btn)
  local icon = CreateFrame("Frame", nil, btn)
  icon:SetFrameLevel(btn:GetFrameLevel() + 12)
  icon:Hide()

  local tex = icon:CreateTexture(nil, "ARTWORK")
  tex:SetAllPoints()
  tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  icon._tex = tex

  local cd = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
  cd:SetAllPoints()
  cd:SetDrawEdge(false)
  cd:SetDrawSwipe(true)
  cd:SetSwipeColor(0, 0, 0, 0.6)
  cd:SetReverse(true)
  cd:SetHideCountdownNumbers(true)
  icon._cooldown = cd

  -- Thin black border via a backdrop so the icon reads against any frame.
  local bdr = CreateFrame("Frame", nil, icon, "BackdropTemplate")
  bdr:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
  bdr:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
  bdr:SetFrameLevel(icon:GetFrameLevel() + 1)
  if bdr.SetBackdrop then
    bdr:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    bdr:SetBackdropBorderColor(0, 0, 0, 1)
  end
  icon._border = bdr

  StyleIcon(icon)
  return icon
end

local function AcquireIcon(btn)
  local icons = buttonIcons[btn]
  if not icons then icons = {}; buttonIcons[btn] = icons end
  local maxIcons = S("targetedSpellsMax") or 3
  for i = 1, #icons do
    if not icons[i]._tsCaster then return icons[i] end
  end
  if #icons >= maxIcons then return nil end
  local icon = CreateIcon(btn)
  icons[#icons + 1] = icon
  return icon
end

local function Place(icon, host, pos, fx, fy)
  pos = (pos or "center"):lower()
  if pos == "topleft" then icon:SetPoint("TOPLEFT", host, "TOPLEFT", fx, fy)
  elseif pos == "top" then icon:SetPoint("TOP", host, "TOP", fx, fy)
  elseif pos == "topright" then icon:SetPoint("TOPRIGHT", host, "TOPRIGHT", fx, fy)
  elseif pos == "left" then icon:SetPoint("LEFT", host, "LEFT", fx, fy)
  elseif pos == "right" then icon:SetPoint("RIGHT", host, "RIGHT", fx, fy)
  elseif pos == "bottomleft" then icon:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", fx, fy)
  elseif pos == "bottom" then icon:SetPoint("BOTTOM", host, "BOTTOM", fx, fy)
  elseif pos == "bottomright" then icon:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", fx, fy)
  else icon:SetPoint("CENTER", host, "CENTER", fx, fy) end
end

-- Lay out the in-use icons on a button: first at the anchor, rest chained
-- in a centered row.
local function LayoutButton(btn)
  local icons = buttonIcons[btn]
  if not icons then return end
  local sz = S("targetedSpellsSize") or 28
  local pos = S("targetedSpellsAnchor") or "CENTER"
  local ox = S("targetedSpellsOffsetX") or 0
  local oy = S("targetedSpellsOffsetY") or 0
  local spc = 2
  local spacing = sz + spc

  local shown = 0
  for i = 1, #icons do if icons[i]._tsCaster then shown = shown + 1 end end
  if shown == 0 then return end

  local centerOff = -((shown - 1) * spacing) / 2
  local prev
  for i = 1, #icons do
    local icon = icons[i]
    if icon._tsCaster then
      icon:ClearAllPoints()
      if not prev then
        Place(icon, btn, pos, ox + centerOff, oy)
      else
        icon:SetPoint("LEFT", prev, "RIGHT", spc, 0)
      end
      prev = icon
    end
  end
end

----------------------------------------------------------------------
-- Active cast tracking
----------------------------------------------------------------------

local gen = {}         -- caster -> generation counter (stale-timer guard)
local activeIcons = {} -- caster -> { icon, ..., key = unitToken }
local tracked = {}     -- caster -> true while followed

local function ClearCaster(caster)
  gen[caster] = (gen[caster] or 0) + 1
  tracked[caster] = nil
  local icons = activeIcons[caster]
  if not icons then return end
  activeIcons[caster] = nil
  local touched = {}
  for i = 1, #icons do
    local icon = icons[i]
    icon._tsCaster = nil
    icon:Hide()
    if icon._cooldown then icon._cooldown:Clear(); icon._cooldown:Hide() end
    touched[icon:GetParent()] = true
  end
  for btn in pairs(touched) do LayoutButton(btn) end
end

local function ClearAll()
  for caster in pairs(activeIcons) do ClearCaster(caster) end
  wipe(tracked)
end
Keys.TargetedSpells_ClearAll = ClearAll

-- Brief red tint then teardown, so a successful interrupt reads as "handled".
local function FlashCaster(caster)
  local icons = activeIcons[caster]
  if not icons then ClearCaster(caster); return end
  for i = 1, #icons do
    local icon = icons[i]
    if icon._tex then icon._tex:SetVertexColor(1, 0.3, 0.3) end
    if icon._cooldown then icon._cooldown:Clear(); icon._cooldown:Hide() end
  end
  local myGen = (gen[caster] or 0)
  C_Timer.After(0.3, function()
    if gen[caster] == myGen then ClearCaster(caster) end
  end)
end

local function ShowFor(caster, matches, texture, durObj)
  local shownAny, list
  for _, unitToken in ipairs(matches) do
    local btn = DFFrameForUnit(unitToken)
    if btn and btn:IsShown() then
      local icon = AcquireIcon(btn)
      if icon then
        icon._tsCaster = caster
        StyleIcon(icon)
        if icon._tex then icon._tex:SetVertexColor(1, 1, 1) end
        -- texture may be SECRET: SetTexture accepts it natively.
        icon._tex:SetTexture(texture == nil and FALLBACK_ICON or texture)
        local cd = icon._cooldown
        if durObj and cd.SetCooldownFromDurationObject then
          cd:SetCooldownFromDurationObject(durObj)
          if durObj.IsZero and cd.SetAlphaFromBoolean then
            cd:SetAlphaFromBoolean(durObj:IsZero(), 0, 1)
          else
            cd:SetAlpha(1)
          end
          cd:SetDrawSwipe(true); cd:Show()
        else
          cd:Clear(); cd:Hide()
        end
        icon:Show()
        LayoutButton(btn)
        shownAny = true
        if not list then list = {} end
        list[#list + 1] = icon
      end
    end
  end
  if shownAny then activeIcons[caster] = list end
end

local function Resolve(caster, myGen)
  if gen[caster] ~= myGen then return end

  -- Re-validate the cast is still running (zero values when not casting).
  local castName, _, texture = UnitCastingInfo(caster)
  local channeling = false
  if type(castName) == "nil" then
    castName, _, texture = UnitChannelInfo(caster)
    channeling = true
  end
  if type(castName) == "nil" then return end

  -- Sanctioned 12.0 clean gate: does this cast have a displayable player
  -- target? false = AoE/self-cast/stale link → nothing to show.
  if _G.UnitShouldDisplaySpellTargetName then
    local sd = UnitShouldDisplaySpellTargetName(caster)
    if not issecret(sd) and sd == false then return end
  end

  if not CastIsRelevant(caster, channeling) then return end

  local matches = Classify(caster)
  if not matches then return end

  -- Unchanged-target guard: a verify-pass that lands on the same member
  -- early-returns (no teardown, no flicker).
  local newKey = matches[1]
  local icons = activeIcons[caster]
  if icons and icons.key == newKey then return end

  local durObj
  if channeling then
    durObj = UnitChannelDuration and UnitChannelDuration(caster)
  else
    durObj = UnitCastingDuration and UnitCastingDuration(caster)
  end

  -- Tear down icons on the WRONG frame (tank-lock bug, or a genuine retarget)
  -- before re-showing.
  if icons then
    activeIcons[caster] = nil
    local touched = {}
    for i = 1, #icons do
      icons[i]._tsCaster = nil
      icons[i]:Hide()
      touched[icons[i]:GetParent()] = true
    end
    for btn in pairs(touched) do LayoutButton(btn) end
  end

  ShowFor(caster, matches, texture, durObj)
  local list = activeIcons[caster]
  if list then list.key = newKey end
end

local function OnCastStart(caster)
  ClearCaster(caster) -- bumps gen; previous cast's icons die
  -- Enemy casters only. Plainly-false attackability = ally; secret = hostile.
  local hostile = UnitCanAttack("player", caster)
  if not issecret(hostile) and hostile ~= true then return end
  -- Clean pre-filter at event time (gate=false → no displayable player target).
  if _G.UnitShouldDisplaySpellTargetName then
    local sd = UnitShouldDisplaySpellTargetName(caster)
    if not issecret(sd) and sd == false then return end
  end
  tracked[caster] = true
  local myGen = gen[caster]
  C_Timer.After(PICKUP_DELAY, function() Resolve(caster, myGen) end)
  C_Timer.After(PICKUP_DELAY + VERIFY_DELAY, function() Resolve(caster, myGen) end)
end

local function OnRetarget(caster)
  if not tracked[caster] then return end
  gen[caster] = (gen[caster] or 0) + 1
  local myGen = gen[caster]
  C_Timer.After(RETARGET_DELAY, function() Resolve(caster, myGen) end)
  C_Timer.After(RETARGET_DELAY + VERIFY_DELAY, function() Resolve(caster, myGen) end)
end

----------------------------------------------------------------------
-- Event wiring
----------------------------------------------------------------------

local plateTokens = {} -- nameplate unit token -> true (O(1) cast filter)
local active = false
local ev = CreateFrame("Frame")
local dfCallbackToken = {}
local dfCallbackHooked = false

local CAST_EVENTS = {
  "UNIT_SPELLCAST_START",
  "UNIT_SPELLCAST_CHANNEL_START",
  "UNIT_SPELLCAST_STOP",
  "UNIT_SPELLCAST_CHANNEL_STOP",
  "UNIT_SPELLCAST_INTERRUPTED",
  "UNIT_TARGET",
  "NAME_PLATE_UNIT_ADDED",
  "NAME_PLATE_UNIT_REMOVED",
}

-- Active when: enabled + DF ready + in a party-type instance (dungeon/M+).
local function ShouldBeActive()
  if not S("targetedSpells") then return false end
  if not DFReady() then return false end
  if not IsInGroup() then return false end
  local inInstance, instanceType = IsInInstance()
  return inInstance and instanceType == "party"
end

local function AdoptIfCasting(unit)
  local castName = UnitCastingInfo(unit)
  if type(castName) == "nil" then castName = UnitChannelInfo(unit) end
  if type(castName) ~= "nil" then OnCastStart(unit) end
end

local function SeedPlates()
  if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
  for _, p in ipairs(C_NamePlate.GetNamePlates()) do
    local u = p.namePlateUnitToken
    if u and not plateTokens[u] then
      plateTokens[u] = true
      AdoptIfCasting(u)
    end
  end
end

-- Subscribe once to DF's frame-resort callback so a button reassigned to a
-- different unit mid-cast can't leave an icon on the wrong member.
local function HookDFCallback()
  if dfCallbackHooked then return end
  if _G.DandersFrames and DandersFrames.RegisterCallback then
    DandersFrames.RegisterCallback(dfCallbackToken, "OnFramesSorted", function()
      ClearAll()
    end)
    dfCallbackHooked = true
  end
end

local function UpdateActive()
  local want = ShouldBeActive()
  if want and not active then
    HookDFCallback()
    for _, e in ipairs(CAST_EVENTS) do ev:RegisterEvent(e) end
    active = true
    RebuildRoster()
    SeedPlates()
    debug("activated")
  elseif not want and active then
    for _, e in ipairs(CAST_EVENTS) do ev:UnregisterEvent(e) end
    active = false
    ClearAll()
    wipe(plateTokens)
    debug("deactivated")
  end
end
Keys.TargetedSpells_UpdateActive = UpdateActive

ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("GROUP_ROSTER_UPDATE")
ev:RegisterEvent("PLAYER_ROLES_ASSIGNED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_REGEN_ENABLED") -- combat-end backstop
ev:SetScript("OnEvent", function(_, event, unit)
  if event == "PLAYER_LOGIN" then
    UpdateActive()
    -- DF may finish loading after us; retry shortly if it wasn't ready.
    if not DFReady() then C_Timer.After(2, UpdateActive) end
    return
  end
  if event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ROLES_ASSIGNED" then
    RebuildRoster()
    ClearAll()
    UpdateActive()
    return
  end
  if event == "PLAYER_ENTERING_WORLD" then
    ClearAll()
    wipe(plateTokens)
    UpdateActive()
    if active then SeedPlates() end
    return
  end
  if event == "PLAYER_REGEN_ENABLED" then
    ClearAll()
    return
  end
  -- Plate add/remove maintain the O(1) filter set.
  if event == "NAME_PLATE_UNIT_ADDED" then
    plateTokens[unit] = true
    AdoptIfCasting(unit)
    return
  end
  if event == "NAME_PLATE_UNIT_REMOVED" then
    plateTokens[unit] = nil
    ClearCaster(unit)
    return
  end
  -- Cast / retarget: O(1) plate-token reject (UNIT_TARGET fires for everyone).
  if not plateTokens[unit] then return end
  if event == "UNIT_TARGET" then
    OnRetarget(unit)
  elseif event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
    OnCastStart(unit)
  elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
    FlashCaster(unit)
  else
    ClearCaster(unit) -- STOP / CHANNEL_STOP
  end
end)

----------------------------------------------------------------------
-- Called from Settings.lua when the master toggle / options change.
----------------------------------------------------------------------

function Keys.UpdateTargetedSpellsFeature()
  -- Re-evaluate active state; if turned off mid-instance, clear immediately.
  UpdateActive()
end
