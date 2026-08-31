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

-- M+ dungeon teleport spells, keyed by NORMALIZED dungeon name.
--
-- Name-keyed rather than keyed by challenge mapID, and covering every
-- dungeon rather than one season's eight, because both of those change
-- and the table did not: Season 2 arrived, the eight mapIDs here stopped
-- matching anything the game offered, and the teleport button simply
-- never appeared. Challenge mapIDs now come from the game itself at
-- discovery time, so only a genuinely NEW dungeon needs an entry here —
-- a returning one already has one.
--
-- Dynamic lookup still isn't possible: 12.0 removed the global
-- GetSpellInfo, C_Spell.GetSpellInfo(name) takes only numeric ids, and
-- achievement-reward teleports don't appear in C_SpellBook iteration.
-- Spell ids sourced from BigWigs' maintained keystone table.
local TELEPORT_BY_DUNGEON = {
  ["algethar academy"] = 393273,        -- Algeth'ar Academy
  ["altar of fangs"] = 1286812,         -- Altar of Fangs
  ["ara kara city of echoes"] = 445417, -- Ara-Kara, City of Echoes
  ["ataldazar"] = 424187,               -- Atal'Dazar
  ["auchindoun"] = 159897,              -- Auchindoun
  ["black rook hold"] = 424153,         -- Black Rook Hold
  ["bloodmaul slag mines"] = 159895,    -- Bloodmaul Slag Mines
  ["brackenhide hollow"] = 393267,      -- Brackenhide Hollow
  ["cinderbrew meadery"] = 445440,      -- Cinderbrew Meadery
  ["city of threads"] = 445416,         -- City of Threads
  ["court of stars"] = 393766,          -- Court of Stars
  ["darkflame cleft"] = 445441,         -- Darkflame Cleft
  ["darkheart thicket"] = 424163,       -- Darkheart Thicket
  ["dawn of the infinite"] = 424197,    -- Dawn of the Infinite
  ["de other side"] = 354468,           -- De Other Side
  ["den of nalorakk"] = 1286807,        -- Den of Nalorakk
  ["eco dome aldani"] = 1237215,        -- Eco-Dome Al'dani
  ["freehold"] = 410071,                -- Freehold
  ["gate of the setting sun"] = 131225, -- Gate of the Setting Sun
  ["grim batol"] = 445424,              -- Grim Batol
  ["grimrail depot"] = 159900,          -- Grimrail Depot
  ["halls of atonement"] = 354465,      -- Halls of Atonement
  ["halls of infusion"] = 393283,       -- Halls of Infusion
  ["halls of valor"] = 393764,          -- Halls of Valor
  ["iron docks"] = 159896,              -- Iron Docks
  ["kings rest"] = 1286831,             -- King's Rest
  ["magisters terrace"] = 1254572,      -- Magisters' Terrace
  ["maisara caverns"] = 1254559,        -- Maisara Caverns
  ["mists of tirna scithe"] = 354464,   -- Mists of Tirna Scithe
  ["mogushan palace"] = 131222,         -- Mogu'shan Palace
  ["murder row"] = 1286809,             -- Murder Row
  ["neltharions lair"] = 410078,        -- Neltharion's Lair
  ["neltharus"] = 393276,               -- Neltharus
  ["nexus point xenas"] = 1254563,      -- Nexus-Point Xenas
  ["operation floodgate"] = 1216786,    -- Operation: Floodgate
  ["operation mechagon"] = 373274,      -- Operation: Mechagon
  ["pit of saron"] = 1254555,           -- Pit of Saron
  ["plaguefall"] = 354463,              -- Plaguefall
  ["priory of the sacred flame"] = 445444, -- Priory of the Sacred Flame
  ["return to karazhan"] = 373262,      -- Return to Karazhan
  ["ruby life pools"] = 393256,         -- Ruby Life Pools
  ["sanguine depths"] = 354469,         -- Sanguine Depths
  ["scarlet halls"] = 131231,           -- Scarlet Halls
  ["scarlet monastery"] = 131229,       -- Scarlet Monastery
  ["scholomance"] = 131232,             -- Scholomance
  ["seat of the triumvirate"] = 1254551, -- Seat of the Triumvirate
  ["shado pan monastery"] = 131206,     -- Shado-Pan Monastery
  ["shadowmoon burial grounds"] = 159899, -- Shadowmoon Burial Grounds
  ["siege of niuzao temple"] = 131228,  -- Siege of Niuzao Temple
  ["skyreach xxx 1254557 was also added which will be used"] = 159898, -- Skyreach -- XXX 1254557 was also added, which will be used..?
  ["spires of ascension"] = 354466,     -- Spires of Ascension
  ["stormstout brewery"] = 131205,      -- Stormstout Brewery
  ["tazavesh the veiled market"] = 367416, -- Tazavesh, the Veiled Market
  ["temple of sethraliss"] = 1286828,   -- Temple of Sethraliss
  ["temple of the jade serpent"] = 131204, -- Temple of the Jade Serpent
  ["the azure vault"] = 393279,         -- The Azure Vault
  ["the blinding vale"] = 1286801,      -- The Blinding Vale
  ["the dawnbreaker"] = 445414,         -- The Dawnbreaker
  ["the everbloom"] = 159901,           -- The Everbloom
  ["the necrotic wake"] = 354462,       -- The Necrotic Wake
  ["the nokhud offensive"] = 393262,    -- The Nokhud Offensive
  ["the rookery"] = 445443,             -- The Rookery
  ["the stonevault"] = 445269,          -- The Stonevault
  ["the underrot"] = 410074,            -- The Underrot
  ["the vortex pinnacle"] = 410080,     -- The Vortex Pinnacle
  ["theater of pain"] = 354467,         -- Theater of Pain
  ["throne of the tides"] = 424142,     -- Throne of the Tides
  ["uldaman legacy of tyr"] = 393222,   -- Uldaman: Legacy of Tyr
  ["upper blackrock spire"] = 159902,   -- Upper Blackrock Spire
  ["voidscar arena"] = 1286804,         -- Voidscar Arena
  ["waycrest manor"] = 424167,          -- Waycrest Manor
  ["windrunner spire"] = 1254400,       -- Windrunner Spire
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

--- Bind every teleport the player actually owns into the live lookups.
--- Driven by the game's own challenge-map list, so the season's mapIDs
--- are whatever the game says they are today.
local function discoverTeleports()
  teleportByDungeonLower = {}
  teleportByMapID = {}

  for mapID, dName in pairs(getChallengeDungeonNames()) do
    local spellID = TELEPORT_BY_DUNGEON[dName]
    if spellID and isSpellOwned(spellID) then
      teleportByMapID[mapID] = spellID
      teleportByDungeonLower[dName] = spellID
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
  -- Down only: registering both Down and Up fires the secure action twice
  -- (the release attempts a second cast mid-teleport → UI error noise).
  f.teleport:RegisterForClicks("AnyDown")
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

--- Remaining cooldown seconds on a teleport, or 0 when castable.
local function teleportCooldownRemaining(spellID)
  if not (C_Spell and C_Spell.GetSpellCooldown) then return 0 end
  local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
  if ok and type(info) == "table" then
    local remaining = (info.startTime or 0) + (info.duration or 0) - GetTime()
    if (info.duration or 0) > 1.5 and remaining > 0.1 then return remaining end
  end
  return 0
end

local function formatCdShort(seconds)
  if seconds >= 90 * 60 then return math.floor(seconds / 3600 + 0.5) .. "h" end
  if seconds >= 90 then return math.floor(seconds / 60 + 0.5) .. "m" end
  return math.floor(seconds + 0.5) .. "s"
end

--- Refresh the teleport button's visibility + bound spell. Combat-safe:
--- we only mutate secure attributes outside lockdown. When in combat we
--- leave the button state as-is and let the next out-of-combat refresh
--- catch up. Owned-but-on-cooldown teleports show as an inert button with
--- the remaining time instead of hiding entirely.
local cdTicker
local function refreshTeleportButton()
  if not widget or not widget.teleport then return end
  local btn = widget.teleport
  if InCombatLockdown() then return end

  local snap = ZugZugKeysDB.pendingKeyInfo
  local spellID = snap and teleportSpellIDForSnap(snap)
  local owned = spellID and isSpellOwned(spellID) or false
  local remaining = owned and teleportCooldownRemaining(spellID) or 0
  local ready = owned and remaining <= 0

  if ZugZugKeysDB.groupKeyInfoDebug then
    print(string.format(
      "|cffff8800ZZK refreshTeleportButton:|r snap.mapID=%s  snap.dungeon=%q  spellID=%s  ready=%s  cd=%.0fs",
      tostring(snap and snap.mapID),
      tostring(snap and snap.dungeon or ""),
      tostring(spellID),
      tostring(ready),
      remaining))
  end

  if ready then
    btn:SetAttribute("type", "spell")
    btn:SetAttribute("spell", spellID)
    btn.spellID = spellID
    btn.text:SetText("Teleport")
    btn.text:SetTextColor(1, 0.96, 0.74)
    if btn.SetBackdropBorderColor then
      btn:SetBackdropBorderColor(0.56, 0.75, 0.25, 0.85)
    end
    btn:Show()
    -- Grow the parent frame so the centered button has its own row and
    -- doesn't sit on top of the dungeon-name text.
    widget:SetHeight(FRAME_HEIGHT_WITH_BUTTON)
  elseif owned then
    -- On cooldown: keep it visible with the remaining time (tooltip still
    -- works via btn.spellID) but no cast attribute, so clicks are inert.
    btn:SetAttribute("type", nil)
    btn:SetAttribute("spell", nil)
    btn.spellID = spellID
    btn.text:SetText("Teleport — " .. formatCdShort(remaining))
    btn.text:SetTextColor(0.62, 0.62, 0.62)
    if btn.SetBackdropBorderColor then
      btn:SetBackdropBorderColor(0.4, 0.42, 0.36, 0.6)
    end
    btn:Show()
    widget:SetHeight(FRAME_HEIGHT_WITH_BUTTON)
  else
    btn:SetAttribute("type", nil)
    btn:SetAttribute("spell", nil)
    btn.spellID = nil
    btn:Hide()
    widget:SetHeight(FRAME_HEIGHT_NO_BUTTON)
  end

  -- Keep polling while the box is up and we own the teleport at all --
  -- NOT just while we believe a cooldown is running. A refresh taken
  -- during a loading screen reads duration 0 (the client hasn't synced
  -- cooldowns yet), which used to look like "ready" and cancel this
  -- ticker, leaving a stale off-cooldown button until the box closed.
  if owned then
    if not cdTicker then
      cdTicker = C_Timer.NewTicker(10, function()
        if widget and widget:IsShown() then
          pcall(refreshTeleportButton)
        elseif cdTicker then
          cdTicker:Cancel()
          cdTicker = nil
        end
      end)
    end
  elseif cdTicker then
    cdTicker:Cancel()
    cdTicker = nil
  end
end

--- Cooldown data is not trustworthy the instant a loading screen ends:
--- GetSpellCooldown answers duration 0 until the server syncs, which
--- reads as "off cooldown". One refresh on PLAYER_ENTERING_WORLD was
--- therefore sampling exactly the wrong moment. Take several passes as
--- the data settles instead of trusting the first answer.
local settleTimers = {}
local function refreshAfterLoadingScreen()
  -- Drop any passes still pending from a previous load; zoning twice in
  -- quick succession shouldn't stack two sets of timers.
  for _, t in ipairs(settleTimers) do
    if t and not t:IsCancelled() then t:Cancel() end
  end
  wipe(settleTimers)
  for _, delay in ipairs({ 0, 1, 3, 6, 12 }) do
    settleTimers[#settleTimers + 1] = C_Timer.NewTimer(delay, function()
      pcall(refreshTeleportButton)
    end)
  end
end

--- SPELL_UPDATE_COOLDOWN fires on every global cooldown, so coalesce
--- bursts into one refresh rather than rebuilding the button constantly.
local refreshPending = false
local function requestTeleportRefresh()
  if refreshPending then return end
  if not (widget and widget:IsShown()) then return end
  refreshPending = true
  C_Timer.After(0.5, function()
    refreshPending = false
    pcall(refreshTeleportButton)
  end)
end

local function showSnapshot(snap)
  if not snap then return end
  ZugZugKeysDB.pendingKeyInfo = snap
  local w = ensureWidget()
  w.title:SetText(snap.title and snap.title ~= "" and snap.title or "[no title]")
  -- Keystone-level chip: listings usually carry "+15" in the free-text
  -- title — surface it on the dungeon line unless it already shows one.
  local dungeonText = snap.dungeon or ""
  local lvl = snap.title and snap.title:match("%+%s?(%d%d?)")
  if lvl and not dungeonText:find("%+%d") then
    dungeonText = dungeonText .. "  |cffffd078+" .. lvl .. "|r"
  end
  w.dungeon:SetText(dungeonText)
  w:Show()
  refreshTeleportButton()
end

local function hideKeyInfo()
  ZugZugKeysDB.pendingKeyInfo = nil
  if widget then widget:Hide() end
  if cdTicker then
    cdTicker:Cancel()
    cdTicker = nil
  end
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

--- True if the LFG activity is a Mythic+ activity. Fails OPEN (returns
--- true) when the API or field is unavailable, so an API rename degrades
--- to the old behavior instead of silently killing the feature.
local function isMythicPlusActivity(activityID)
  if not activityID then return true end
  if not (C_LFGList and C_LFGList.GetActivityInfoTable) then return true end
  local ok, info = pcall(C_LFGList.GetActivityInfoTable, activityID)
  if not ok or type(info) ~= "table" then return true end
  if info.isMythicPlusActivity == nil then return true end
  return info.isMythicPlusActivity == true
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
  -- This box is an M+ feature — don't pop it for raid/questing/custom
  -- listings (the fallback label below would mislabel them "Mythic+").
  if not isMythicPlusActivity(activityID) then return nil end
  local dungeon, mapID = resolveActivity(activityID)

  -- Final fallback so the dungeon line isn't blank when the listing's
  -- activity is a generic "Mythic+" with no per-dungeon name attached.
  if not dungeon or dungeon == "" then dungeon = "Mythic+" end

  if (not title or title == "") and not dungeon then return nil end
  return { title = title, dungeon = dungeon, mapID = mapID }
end

--- Build the same snapshot shape from the player's OWN active LFG
--- listing (the listing they posted as leader). Used by the
--- group-fills-up path so leaders see the popup too, not just joiners.
local function snapshotOwnListing()
  if not (C_LFGList and C_LFGList.GetActiveEntryInfo) then return nil end
  local ok, info = pcall(C_LFGList.GetActiveEntryInfo)
  if not ok or type(info) ~= "table" then return nil end

  local title = info.name
  local activityID = info.activityID
  if not activityID and type(info.activityIDs) == "table" then
    activityID = info.activityIDs[1]
  end
  if not isMythicPlusActivity(activityID) then return nil end
  local dungeon, mapID = resolveActivity(activityID)
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
  local instanceName, _, _, _, _, _, _, instanceMapID = GetInstanceInfo()
  -- LFG activity map ids and GetInstanceInfo's instance id are different
  -- id spaces, so this equality almost never held and the box just never
  -- went away. Keep it (it's exact when it does match) but fall back to
  -- comparing the names, which is the same bridge the teleport lookup
  -- already relies on.
  if saved.mapID and instanceMapID and instanceMapID == saved.mapID then
    return true
  end
  local here = normalizeDungeonName(instanceName or "")
  local want = normalizeDungeonName(saved.dungeon or "")
  if here ~= "" and want ~= "" then
    return here == want or here:find(want, 1, true) ~= nil or want:find(here, 1, true) ~= nil
  end
  -- Nothing to compare on → hide on any party instance entry, as before.
  return true
end

-- Track whether we've already shown the popup for the current "group is
-- full" state, so GROUP_ROSTER_UPDATE doesn't re-fire every time someone
-- swaps spec / a ready check fires / etc. while still at 5 members.
-- Reset whenever the party drops below 5 (so re-fill triggers a new
-- popup) or we leave the group entirely.
local shownForCurrentFullGroup = false
-- Dedup for the "group has an active listing" trigger. The active entry is
-- group-scoped (readable by any member, not just the leader — confirmed in
-- Blizzard's own LFGList.lua: the ACTIVE_ENTRY_UPDATE handler isn't
-- leadership-gated and non-leaders/assistants read GetActiveEntryInfo).
-- The signal fires repeatedly (creation, edits, applicant churn), so we
-- show on the rising edge only and re-arm when the listing goes away.
local shownForActiveEntry = false

--- Show the popup if the player's group currently has an active LFG
--- listing. Works whether YOU listed it (leader) or a groupmate's leader
--- did (member) — GetActiveEntryInfo reflects the group's entry for all
--- members. Called from both LFG_LIST_ACTIVE_ENTRY_UPDATE (fires for the
--- listing owner) and GROUP_ROSTER_UPDATE (catches members for whom the
--- entry event may not fire, e.g. you were invited into an already-listed
--- group).
local function tryShowFromActiveEntry()
  if not ZugZugKeysDB.groupKeyInfo then return end
  local hasEntry = C_LFGList and C_LFGList.HasActiveEntryInfo
    and C_LFGList.HasActiveEntryInfo()
  if not hasEntry then
    shownForActiveEntry = false  -- delisted → re-arm for the next listing
    return
  end
  if shownForActiveEntry then return end  -- rising edge only
  local snap = snapshotOwnListing()
  if not snap then return end
  showSnapshot(snap)
  shownForActiveEntry = true
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("LFG_LIST_APPLICATION_STATUS_UPDATED")
-- Your own (or your group leader's) listing being created/updated. This is
-- the "my key is being listed" trigger — the popup should appear the moment
-- you post the group, before anyone applies and before it fills.
frame:RegisterEvent("LFG_LIST_ACTIVE_ENTRY_UPDATE")
-- Group composition changes. We watch for the moment the party hits 5
-- members so leaders / direct-invitees (who never went through LFG
-- application status events) also see the popup when their group fills.
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
-- Hide the popup when the player finishes casting the teleport — that's
-- their explicit "I'm done with this popup" signal. We use a unit-filtered
-- registration so the event ONLY fires for the player's own casts (no
-- party-member noise), which is cheaper than registering globally and
-- filtering on the unit string ourselves.
if frame.RegisterUnitEvent then
  frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
end
-- refreshTeleportButton is a deliberate no-op during combat lockdown —
-- catch up as soon as combat ends so a snapshot shown mid-combat can't
-- keep a stale teleport bound.
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
-- Cooldowns sync after the loading screen, not during it. This is the
-- event that tells us the teleport's real state has arrived.
frame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
-- A zone change without a full loading screen (and the delayed area
-- update after one) still wants a fresh look at both the cooldown and
-- "am I in the key yet".
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
-- The key going live is the clearest possible "I'm here, close the box".
frame:RegisterEvent("CHALLENGE_MODE_START")
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
    if isInTrackedInstance() then
      hideKeyInfo()
      return
    end
    refreshAfterLoadingScreen()
    return
  end

  if event == "ZONE_CHANGED_NEW_AREA" then
    if isInTrackedInstance() then
      hideKeyInfo()
      return
    end
    requestTeleportRefresh()
    return
  end

  if event == "CHALLENGE_MODE_START" then
    -- The key has started, so whatever the box was reminding us about is
    -- now moot regardless of which instance ids matched.
    hideKeyInfo()
    return
  end

  if event == "SPELL_UPDATE_COOLDOWN" then
    requestTeleportRefresh()
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

  if event == "LFG_LIST_ACTIVE_ENTRY_UPDATE" then
    tryShowFromActiveEntry()
    return
  end

  if event == "GROUP_ROSTER_UPDATE" then
    if not ZugZugKeysDB.groupKeyInfo then return end
    -- Catch the member case: if you're in a group that already has an
    -- active listing (you were invited into a listed group, or the
    -- ACTIVE_ENTRY_UPDATE event didn't fire for you), this picks it up.
    tryShowFromActiveEntry()
    local size = GetNumGroupMembers and GetNumGroupMembers() or 0
    -- M+ groups are exactly 5. Below that we reset the dedup flag so the
    -- next time the group fills we get one fresh popup. Above that
    -- (raid contexts) we ignore — the box is intended for 5-man M+.
    if size < 5 then
      shownForCurrentFullGroup = false
      return
    end
    if size > 5 then return end
    -- Exactly 5 members. Only fire once per fill-up event.
    if shownForCurrentFullGroup then return end
    -- Pull dungeon info from our own listing (we're the leader, or a
    -- direct invitee in a leader-listed group). If there's no listing
    -- (e.g. a hand-rolled group with no LFG entry), there's nothing
    -- useful to display — skip.
    local snap = snapshotOwnListing()
    if not snap then return end
    showSnapshot(snap)
    shownForCurrentFullGroup = true
    return
  end

  if event == "PLAYER_REGEN_ENABLED" then
    pcall(refreshTeleportButton)
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
    if spellID and TELEPORT_BY_DUNGEON then
      for _, teleSpellID in pairs(TELEPORT_BY_DUNGEON) do
        if spellID == teleSpellID then
          hideKeyInfo()
          return
        end
      end
    end
    return
  end
end)
