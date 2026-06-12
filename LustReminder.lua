----------------------------------------------------------------------
-- ZugZug Keys — Lust Reminder
-- Watches the active Mythic+ key for the right moment to pop lust:
--   1. Reads the active Mythic Dungeon Tools route (if loaded), scans
--      pull notes for a permissive lust pattern, computes the cumulative
--      enemy forces % at that pull.
--   2. Watches the live enemy-forces criterion (officially exposed in
--      12.0) and fires the alert when current% >= target% - lead.
--   3. Falls back to a curated boss-N recommendation via LustData if
--      MDT isn't loaded, no route is active for the dungeon, or the
--      route has no recognisable lust marker.
--   4. Fires at most once per key; re-arms on CHALLENGE_MODE_RESET.
----------------------------------------------------------------------

local Keys = _G.ZugZugKeys

----------------------------------------------------------------------
-- Pattern matching for lust notes in MDT route text
----------------------------------------------------------------------

-- Permissive but careful: long-form keywords match as substrings, but
-- the short abbreviations (BL / TW / HERO) only match as standalone
-- whitespace-delimited tokens so we don't false-positive on things like
-- "Blast" or "blow up".
local LUST_LONG = { "lust", "bloodlust", "heroism", "warp", "drums" }
local LUST_SHORT = { " bl ", " tw ", " hero ", " warp " }

--- Negation patterns — notes like "Better to not lust here" or "skip
--- bloodlust on this pull" should NOT match. We check these before the
--- positive patterns so the negative case shorts out.
local LUST_NEGATIONS = {
  "not lust", "no lust", "skip lust", "skip bloodlust", "without lust",
  "don't lust", "dont lust", "do not lust",
  "no bl", "skip bl", "without bl",
  "no hero", "no heroism", "skip hero", "skip heroism",
  "better to not", -- common Tactyks idiom
}

local function isLustNote(text)
  if type(text) ~= "string" or text == "" then return false end
  local lower = text:lower()
  for _, p in ipairs(LUST_NEGATIONS) do
    if lower:find(p, 1, true) then return false end
  end
  for _, p in ipairs(LUST_LONG) do
    if lower:find(p, 1, true) then return true end
  end
  -- Replace non-word chars with spaces, pad ends, then look for short tokens.
  local padded = " " .. (lower:gsub("[^%w%s]", " ")) .. " "
  for _, p in ipairs(LUST_SHORT) do
    if padded:find(p, 1, true) then return true end
  end
  return false
end

----------------------------------------------------------------------
-- Reading the active MDT route
-- MDT's saved-variable shape has shifted across versions. Try the
-- common access paths; bail out cleanly if anything is missing.
----------------------------------------------------------------------

--- Locate the dungeon index for an MDT preset. Tactyks routes put this
--- at `preset.value.currentDungeonIdx`. Fallback to MDT's global state.
local function getDungeonIdx(preset)
  if preset and preset.value and type(preset.value.currentDungeonIdx) == "number" then
    return preset.value.currentDungeonIdx
  end
  if _G.MDT and MDT.db and MDT.db.global and type(MDT.db.global.currentDungeonIdx) == "number" then
    return MDT.db.global.currentDungeonIdx
  end
  return nil
end

--- Modern MDT (12.0+) accesses its DB via MDT:GetDB(), not MDT.db. The
--- saved-variable backing store is `MythicDungeonToolsDB.global` per the
--- Ace3 profile model, with presets at `db.presets[dungeonIdx]`.
--- Declared BEFORE mdtMapIDForDungeon / mdtDungeonIdxForMapID because
--- Lua resolves local references at parse time, not call time — leaving
--- this further down made the callers fall through to a nil global.
local function mdtGetDB()
  if type(_G.MDT) ~= "table" then return nil end
  if type(MDT.GetDB) == "function" then
    local ok, db = pcall(MDT.GetDB, MDT)
    if ok and type(db) == "table" then return db end
  end
  -- Last-resort fallback for older MDT shapes.
  if type(MDT.db) == "table" and type(MDT.db.global) == "table" then
    return MDT.db.global
  end
  return nil
end

--- MDT exposes dungeon metadata in various shapes across versions. Try
--- several paths to map a dungeon index back to its challenge map ID.
--- Returns nil if not found.
local function mdtMapIDForDungeon(dungeonIdx)
  if not _G.MDT or not dungeonIdx then return nil end
  -- Path 1: MDT.mapInfo[dungeonIdx].mapID
  if type(MDT.mapInfo) == "table" and MDT.mapInfo[dungeonIdx]
      and type(MDT.mapInfo[dungeonIdx].mapID) == "number" then
    return MDT.mapInfo[dungeonIdx].mapID
  end
  -- Path 2: MDT.dungeonMaps[dungeonIdx].mapID
  if type(MDT.dungeonMaps) == "table" and MDT.dungeonMaps[dungeonIdx]
      and type(MDT.dungeonMaps[dungeonIdx].mapID) == "number" then
    return MDT.dungeonMaps[dungeonIdx].mapID
  end
  -- Path 3: MDT.dungeonList[dungeonIdx].mapID (older shape)
  if type(MDT.dungeonList) == "table" and MDT.dungeonList[dungeonIdx]
      and type(MDT.dungeonList[dungeonIdx].mapID) == "number" then
    return MDT.dungeonList[dungeonIdx].mapID
  end
  -- Path 4: MDT.zoneIdToDungeonIdx is the inverse map (zone/map → idx).
  -- Scan it backwards.
  if type(MDT.zoneIdToDungeonIdx) == "table" then
    for mapID, idx in pairs(MDT.zoneIdToDungeonIdx) do
      if idx == dungeonIdx and type(mapID) == "number" then return mapID end
    end
  end
  return nil
end

--- Reverse lookup: given an active challenge map ID, find MDT's dungeon
--- index. Tries MDT.zoneIdToDungeonIdx directly, then falls back to
--- walking every preset bucket.
local function mdtDungeonIdxForMapID(mapID)
  if not _G.MDT or not mapID then return nil end
  if type(MDT.zoneIdToDungeonIdx) == "table"
      and type(MDT.zoneIdToDungeonIdx[mapID]) == "number" then
    return MDT.zoneIdToDungeonIdx[mapID]
  end
  -- Iterate every dungeon idx that has a preset and check its mapID.
  local db = mdtGetDB()
  if db and type(db.presets) == "table" then
    for idx in pairs(db.presets) do
      if mdtMapIDForDungeon(idx) == mapID then return idx end
    end
  end
  -- Last resort: walk dungeonTotalCount (we know this exists from prior dumps).
  if type(MDT.dungeonTotalCount) == "table" then
    for idx in pairs(MDT.dungeonTotalCount) do
      if mdtMapIDForDungeon(idx) == mapID then return idx end
    end
  end
  return nil
end

--- Find MDT's dungeon index for the dungeon the player is currently
--- standing in (or running a key for). Tries every available signal so
--- we work whether or not the keystone has been inserted yet.
--- Returns dungeonIdx, source string (for diagnostic display) or nil, nil.
local function detectCurrentDungeonIdx()
  if not _G.MDT then return nil, "MDT not loaded" end

  -- (a) Active M+ key — only fires once the keystone is in.
  local okC, cMapID = pcall(C_ChallengeMode.GetActiveChallengeMapID)
  if okC and type(cMapID) == "number" and cMapID > 0 then
    local idx = mdtDungeonIdxForMapID(cMapID)
    if idx then return idx, "challenge mapID=" .. cMapID end
  end

  -- (b) Current UI map for the player. MDT.zoneIdToDungeonIdx is keyed
  -- by UIMapID for the dungeon's main map.
  if _G.C_Map and C_Map.GetBestMapForUnit then
    local okM, uiMapID = pcall(C_Map.GetBestMapForUnit, "player")
    if okM and type(uiMapID) == "number" and uiMapID > 0 then
      if type(MDT.zoneIdToDungeonIdx) == "table"
          and type(MDT.zoneIdToDungeonIdx[uiMapID]) == "number" then
        return MDT.zoneIdToDungeonIdx[uiMapID], "UIMapID=" .. uiMapID
      end
    end
  end

  -- (c) Current instance ID via GetInstanceInfo.
  local _, instType, _, _, _, _, _, instanceID = GetInstanceInfo()
  if (instType == "party" or instType == "raid") and type(instanceID) == "number" then
    if type(MDT.zoneIdToDungeonIdx) == "table"
        and type(MDT.zoneIdToDungeonIdx[instanceID]) == "number" then
      return MDT.zoneIdToDungeonIdx[instanceID], "instanceID=" .. instanceID
    end
    -- Fallback: walk presets and check instance IDs.
    if type(MDT.mapInfo) == "table" then
      for idx, info in pairs(MDT.mapInfo) do
        if type(info) == "table" and info.instanceID == instanceID then
          return idx, "MDT.mapInfo instanceID=" .. instanceID
        end
      end
    end
  end

  return nil, "no signal matched"
end

--- Given an active key's challenge map ID, return the user's most-recent
--- preset for that specific dungeon — even if MDT's UI is currently
--- displaying a different dungeon. Returns nil if no preset exists.
local function presetForActiveMapID(activeMapID)
  if not activeMapID or not _G.MDT then return nil end
  local db = mdtGetDB()
  if not db or type(db.presets) ~= "table" then return nil end
  local dungeonIdx = mdtDungeonIdxForMapID(activeMapID)
  if not dungeonIdx then return nil end
  local presets = db.presets[dungeonIdx]
  if type(presets) ~= "table" then return nil end
  -- MDT keeps the per-dungeon last-selected preset index in db.currentPreset.
  local presetIdx = (type(db.currentPreset) == "table"
                      and db.currentPreset[dungeonIdx])
                    or 1
  return presets[presetIdx], dungeonIdx, presetIdx
end

--- Sum one MDT pull's enemy count. Pull table shape (Tactyks / modern MDT):
---     pull[npc_slot] = { instance1, instance2, … }
---     pull.color     = "ff3eff"
--- Each NPC slot's per-kill forces value lives in
---     MDT.dungeonEnemies[dungeonIdx][npc_slot].count
--- So the pull total is sum over slots of (#instances × .count).
local function pullEnemyCount(pull, dungeonIdx)
  if type(pull) ~= "table" then return 0 end
  local enemies
  if _G.MDT and MDT.dungeonEnemies and dungeonIdx then
    enemies = MDT.dungeonEnemies[dungeonIdx]
  end
  local total = 0
  for k, v in pairs(pull) do
    if type(k) == "number" and type(v) == "table" then
      local instances = 0
      for _ in pairs(v) do instances = instances + 1 end
      local perKill = 0
      if enemies and enemies[k] and type(enemies[k].count) == "number" then
        perKill = enemies[k].count
      end
      total = total + instances * perKill
    end
  end
  return total
end

--- Walk every pull and sum.
local function preset_totalCount(preset)
  if not preset or not preset.value or not preset.value.pulls then return 0 end
  local idx = getDungeonIdx(preset)
  local total = 0
  for _, pull in ipairs(preset.value.pulls) do
    total = total + pullEnemyCount(pull, idx)
  end
  return total
end

--- Walk MDT's data to find the current preset's pulls. Returns the
--- preset table or nil if anything along the chain is missing.
--- Get the preset most relevant to right now. Uses every available
--- signal — active key, current UI map, current instance ID — to find
--- the dungeon the player is in, then returns that dungeon's
--- most-recent-selected preset.
--- Get the user's most-recent preset for a specific dungeon index,
--- regardless of where they're standing. Used by getCurrentPreset (with
--- the auto-detected idx) and by the /zzk lustsim diagnostic (with a
--- user-supplied idx, so we can test target extraction outside a key).
local function getPresetForDungeonIdx(dungeonIdx)
  if not _G.MDT or not dungeonIdx then return nil end
  local db = mdtGetDB()
  if not (db and type(db.presets) == "table") then return nil end
  local presets = db.presets[dungeonIdx]
  if type(presets) ~= "table" then return nil end
  local presetIdx = (type(db.currentPreset) == "table"
                      and db.currentPreset[dungeonIdx])
                    or 1
  local preset = presets[presetIdx]
  if type(preset) == "table" then return preset, presetIdx end
  return nil
end

local function getCurrentPreset()
  if not _G.MDT then return nil end

  -- (1) Detect the dungeon via any available signal.
  local dungeonIdx = detectCurrentDungeonIdx()
  if dungeonIdx then
    local preset = getPresetForDungeonIdx(dungeonIdx)
    if preset then return preset end
  end

  -- (2) Last resort: MDT's currently-displayed preset.
  if type(MDT.GetCurrentPreset) == "function" then
    local okP, preset = pcall(MDT.GetCurrentPreset, MDT)
    if okP and type(preset) == "table" then return preset end
  end
  local dbFallback = mdtGetDB()
  if dbFallback and type(dbFallback.presets) == "table" then
    local dispIdx = MDT.GetCurrentSubLevel
      and (pcall(MDT.GetCurrentSubLevel, MDT) and MDT:GetCurrentSubLevel())
      or dbFallback.currentDungeonIdx
    if dispIdx and dbFallback.presets[dispIdx] then
      local presets = dbFallback.presets[dispIdx]
      local idx = (type(dbFallback.currentPreset) == "table"
                    and dbFallback.currentPreset[dispIdx]) or 1
      return presets[idx]
    end
  end
  return nil
end

--- Look up the canonical dungeon total via MDT.dungeonTotalCount. The
--- table's value shape varies — sometimes a number, sometimes a table
--- keyed by difficulty/season (10, 11, …) and/or named keys. Falls
--- back to summing every pull if nothing usable is found.
local function totalForces(preset)
  local idx = getDungeonIdx(preset)
  if idx and _G.MDT and MDT.dungeonTotalCount then
    local totals = MDT.dungeonTotalCount[idx]
    if type(totals) == "number" and totals > 0 then return totals end
    if type(totals) == "table" then
      -- Try the preset's exact difficulty first.
      local diff = preset and preset.difficulty
      if diff and type(totals[diff]) == "number" and totals[diff] > 0 then
        return totals[diff]
      end
      -- Then named buckets and known difficulty integers.
      for _, key in ipairs({ "normal", "mythic", "teeming", 11, 10 }) do
        local v = totals[key]
        if type(v) == "number" and v > 0 then return v end
      end
      -- The value at a difficulty key may itself be a table holding the
      -- count under .normal/.teeming/etc.
      for _, candidate in pairs(totals) do
        if type(candidate) == "table" then
          for _, key in ipairs({ "normal", "mythic", "teeming", "count", "total" }) do
            local v = candidate[key]
            if type(v) == "number" and v > 0 then return v end
          end
          -- Or just the first numeric value in the sub-table.
          for _, v in pairs(candidate) do
            if type(v) == "number" and v > 0 then return v end
          end
        end
      end
      -- Last resort: first numeric value in the top-level totals table.
      for _, v in pairs(totals) do
        if type(v) == "number" and v > 0 then return v end
      end
    end
  end
  return preset_totalCount(preset)
end

--- Cumulative enemy count up to (but not including) pull N — i.e. the
--- count you'd have if you killed everything in pulls 1..(N-1) and were
--- about to start pull N. Returns 0 if pullIndex is 1.
local function cumulativeCountBeforePull(preset, pullIndex)
  if not preset or not preset.value or not preset.value.pulls then return 0 end
  local idx = getDungeonIdx(preset)
  local sum = 0
  for i = 1, (pullIndex or 1) - 1 do
    sum = sum + pullEnemyCount(preset.value.pulls[i], idx)
  end
  return sum
end

--- Concatenate every string-shaped, text-bearing field on an MDT object.
--- Different versions/authors put visible text in different fields:
---     text, note, l (string or array of lines), lines
--- Tactyks / current MDT puts note text inside the `d` array (usually d[5])
--- so we also harvest any string slot from there.
local function objectText(obj)
  if type(obj) ~= "table" then return "" end
  local pieces = {}
  if type(obj.text) == "string" then pieces[#pieces+1] = obj.text end
  if type(obj.note) == "string" then pieces[#pieces+1] = obj.note end
  if type(obj.l) == "string" then pieces[#pieces+1] = obj.l end
  if type(obj.l) == "table" then
    for _, line in ipairs(obj.l) do
      if type(line) == "string" then pieces[#pieces+1] = line end
    end
  end
  if type(obj.lines) == "table" then
    for _, line in ipairs(obj.lines) do
      if type(line) == "string" then pieces[#pieces+1] = line end
    end
  end
  if type(obj.d) == "table" then
    for _, v in pairs(obj.d) do
      if type(v) == "string" then pieces[#pieces+1] = v end
    end
  end
  return table.concat(pieces, " ")
end

--- Find a global note object containing a lust marker. Tactyks routes
--- (and modern MDT in general) put notes at `preset.objects` (top-level),
--- though some older / per-author conventions used `preset.value.objects`.
--- Scan both locations.
local function findLustNoteText(preset)
  if not preset then return nil end
  for _, source in ipairs({ preset.objects,
                            preset.value and preset.value.objects }) do
    if type(source) == "table" then
      for _, obj in ipairs(source) do
        local text = objectText(obj)
        if text ~= "" and isLustNote(text) then return text end
      end
    end
  end
  return nil
end

--- Find which pull contains a given MDT enemy "slot" (integer key into
--- `MDT.dungeonEnemies[dungeonIdx]`). Returns the first pull whose entries
--- reference that slot.
local function findPullContainingSlot(preset, slot)
  if not preset or not preset.value or not preset.value.pulls then return nil end
  for i, pull in ipairs(preset.value.pulls) do
    if type(pull) == "table" then
      for k, v in pairs(pull) do
        if k == slot and type(v) == "table" then return i end
      end
    end
  end
end

--- Get the dungeon's boss order. Each entry: { name, encounterID }.
--- Strategy:
---   (1) MDT.dungeonEnemies filtered to isBoss, sorted by NPC slot.
---       Authoritative for per-boss encounterIDs and works out-of-key.
---   (2) Encounter Journal fallback. Note: in 12.0 the
---       EJ_GetEncounterInfoByIndex signature shifted such that the
---       former dungeonEncounterID slot now returns the journal instance
---       ID for every boss (e.g. NPX returns 2658 for all 3 bosses) —
---       so we use EJ only for the boss *names* and ordering, never for
---       encounterIDs. Pair each EJ name with an MDT encounterID by
---       fuzzy-matching back to MDT.dungeonEnemies.
local function getDungeonBossOrder(preset)
  -- (1) MDT enemy data — slot-ordered, per-boss encounterIDs.
  if _G.MDT and MDT.dungeonEnemies then
    local idx = getDungeonIdx(preset)
    local enemies = idx and MDT.dungeonEnemies[idx]
    if type(enemies) == "table" then
      local indexed = {}
      for slot, e in pairs(enemies) do
        if type(e) == "table" and e.isBoss and e.encounterID
            and type(slot) == "number" then
          table.insert(indexed, {
            slot = slot, name = e.name, encounterID = e.encounterID,
          })
        end
      end
      if #indexed > 0 then
        table.sort(indexed, function(a, b) return a.slot < b.slot end)
        local out = {}
        for _, b in ipairs(indexed) do
          table.insert(out, { name = b.name, encounterID = b.encounterID })
        end
        return out
      end
    end
  end
  -- (2) EJ fallback — names only, encounterIDs left nil. (Better to
  -- return nil than the broken 2658-for-everything value.)
  if EJ_GetCurrentInstance and EJ_GetEncounterInfoByIndex then
    local ok, jInstanceID = pcall(EJ_GetCurrentInstance)
    if ok and type(jInstanceID) == "number" and jInstanceID > 0 then
      if EJ_SelectInstance then pcall(EJ_SelectInstance, jInstanceID) end
      local out = {}
      for i = 1, 20 do
        local name = EJ_GetEncounterInfoByIndex(i)
        if not name then break end
        table.insert(out, { name = name, encounterID = nil })
      end
      if #out > 0 then return out end
    end
  end
  return {}
end

--- Word → numeric ordinal. "first" → 1, "2nd" → 2, etc.
local ORDINAL_FROM_START = {
  first   = 1, ["1st"] = 1,
  second  = 2, ["2nd"] = 2,
  third   = 3, ["3rd"] = 3,
  fourth  = 4, ["4th"] = 4,
  fifth   = 5, ["5th"] = 5,
  sixth   = 6, ["6th"] = 6,
  seventh = 7, ["7th"] = 7,
}

--- Word → "N from the end". "last" → 1 (last is #boss order), "penultimate" → 2.
local ORDINAL_FROM_END = {
  last        = 1,
  final       = 1,
  ["end"]     = 1,
  penultimate = 2,
}

-- Words too generic to match against on their own. If the enemy name only
-- has stopwords + a unique word, we still match on the unique word; we
-- only skip the stopwords themselves.
local NAME_STOPWORDS = {
  ["the"]=true, ["of"]=true, ["and"]=true,
  ["lord"]=true, ["lady"]=true, ["master"]=true, ["sir"]=true, ["dame"]=true,
  ["baron"]=true, ["king"]=true, ["queen"]=true,
  ["captain"]=true, ["general"]=true, ["champion"]=true,
  ["high"]=true, ["dread"]=true, ["dark"]=true, ["holy"]=true,
  ["frost"]=true, ["fire"]=true,
  ["forgemaster"]=true, ["scourgelord"]=true,
}

--- Damerau-Levenshtein edit distance (handles single-char insert, delete,
--- substitute, and adjacent transposition). Returns the integer distance.
--- O(m·n) time, O(m·n) memory — fine for the ≤20-char strings we use.
local function damerauLevenshtein(a, b)
  if a == b then return 0 end
  local la, lb = #a, #b
  if la == 0 then return lb end
  if lb == 0 then return la end
  local dp = {}
  for i = 0, la do dp[i] = { [0] = i } end
  for j = 0, lb do dp[0][j] = j end
  for i = 1, la do
    local ai = a:byte(i)
    for j = 1, lb do
      local cost = (ai == b:byte(j)) and 0 or 1
      local v = dp[i-1][j] + 1                  -- delete
      local v2 = dp[i][j-1] + 1                 -- insert
      if v2 < v then v = v2 end
      v2 = dp[i-1][j-1] + cost                  -- substitute
      if v2 < v then v = v2 end
      if i > 1 and j > 1
          and ai == b:byte(j-1)
          and a:byte(i-1) == b:byte(j) then
        v2 = dp[i-2][j-2] + 1                   -- transposition
        if v2 < v then v = v2 end
      end
      dp[i][j] = v
    end
  end
  return dp[la][lb]
end

--- Match an MDT enemy name against the note text. Three passes, narrowest
--- to widest:
---   Pass A — direct substring (full enemy name in the note)
---   Pass B — split enemy name into words and check each ≥5-char,
---            non-stopword word as a substring of the note
---   Pass C — Damerau-Levenshtein typo tolerance: for each ≥8-char word in
---            the note, compare against each significant enemy word with a
---            length-scaled distance cap (1 for words ≤10 chars, 2 above).
--- Returns matched=true plus a "via" tag for the dry-run.
local function fuzzyEnemyMatch(noteText, enemyName)
  if type(noteText) ~= "string" or type(enemyName) ~= "string"
      or #enemyName < 4 or #noteText < 3 then
    return false
  end
  local lowerNote  = noteText:lower()
  local lowerEnemy = enemyName:lower()

  -- Pass A: full name appears anywhere in the note
  if lowerNote:find(lowerEnemy, 1, true) then
    return true, "full"
  end

  -- Pass B: any significant word from the enemy name appears in the note
  for word in lowerEnemy:gmatch("[%w']+") do
    if #word >= 5 and not NAME_STOPWORDS[word]
        and lowerNote:find(word, 1, true) then
      return true, "word:" .. word
    end
  end

  -- Pass C: typo tolerance. Tight thresholds keep false-positives down.
  --   note word length: ≥8
  --   enemy word length: ≥6
  --   max(|noteWord|, |enemyWord|) → tolerance: ≤10 ⇒ 1, else 2
  for noteWord in lowerNote:gmatch("[%w]+") do
    if #noteWord >= 8 and not NAME_STOPWORDS[noteWord] then
      for enemyWord in lowerEnemy:gmatch("[%w']+") do
        if #enemyWord >= 6 and not NAME_STOPWORDS[enemyWord] then
          local maxLen = (#noteWord > #enemyWord) and #noteWord or #enemyWord
          local tol = (maxLen <= 10) and 1 or 2
          -- Cheap length-diff prefilter avoids the DP table for impossible cases.
          if math.abs(#noteWord - #enemyWord) <= tol then
            local d = damerauLevenshtein(noteWord, enemyWord)
            if d <= tol then
              return true, "typo:" .. noteWord .. "~" .. enemyWord
            end
          end
        end
      end
    end
  end

  return false
end

--- Scan the lust note for every reference it contains — both literal
--- "pull N" mentions and named-enemy mentions (matched against the
--- dungeon's enemy table). Returns a list ordered by where each
--- reference appears in the note, deduplicated.
---
--- Each entry: { kind = "pull", pullIndex = N, name = nil|"Garfrost" }
---             { kind = "boss", encounterID = ID,  name = "Garfrost" }
local function extractTargetsFromNote(noteText, preset)
  if type(noteText) ~= "string" then return {} end
  local lower = noteText:lower()

  -- (1) Collect raw hits with the byte-offset where each was found in
  -- the note. Boss/enemy hits get resolved further down.
  local hits = {}

  -- "pull N"
  do
    local start = 1
    while true do
      local s, e, n = lower:find("pull%s+(%d+)", start)
      if not s then break end
      local num = tonumber(n)
      if num then
        table.insert(hits, {
          pos = s, kind = "pull", pullIndex = num,
          matchedBy = "pull-ref",
        })
      end
      start = e + 1
    end
  end

  -- "<ordinal> pull" — e.g. "first pull", "last pull", "2nd pull". Uses
  -- the same ordinal tables as the boss-ordinal path below. Resolved to
  -- a concrete pull index now (well-known) or to "first-combat" when the
  -- ordinal is "first" and no pulls table is available yet.
  if preset and preset.value and type(preset.value.pulls) == "table" then
    local numPulls = #preset.value.pulls
    for s, word in lower:gmatch("()(%a+)%s+pull%f[%W]") do
      local fromStart = ORDINAL_FROM_START[word]
      local fromEnd   = ORDINAL_FROM_END[word]
      local pullIdx
      if fromStart then
        pullIdx = fromStart
      elseif fromEnd then
        pullIdx = numPulls - fromEnd + 1
      end
      if pullIdx and pullIdx >= 1 and pullIdx <= numPulls then
        table.insert(hits, {
          pos = s, kind = "pull", pullIndex = pullIdx,
          matchedBy = "ordinal:" .. word,
        })
      end
    end
  end

  -- Boss-ordinal references — "first boss", "last boss", "boss 3", etc.
  -- Resolved via the dungeon's boss order list (EJ or MDT-derived).
  local bossOrder = getDungeonBossOrder(preset)
  if #bossOrder > 0 then
    -- "<word> boss" — first/last/2nd/penultimate/etc.
    for s, word in lower:gmatch("()(%a+)%s+boss%f[%W]") do
      local fromStart = ORDINAL_FROM_START[word]
      local fromEnd   = ORDINAL_FROM_END[word]
      local bossIdx
      if fromStart then
        bossIdx = fromStart
      elseif fromEnd then
        bossIdx = #bossOrder - fromEnd + 1
      end
      if bossIdx and bossIdx >= 1 and bossIdx <= #bossOrder then
        local boss = bossOrder[bossIdx]
        if boss.encounterID then
          table.insert(hits, {
            pos = s, kind = "boss",
            encounterID = boss.encounterID, name = boss.name,
            matchedBy = "ordinal:" .. word .. " boss",
          })
        end
      end
    end
    -- "boss <number>" — boss 1, boss 3, etc.
    for s, num in lower:gmatch("()boss%s+(%d+)") do
      local idx = tonumber(num)
      if idx and idx >= 1 and idx <= #bossOrder then
        local boss = bossOrder[idx]
        if boss.encounterID then
          table.insert(hits, {
            pos = s, kind = "boss",
            encounterID = boss.encounterID, name = boss.name,
            matchedBy = "ordinal:boss " .. idx,
          })
        end
      end
    end
  end

  -- Enemy names — fuzzy match each enemy from the dungeon's MDT data.
  --   Pass A finds the full name in the note ("Glacieth").
  --   Pass B finds a significant word from the MDT name in the note
  --     ("Garfrost" mentioned in note even though MDT calls it
  --      "Forgemaster Garfrost").
  -- The matched word's position in the note is used to preserve the
  -- author's intended ordering.
  if _G.MDT and preset then
    local dungeonIdx = getDungeonIdx(preset)
    local enemies = MDT.dungeonEnemies and dungeonIdx and MDT.dungeonEnemies[dungeonIdx]
    if type(enemies) == "table" then
      for slot, e in pairs(enemies) do
        if type(e) == "table" and type(e.name) == "string" then
          local matched, via = fuzzyEnemyMatch(noteText, e.name)
          if matched then
            -- Find a stable position to sort by. For "full" matches use the
            -- start of the full name; for "word:foo" or "typo:noteword~..."
            -- matches use the position of the actual token in the note so
            -- ordering reflects what the author wrote.
            local pos
            if via == "full" then
              pos = lower:find(e.name:lower(), 1, true)
            elseif via:sub(1, 5) == "typo:" then
              local noteWord = via:sub(6):match("^(.-)~")
              if noteWord then pos = lower:find(noteWord, 1, true) end
            else  -- "word:foo"
              pos = lower:find(via:sub(6), 1, true)
            end
            if e.isBoss and e.encounterID then
              table.insert(hits, {
                pos = pos or 1, kind = "boss",
                encounterID = e.encounterID, name = e.name, matchedBy = via,
              })
            else
              local pullIdx = findPullContainingSlot(preset, slot)
              if pullIdx then
                table.insert(hits, {
                  pos = pos or 1, kind = "pull",
                  pullIndex = pullIdx, name = e.name, matchedBy = via,
                })
              end
            end
          end
        end
      end
    end
  end

  -- (2) Sort by note position so the output mirrors the author's order.
  table.sort(hits, function(a, b) return a.pos < b.pos end)

  -- (3) Deduplicate.
  --   * Pulls dedup by pullIndex.
  --   * Bosses dedup by NAME (not encounterID) — because MDT stores
  --     the journal instance ID in the per-boss encounterID field for
  --     every boss in a dungeon (e.g. every NPX boss shows encID 2658),
  --     keying on encID would collapse 3 distinct boss targets into 1.
  --   * If a boss-hit exists for an enemy name AND a pull-hit also
  --     references that same enemy name (typically when an MDT entry
  --     exists for both the boss form and a trash spawn of the same
  --     enemy), the boss-hit wins. The pull-hit would fire at a slightly
  --     different time but conceptually targets the same encounter.
  --     "pull N" references stay because they have no enemy name.
  local bossNames = {}
  for _, h in ipairs(hits) do
    if h.kind == "boss" and type(h.name) == "string" then
      bossNames[h.name:lower()] = true
    end
  end

  local out, seen = {}, {}
  for _, h in ipairs(hits) do
    local key
    if h.kind == "pull" then
      -- Drop if this pull-hit's enemy name is already covered by a boss-hit.
      if type(h.name) == "string" and bossNames[h.name:lower()] then
        key = nil  -- skip
      else
        key = "p" .. tostring(h.pullIndex)
      end
    else
      key = "b" .. tostring(h.name or h.encounterID)
    end
    if key and not seen[key] then
      seen[key] = true
      table.insert(out, h)
    end
  end
  return out
end

--- Legacy helper kept for the dump/diagnostic paths. Walks the same
--- pull-N regex extractTargetsFromNote uses but in a simpler shape.
local function extractPullRefs(text)
  if type(text) ~= "string" then return {} end
  local found, seen = {}, {}
  for n in text:lower():gmatch("pull%s+(%d+)") do
    local num = tonumber(n)
    if num and not seen[num] then
      seen[num] = true
      table.insert(found, num)
    end
  end
  return found
end

--- Resolve boss names mentioned in the lust note to encounterIDs by
--- cross-referencing MDT.dungeonEnemies for the active dungeon. Catches
--- "Araknath" / "High Sage" tokens in a Tactyks note.
local function extractBossEncounterIDs(noteText, preset)
  if type(noteText) ~= "string" or not _G.MDT then return {} end
  local dungeonIdx = getDungeonIdx(preset)
  if not dungeonIdx then return {} end
  local enemies = MDT.dungeonEnemies and MDT.dungeonEnemies[dungeonIdx]
  if type(enemies) ~= "table" then return {} end
  local lower = noteText:lower()
  local found, seen = {}, {}
  for _, enemy in pairs(enemies) do
    if type(enemy) == "table"
        and enemy.isBoss and enemy.encounterID
        and type(enemy.name) == "string" and enemy.name ~= ""
        and lower:find(enemy.name:lower(), 1, true)
        and not seen[enemy.encounterID] then
      seen[enemy.encounterID] = true
      table.insert(found, enemy.encounterID)
    end
  end
  return found
end

--- Locate the lust target. Strategy:
---   1) Tactyks-style: a global note in `objects` lists pulls/bosses
---      ("Lust on pull 1, Araknath, and High Sage")
---   2) Per-pull notes — older / per-author convention
--- Extract the lust target list from a specific preset. Pure function:
--- no global state access, no event firing, no MDT mutations. Designed so
--- the /zzk lustsim command can call it on any preset for out-of-key
--- testing of the parse pipeline.
local function findLustTargetFromPreset(preset)
  if not preset or not preset.value or type(preset.value.pulls) ~= "table" then
    return nil
  end
  local total = totalForces(preset) or 0
  local noteText = findLustNoteText(preset)
  if noteText then
    local hits = extractTargetsFromNote(noteText, preset)
    if #hits > 0 then
      return {
        source     = "mdt",
        noteSource = "object",
        note       = noteText,
        hits       = hits,
        totalCount = total,
      }
    end
  end
  for i, pull in ipairs(preset.value.pulls) do
    local note = pull.text or pull.note or pull.notes
    if isLustNote(note) then
      return {
        source     = "mdt",
        noteSource = "pull",
        note       = note,
        hits       = { { kind = "pull", pullIndex = i } },
        totalCount = total,
      }
    end
  end
  return nil
end

local function findLustTargetFromMDT()
  return findLustTargetFromPreset(getCurrentPreset())
end

----------------------------------------------------------------------
-- Curated fallback
----------------------------------------------------------------------

local function findCuratedFallback(challengeMapID)
  if not ZugZugKeysDB.lustReminderCuratedFallback then return nil end
  local data = _G.ZugZugKeysLustData
  if type(data) ~= "table" then return nil end
  local entry = data[challengeMapID]
  if not entry or type(entry.encounterIDs) ~= "table" then return nil end
  return {
    source       = "curated",
    encounterIDs = entry.encounterIDs,
    name         = entry.name,
    note         = entry.note,
  }
end

----------------------------------------------------------------------
-- Per-key state
----------------------------------------------------------------------

-- Each target is a row in state.targets:
--   { kind = "pull", pullIndex = N, targetPct = X, fired = false,
--     fireOnFirstCombat = bool }
--   { kind = "boss", encounterID = ID, fired = false }
local state = {
  active             = false,
  mapID              = nil,
  routeNote          = nil,
  source             = nil,    -- "mdt" | "curated"
  noteSource         = nil,    -- "object" | "pull" | nil
  targets            = {},     -- ordered list of fire-able targets
  firstCombatHandled = false,
  -- Diagnostics: counters and last-seen values that let `/zzk lust` mid-key
  -- diagnose why forces-based targets aren't firing.
  scenarioUpdateCount = 0,
  forcesCheckCount    = 0,
  lastForcesPct       = nil,
  lastForcesAt        = nil,
  lastForcesErr       = nil,
}

local backupTicker

local function debug(msg)
  if ZugZugKeysDB.lustReminderDebug then
    print("|cffFF8800ZZK Lust:|r " .. tostring(msg))
  end
end

-- Classes that natively bring a Bloodlust / Heroism / Time Warp / Primal
-- Rage / Fury of the Aspects effect. Members of these classes are the
-- ones we want to remind. Other classes get silently no-opped because
-- the reminder isn't actionable for them.
local LUST_CAPABLE_CLASSES = {
  SHAMAN = true,    -- Bloodlust / Heroism
  MAGE   = true,    -- Time Warp
  HUNTER = true,    -- Primal Rage (BM pet — but every hunter knows about it)
  EVOKER = true,    -- Fury of the Aspects
}

local function canPlayerLust()
  local _, classToken = UnitClass("player")
  return classToken ~= nil and LUST_CAPABLE_CLASSES[classToken] == true
end

--- Full reset — wipes targets and diagnostics. Only called when a brand new
--- key starts via CHALLENGE_MODE_START so we don't carry stale data forward.
local function resetState()
  state.active = false
  state.mapID = nil
  state.routeNote = nil
  state.presetName = nil
  state.source = nil
  state.noteSource = nil
  state.targets = {}
  state.firstCombatHandled = false
  state.scenarioUpdateCount = 0
  state.forcesCheckCount = 0
  state.lastForcesPct = nil
  state.lastForcesAt = nil
  state.lastForcesErr = nil
  state.criteriaSnapshot = nil
  state.criteriaSnapshotErr = nil
  state.criteriaSnapshotAt = nil
  state.lastStepPct = nil
  state.lastForcesSource = nil
  if backupTicker then backupTicker:Cancel(); backupTicker = nil end
end

--- Soft deactivate — stops the ticker and marks the key inactive but
--- preserves all targets + diagnostics so `/zzk lust` after the key can
--- show what fired (and what didn't). Cleared on the next key start.
local function deactivate()
  state.active = false
  if backupTicker then backupTicker:Cancel(); backupTicker = nil end
end

----------------------------------------------------------------------
-- On-screen popup
----------------------------------------------------------------------

local popup
local function ensurePopup()
  if popup then return popup end
  popup = CreateFrame("Frame", "ZugZugKeysLustPopup", UIParent, "BackdropTemplate")
  popup:SetSize(380, 76)
  popup:SetFrameStrata("DIALOG")
  popup:SetClampedToScreen(true)
  -- Flush against the top-center of the screen, matching the Group Key Info box.
  popup:SetPoint("TOP", UIParent, "TOP", 0, 0)

  if popup.SetBackdrop then
    popup:SetBackdrop({
      bgFile   = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      edgeSize = 14,
      insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    popup:SetBackdropColor(0.05, 0.07, 0.05, 0.94)
    popup:SetBackdropBorderColor(0.40, 0.52, 0.18, 1)  -- darkened ZugZug green
  end

  -- Subtle inner accent line at the top of the content area.
  popup.accent = popup:CreateTexture(nil, "BORDER")
  popup.accent:SetColorTexture(0.56, 0.75, 0.25, 0.55)
  popup.accent:SetHeight(1)
  popup.accent:SetPoint("TOPLEFT", popup, "TOPLEFT", 6, -6)
  popup.accent:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -6, -6)

  -- Title — warm-cream, outlined, mirroring the KeyInfo title.
  popup.title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  popup.title:SetFont(STANDARD_TEXT_FONT, 16, "OUTLINE")
  popup.title:SetPoint("TOPLEFT", popup, "TOPLEFT", 28, -14)
  popup.title:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -28, -14)
  popup.title:SetJustifyH("CENTER")
  popup.title:SetWordWrap(false)
  popup.title:SetText("LUST NOW")
  popup.title:SetTextColor(1, 0.96, 0.74)  -- warm cream

  -- Subtitle — ZugZug green, matches the dungeon line on the KeyInfo box.
  popup.sub = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  popup.sub:SetFont(STANDARD_TEXT_FONT, 14, "")
  popup.sub:SetPoint("TOPLEFT", popup.title, "BOTTOMLEFT", 0, -8)
  popup.sub:SetPoint("TOPRIGHT", popup.title, "BOTTOMRIGHT", 0, -8)
  popup.sub:SetJustifyH("CENTER")
  popup.sub:SetTextColor(0.56, 0.75, 0.25)

  popup:Hide()
  return popup
end

local function showPopup(title, sub)
  local p = ensurePopup()
  p.title:SetText(title or "LUST NOW")
  p.sub:SetText(sub or "")
  p:Show()
  C_Timer.After(8, function() if p then p:Hide() end end)
end

----------------------------------------------------------------------
-- Alert
----------------------------------------------------------------------

--- Find a target's 1-based index within state.targets (so the alert
--- can say "LUST 2/3").
local function targetIndex(target)
  for i, t in ipairs(state.targets) do
    if t == target then return i end
  end
end

local function fireAlert(target, reason)
  if not target or target.fired then return end
  target.fired = true

  local count = #state.targets
  local idx   = targetIndex(target) or 1
  local headline
  if count > 1 then
    headline = string.format(
      "|cffff8800ZugZug Keys:|r |cffffd078LUST %d/%d|r", idx, count)
  else
    headline = "|cffff8800ZugZug Keys:|r |cffffd078LUST NOW|r"
  end

  local detail
  if target.kind == "pull" then
    if target.name then
      detail = string.format("%s — pull %d at %.0f%% forces",
        target.name, target.pullIndex or 0, target.targetPct or 0)
    else
      detail = string.format("pull %d at %.0f%% forces",
        target.pullIndex or 0, target.targetPct or 0)
    end
  elseif target.kind == "boss" then
    detail = (target.name and (target.name .. " engaged")) or
             ("boss engaged (encounterID " .. tostring(target.encounterID) .. ")")
  end
  if reason and reason ~= "" then
    detail = (detail and (detail .. " — ") or "") .. reason
  end
  detail = detail or ""

  print(headline .. " — " .. detail)
  local popupTitle = (count > 1)
    and string.format("LUST %d/%d", idx, count)
    or "LUST NOW"
  showPopup(popupTitle, detail)

  if ZugZugKeysDB.lustReminderSound then
    pcall(PlaySound, _G.SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
  end
end

----------------------------------------------------------------------
-- Forces % helpers
----------------------------------------------------------------------

--- Defensive guard: return true if `v` is a Midnight Secret Value. Any
--- arithmetic or comparison on a Secret throws a Lua error, so any code
--- path that operates on potentially-secret values must check this
--- first.
---
--- As of 12.0 the scenario criteria fields we read (`isWeightedProgress`,
--- `totalQuantity`, `quantityString`) are NOT Secret in M+ keys — verified
--- against WarpDeplete (which compares them directly without any guard)
--- and the Blizzard API docs (zero field-level SecretWhenInX predicates
--- on C_ScenarioInfo.GetCriteriaInfo). But Blizzard can flip any API to
--- Secret in a future patch, so we check anyway. Better degrade than crash.
---
--- Declared up here (before snapshotScenario and getEnemyForcesPct) so
--- Lua's parse-time local resolution can see it.
local function isSecret(v)
  if _G.issecretvalue then
    local ok, result = pcall(_G.issecretvalue, v)
    if ok then return result == true end
  end
  return false
end

--- Capture the scenario step + every criterion into a plain Lua snapshot
--- so we can inspect what M+ is actually exposing.
---
--- Canonical 12.0 path (matches WarpDeplete's UpdateObjectives):
---   * `C_Scenario.GetStepInfo()` still works; 3rd return value is the
---     criterion count for the active step
---   * `C_ScenarioInfo.GetCriteriaInfo(i)` returns the table-shaped info
---     for each criterion index (1..numCriteria)
---   * `C_ScenarioInfo.GetStepInfo` was removed in 12.0 — don't use it
local function snapshotScenario()
  if not (_G.C_Scenario and C_Scenario.GetStepInfo) then
    return nil, "C_Scenario.GetStepInfo nil"
  end
  if not (_G.C_ScenarioInfo and C_ScenarioInfo.GetCriteriaInfo) then
    return nil, "C_ScenarioInfo.GetCriteriaInfo nil"
  end

  -- C_Scenario.GetStepInfo returns multiple values. The 3rd is numCriteria.
  -- It returns nothing useful (or zero criteria) when not in a scenario,
  -- so we treat numCriteria == 0 as "no active scenario step".
  local ok, name, currentStage, numCriteria = pcall(C_Scenario.GetStepInfo)
  if not ok then return nil, "GetStepInfo errored: " .. tostring(name) end
  numCriteria = type(numCriteria) == "number" and numCriteria or 0
  if numCriteria <= 0 then
    return nil, "no active scenario (numCriteria=" .. tostring(numCriteria) .. ")"
  end

  local snap = {
    stepName    = name,
    currentStage = currentStage,
    numCriteria = numCriteria,
    criteria    = {},
  }
  for i = 1, numCriteria do
    local ok2, crit = pcall(C_ScenarioInfo.GetCriteriaInfo, i)
    if not ok2 then
      snap.criteria[i] = { error = tostring(crit) }
    elseif type(crit) ~= "table" then
      snap.criteria[i] = { otherType = type(crit) }
    else
      -- Copy each field individually inside its own pcall so a single
      -- field becoming Secret in a future patch doesn't crater the whole
      -- snapshot. We record the secret-status so /zzk lust can show it.
      local row = { __secret = {} }
      local function take(name)
        local okv, val = pcall(function() return crit[name] end)
        if not okv then row.__secret[name] = "read errored" return end
        if val ~= nil and (function()
              local ok3, isS = pcall(isSecret, val)
              return ok3 and isS
            end)() then
          row.__secret[name] = "secret"
          return
        end
        row[name] = val
      end
      take("quantity")
      take("totalQuantity")
      take("isWeightedProgress")
      take("description")
      take("quantityString")
      take("criteriaType")
      take("completed")
      take("elapsed")
      snap.criteria[i] = row
    end
  end
  return snap
end

-- (Widget-scan path removed 2026-06-11 — the M+ forces display is NOT
-- routed through any UI widget set in 12.0. Canonical path is now the
-- C_ScenarioInfo.GetCriteriaInfo loop in getEnemyForcesPct below; we
-- verified empirically (`/zzk lustscan 500` returned zero matches in
-- multiple keys) and against WarpDeplete's reference implementation.)

--- Returns the current enemy forces percentage (0..100), or nil if there
--- is no active M+ scenario.
---
--- Canonical 12.0 path (verified against WarpDeplete's UpdateObjectives,
--- which is the reference implementation for M+ trackers post-Midnight):
---
---   1. `C_Scenario.GetStepInfo()` 3rd return value = criterion count
---   2. For each i = 1..numCriteria, fetch `C_ScenarioInfo.GetCriteriaInfo(i)`
---   3. The Enemy Forces criterion is the one with `info.isWeightedProgress = true`
---   4. Current count = `tonumber(info.quantityString:match("%d+"))` — the
---      `quantity` field is often 0 in 12.0 even when there's progress;
---      `quantityString` is what's actually shown in the scenario tracker
---   5. Percentage = (current / info.totalQuantity) * 100
---
--- All comparisons + arithmetic are pcall-wrapped so that if a future
--- patch flips any of these fields to a Secret Value, we return nil and
--- log a clear diagnostic message instead of erroring out the tick.
---
--- The UI-widget scan (`readForcesFromWidgets`) is kept only for the
--- `/zzk lustscan` diagnostic — Blizzard moved forces *out* of widgets
--- before 12.0.5 so it's no longer reachable that way in any live key.
local function getEnemyForcesPct()
  -- Always snapshot the criteria for the /zzk lust diagnostic, even if
  -- we end up returning nil (e.g. outside a scenario).
  local snap, err = snapshotScenario()
  state.criteriaSnapshot    = snap
  state.criteriaSnapshotErr = err
  state.criteriaSnapshotAt  = GetTime()

  if not snap then return nil end

  for i, c in ipairs(snap.criteria) do
    if type(c) ~= "table" or c.error or c.otherType then
      -- skip
    elseif isSecret(c.isWeightedProgress)
        or isSecret(c.totalQuantity)
        or isSecret(c.quantityString) then
      state.lastForcesSource = string.format(
        "criteria idx %d has secret values — Blizzard restricted this API; skipping", i)
    else
      -- pcall every operation that could fail if a value silently became
      -- Secret without us catching it via isSecret() — defence in depth.
      local ok, pct, current, qStr = pcall(function()
        if not c.isWeightedProgress then return nil end
        if type(c.totalQuantity) ~= "number" or c.totalQuantity <= 0 then
          return nil
        end
        local qs = (type(c.quantityString) == "string") and c.quantityString or ""
        local cur = tonumber(qs:match("(%d+)")) or tonumber(c.quantity) or 0
        local p = (cur / c.totalQuantity) * 100
        if p < 0 then p = 0 end
        if p > 100 then p = 100 end
        return p, cur, qs
      end)
      if not ok then
        state.lastForcesSource = "pcall errored on criteria idx " .. i
          .. " — possible undocumented Secret Value: " .. tostring(pct)
      elseif type(pct) == "number" then
        state.lastStepPct      = pct
        state.lastForcesSource = string.format(
          "criteria idx %d  qStr=%q  current=%d / total=%d  desc=%q",
          i, tostring(qStr), current, c.totalQuantity, tostring(c.description))
        return pct
      end
    end
  end

  state.lastForcesSource = state.lastForcesSource
    or "no isWeightedProgress criterion found"
  return nil
end

----------------------------------------------------------------------
-- Key lifecycle
----------------------------------------------------------------------

local function loadTargetForCurrentKey()
  if not ZugZugKeysDB.lustReminder then return end
  if not canPlayerLust() then
    -- Stay silent for non-lust classes — the reminder isn't useful for
    -- them. The /zzk lust status command surfaces this state if needed.
    debug("player's class isn't a lust-capable class; reminder suppressed")
    return
  end

  local mapID
  local ok, id = pcall(C_ChallengeMode.GetActiveChallengeMapID)
  if ok then mapID = Keys.safeNum and Keys.safeNum(id) or (type(id) == "number" and id or nil) end
  state.mapID = mapID
  state.active = true
  state.fired = false

  -- Diagnostic: confirm CHALLENGE_MODE_START reached here. Helps the
  -- user tell "event didn't fire" from "route has no parseable note".
  do
    local preview = getCurrentPreset()
    local pname   = (preview and preview.text) or "(no preset resolved)"
    print(string.format("|cffff8800ZugZug Keys:|r key started — using MDT route '%s'.",
      tostring(pname)))
  end

  -- Try MDT route first.
  local mdt = findLustTargetFromMDT()
  if mdt then
    local preset = getCurrentPreset()
    -- Sanity check: confirm the preset we resolved actually belongs to
    -- the active key's dungeon. Tells the user *why* it failed if the
    -- preset is for a different dungeon (almost always: no preset
    -- imported in MDT for this dungeon yet).
    local activeMapID      = mapID
    local presetDungeonIdx = getDungeonIdx(preset)
    local presetMapID      = mdtMapIDForDungeon(presetDungeonIdx)
    if activeMapID and presetMapID and activeMapID ~= presetMapID then
      local activeDungeonIdx = mdtDungeonIdxForMapID(activeMapID)
      local activeName = (_G.MDT and MDT.dungeonList and MDT.dungeonList[activeDungeonIdx])
                        or ("dungeonIdx " .. tostring(activeDungeonIdx))
      print(string.format(
        "|cffff4444ZugZug Keys:|r no MDT route loaded for %s. Open MDT, switch to that dungeon's tab and import a route (e.g. Tactyks), then /reload.",
        tostring(activeName)))
      state.active = false
      return
    end

    state.source     = "mdt"
    state.noteSource = mdt.noteSource
    state.routeNote  = mdt.note
    state.presetName = (preset and preset.text) or nil

    local total = preset and totalForces(preset) or 0
    for _, h in ipairs(mdt.hits or {}) do
      if h.kind == "pull" then
        local cum = (total > 0) and cumulativeCountBeforePull(preset, h.pullIndex) or 0
        local pct = (total > 0) and ((cum / total) * 100) or 0
        table.insert(state.targets, {
          kind              = "pull",
          pullIndex         = h.pullIndex,
          targetPct         = pct,
          name              = h.name,             -- e.g. "Glacieth" or nil for "pull N"
          fired             = false,
          fireOnFirstCombat = pct < 3,
        })
      elseif h.kind == "boss" then
        table.insert(state.targets, {
          kind        = "boss",
          encounterID = h.encounterID,
          name        = h.name,
          fired       = false,
        })
      end
    end

    local count = #state.targets
    local summary = {}
    for _, t in ipairs(state.targets) do
      if t.kind == "pull" then
        table.insert(summary,
          (t.name and (t.name .. " ") or "") ..
          string.format("pull %d (%.0f%%)", t.pullIndex, t.targetPct or 0))
      else
        table.insert(summary,
          (t.name or "boss") .. " (encID " .. tostring(t.encounterID) .. ")")
      end
    end
    debug(string.format("MDT lust note (%s) parsed %d targets — note: %q",
      tostring(mdt.noteSource), count, tostring(mdt.note)))
    local preFix = state.presetName
      and string.format(" using route '%s'", state.presetName) or ""
    if count > 0 then
      print(string.format(
        "|cffff8800ZugZug Keys:|r %d lust target%s loaded%s — %s.",
        count, count == 1 and "" or "s", preFix, table.concat(summary, ", ")))
    else
      print("|cffff8800ZugZug Keys:|r found lust note but couldn't extract any pull/boss reference"
        .. preFix .. ". Note: " .. tostring(mdt.note))
    end
    return
  end

  -- Fallback to curated.
  local curated = mapID and findCuratedFallback(mapID)
  if curated then
    state.source    = "curated"
    state.routeNote = curated.note or curated.name
    for _, encID in ipairs(curated.encounterIDs) do
      table.insert(state.targets, {
        kind        = "boss",
        encounterID = encID,
        fired       = false,
      })
    end
    debug("Curated lust fallback in use for mapID " .. tostring(mapID))
    print(string.format(
      "|cffff8800ZugZug Keys:|r curated lust target%s loaded — alerts on %d boss engage%s.",
      #state.targets == 1 and "" or "s",
      #state.targets,
      #state.targets == 1 and "" or "s"))
    return
  end

  -- Neither available: stay quiet but log so /zzk debug users can see.
  state.source = nil
  debug("No lust target available (no MDT marker, no curated entry for mapID "
    .. tostring(mapID) .. ").")
end

----------------------------------------------------------------------
-- Event wiring
----------------------------------------------------------------------

local function tickForcesCheck(triggerSource)
  if not state.active then return end
  state.forcesCheckCount = (state.forcesCheckCount or 0) + 1
  local pct
  local ok, err = pcall(function() pct = getEnemyForcesPct() end)
  if not ok then
    state.lastForcesErr = "pcall error: " .. tostring(err)
    return
  end
  if pct == nil then
    state.lastForcesErr = "getEnemyForcesPct returned nil (no weighted-progress criterion?)"
    return
  end
  -- Final secret-value guard. getEnemyForcesPct already filters Secrets
  -- internally but if a future patch sneaks a Secret through and pct is
  -- itself secret, the `>=` comparison below would crash.
  if isSecret(pct) or type(pct) ~= "number" then
    state.lastForcesErr = "getEnemyForcesPct returned a non-number ("
      .. type(pct) .. ", isSecret=" .. tostring(isSecret(pct)) .. ")"
    return
  end
  state.lastForcesPct = pct
  state.lastForcesAt  = GetTime()
  state.lastForcesErr = nil
  local lead = ZugZugKeysDB.lustReminderLeadPct or 3
  for _, t in ipairs(state.targets) do
    if not t.fired
        and t.kind == "pull"
        and not t.fireOnFirstCombat
        and t.targetPct
        and pct >= (t.targetPct - lead) then
      fireAlert(t, string.format("forces %.0f%% (target %.0f%%)",
        pct, t.targetPct))
    end
  end
end

--- Forgiving boss-name comparison. Returns true if:
---   * exact case-insensitive match, OR
---   * one name is a substring of the other AND the shorter name is
---     >= 5 chars (catches "Tyrannus" inside "Scourgelord Tyrannus" or
---     "Garfrost" inside "Forgemaster Garfrost" without matching short
---     common words like "the" or "lord").
--- MDT and Blizzard sometimes disagree on title prefixes — MDT stores
--- the full creature name while ENCOUNTER_START often fires the short
--- form, so an exact-equality check missed legitimate matches.
local function bossNamesMatch(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then return false end
  a, b = a:lower(), b:lower()
  if a == b then return true end
  if #a >= 5 and b:find(a, 1, true) then return true end
  if #b >= 5 and a:find(b, 1, true) then return true end
  return false
end

--- Match a boss target against the live ENCOUNTER_START payload.
--- Strategy (in order):
---   (1) Forgiving name match (substring + min length). Most reliable
---       because the event gives us the real boss name and MDT stores
---       accurate names.
---   (2) encounterID match. Only matters when we somehow have a real
---       per-boss encID (rare in 12.0 — MDT/EJ both return the journal
---       instance ID for every boss).
local function onEncounterStart(encounterID, encounterName)
  if not state.active then return end
  -- Diagnostic line: one print per boss engage during an active key,
  -- so we can see exactly what fired and what targets were considered.
  -- Quiet, useful, only fires when state.active so it stays out of the
  -- way outside keys.
  local pending = {}
  for _, t in ipairs(state.targets) do
    if not t.fired and t.kind == "boss" then
      table.insert(pending, tostring(t.name or ("encID " .. tostring(t.encounterID))))
    end
  end
  print(string.format(
    "|cffff8800ZZK boss engage:|r %q (encID %s)  pending: %s",
    tostring(encounterName), tostring(encounterID),
    (#pending > 0) and table.concat(pending, ", ") or "(none)"))

  for _, t in ipairs(state.targets) do
    if not t.fired and t.kind == "boss" then
      local matched = bossNamesMatch(t.name, encounterName)
        or (t.encounterID and t.encounterID == encounterID)
      if matched then
        fireAlert(t, "boss engaged" ..
          (encounterName and (" (" .. encounterName .. ")") or ""))
        return
      end
    end
  end
end

local function onRegenDisabled()
  if not state.active or state.firstCombatHandled then return end
  state.firstCombatHandled = true
  for _, t in ipairs(state.targets) do
    if not t.fired and t.kind == "pull" and t.fireOnFirstCombat then
      fireAlert(t, "first pull engaged")
      return
    end
  end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHALLENGE_MODE_START")
frame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
frame:RegisterEvent("CHALLENGE_MODE_RESET")
frame:RegisterEvent("SCENARIO_CRITERIA_UPDATE")
frame:RegisterEvent("ENCOUNTER_START")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:SetScript("OnEvent", function(_, event, arg1, arg2, ...)
  if event == "CHALLENGE_MODE_START" then
    resetState()
    -- Slight delay so MDT has a chance to react to the dungeon zone in
    -- and update its current sublevel if it auto-selects per-dungeon.
    C_Timer.After(0.5, function()
      loadTargetForCurrentKey()
      -- Safety net: SCENARIO_CRITERIA_UPDATE is the right event for forces
      -- updates, but in some 12.0 scenarios it can be sparse. A 1-second
      -- backup poll guarantees we still see %-changes within ~1s.
      if state.active and not backupTicker then
        backupTicker = C_Timer.NewTicker(1.0, function()
          tickForcesCheck("ticker")
        end)
      end
    end)
    return
  end
  if event == "CHALLENGE_MODE_COMPLETED" or event == "CHALLENGE_MODE_RESET" then
    -- Preserve targets + diagnostics so a post-key `/zzk lust` still shows
    -- what fired (and what didn't). Cleared on the next CHALLENGE_MODE_START.
    deactivate()
    return
  end
  if event == "PLAYER_ENTERING_WORLD" then
    local inInst, instType = IsInInstance()
    if not (inInst and instType == "party") then
      -- Same as above — just deactivate, keep diagnostics for inspection.
      deactivate()
    end
    return
  end
  if event == "SCENARIO_CRITERIA_UPDATE" then
    state.scenarioUpdateCount = (state.scenarioUpdateCount or 0) + 1
    tickForcesCheck("SCENARIO_CRITERIA_UPDATE")
    return
  end
  if event == "ENCOUNTER_START" then
    -- ENCOUNTER_START fires with (encounterID, encounterName, difficultyID, groupSize).
    -- Pass both because MDT stores the journal instance ID in its
    -- per-boss encounterID field for every boss in a dungeon (e.g. 2658
    -- for every NPX boss), so encID matching alone is unreliable. The
    -- handler prefers a name match, then falls back to encID.
    onEncounterStart(arg1, arg2)
    return
  end
  if event == "PLAYER_REGEN_DISABLED" then
    onRegenDisabled()
    return
  end
end)

----------------------------------------------------------------------
-- Simulation command: /zzk lustsim [dungeonIdx]
--
-- Runs the full lust-target extraction pipeline against any MDT dungeon
-- preset, without requiring an active key. With no argument it walks
-- every MDT dungeon with a preset and prints a summary line per
-- dungeon ("✓ lust found" / "✗ no lust note"). With a numeric argument
-- it prints the full per-target dump for that specific dungeon.
--
-- Tests covered:
--   * mdtGetDB() resolution
--   * preset lookup for an explicit dungeonIdx (no challenge mode check)
--   * findLustNoteText() — does the parser find a lust note?
--   * extractTargetsFromNote() — what targets does it extract?
--   * isLustNote() per-pull fallback
--   * Encounter Journal boss-order resolution for ordinal references
--   * Curated fallback data (when present)
----------------------------------------------------------------------

--- Project the same per-hit metadata loadTargetForCurrentKey computes
--- (targetPct, fireOnFirstCombat) so the simulation shows the same
--- target state the real run would set up.
local function projectHit(h, preset, total)
  if h.kind == "pull" then
    local cum = (total > 0) and cumulativeCountBeforePull(preset, h.pullIndex) or 0
    local pct = (total > 0) and ((cum / total) * 100) or 0
    return {
      kind              = "pull",
      pullIndex         = h.pullIndex,
      name              = h.name,
      matchedBy         = h.matchedBy,
      targetPct         = pct,
      fireOnFirstCombat = pct < 3,
    }
  elseif h.kind == "boss" then
    return {
      kind        = "boss",
      encounterID = h.encounterID,
      name        = h.name,
      matchedBy   = h.matchedBy,
    }
  end
  return h
end

local function dumpHitList(label, hits, preset, total)
  print(string.format("  %s (%d hits):", label, #hits))
  for i, raw in ipairs(hits) do
    local h = projectHit(raw, preset, total)
    if h.kind == "pull" then
      local prefix = h.fireOnFirstCombat and "[first-combat]" or "[forces]"
      local pctStr = h.targetPct
        and string.format("%.1f%%", h.targetPct)
        or "nil"
      local nameStr = h.name and (" name=" .. h.name) or ""
      print(string.format("    %d. %s pull=%d  targetPct=%s  matchedBy=%s%s",
        i, prefix, h.pullIndex, pctStr,
        tostring(h.matchedBy or "?"), nameStr))
    elseif h.kind == "boss" then
      print(string.format("    %d. [boss] encID=%s  name=%q  matchedBy=%s",
        i, tostring(h.encounterID), tostring(h.name or "?"),
        tostring(h.matchedBy or "?")))
    else
      print(string.format("    %d. [%s] %s", i, tostring(h.kind), tostring(h)))
    end
  end
end

local function lustsimOne(dungeonIdx)
  if not _G.MDT then print("  MDT not loaded") return end
  local idx = tonumber(dungeonIdx)
  if not idx then print("  bad dungeon idx: " .. tostring(dungeonIdx)) return end

  local dungeonName = (MDT.dungeonList and MDT.dungeonList[idx]) or "(unknown)"
  print(string.format("|cffff8800ZZK lustsim:|r dungeonIdx=%d  name=%s",
    idx, tostring(dungeonName)))

  local preset, presetIdx = getPresetForDungeonIdx(idx)
  if not preset then
    print("  ✗ no MDT preset for this dungeon. Open MDT, switch to it,")
    print("    and import a route, then try again.")
    return
  end
  print(string.format("  preset[%d] = %q  (has .value=%s, has .objects=%s)",
    presetIdx, tostring(preset.text),
    tostring(type(preset.value) == "table"),
    tostring(type(preset.objects) == "table")))

  -- Forces total + dungeon meta
  local total = totalForces(preset) or 0
  print(string.format("  totalForces = %d", total))

  -- Encounter Journal preview (for ordinal "first/last boss" support)
  local bo = getDungeonBossOrder(preset)
  if #bo > 0 then
    print("  boss order (" .. #bo .. "):")
    for i, b in ipairs(bo) do
      print(string.format("    %d. %s (encID %s)",
        i, tostring(b.name), tostring(b.encounterID)))
    end
  else
    print("  boss order: (none — EJ not ready or MDT enemies missing isBoss)")
  end

  -- Raw MDT.dungeonEnemies boss entries so we can see every field MDT
  -- exposes for each boss. If encounterID is duplicated, we need a
  -- different field to distinguish them.
  if _G.MDT and MDT.dungeonEnemies and MDT.dungeonEnemies[idx] then
    print("  raw MDT boss entries (every isBoss=true entry, every field):")
    for slot, e in pairs(MDT.dungeonEnemies[idx]) do
      if type(e) == "table" and e.isBoss then
        local fields = {}
        for k, v in pairs(e) do
          local kind = type(v)
          if kind == "string" or kind == "number" or kind == "boolean" then
            table.insert(fields, string.format("%s=%s", tostring(k), tostring(v)))
          elseif kind == "table" then
            local n = 0
            for _ in pairs(v) do n = n + 1 end
            table.insert(fields, string.format("%s=table(%d)", tostring(k), n))
          end
        end
        table.sort(fields)
        print(string.format("    slot=%s  %s", tostring(slot), table.concat(fields, "  ")))
      end
    end
  end

  -- Pure parse via findLustTargetFromPreset
  local target = findLustTargetFromPreset(preset)
  if not target then
    print("  ✗ no lust target extracted from this preset.")
    print("    Check that the preset has a Tactyks-style note containing")
    print("    'lust' / 'bloodlust' / 'heroism' / 'BL' / 'hero' / 'drums'")
    print("    and at least one parseable ref ('pull N', 'first boss',")
    print("    enemy name, etc.).")
    -- Curated fallback preview
    if _G.ZugZugKeysLustData then
      local mapID = mdtMapIDForDungeon(idx)
      if mapID and ZugZugKeysLustData[mapID] then
        local entry = ZugZugKeysLustData[mapID]
        print(string.format("  curated fallback: encounterIDs=%s  name=%q  note=%q",
          tostring(#(entry.encounterIDs or {})), tostring(entry.name),
          tostring(entry.note)))
      end
    end
    return
  end

  print(string.format("  ✓ lust target found — source=%s noteSource=%s totalCount=%d",
    tostring(target.source), tostring(target.noteSource), target.totalCount or 0))
  print(string.format("  note: %q", tostring(target.note)))
  dumpHitList("hits", target.hits, preset, total)
end

--- Should an entry appear in the lustsim summary? We skip dungeons MDT
--- doesn't have a real name for — those are stale/legacy slots in MDT's
--- catalog that aren't actually in the current season, and listing 200+
--- "(unknown)" rows just buries the useful output.
---
--- A dungeon counts as "shown" if it has either:
---   * a non-empty MDT.dungeonList[idx] string longer than 1 char, OR
---   * a successful lust target extracted (always interesting), OR
---   * a lust note that we couldn't parse (always interesting — surface
---     it so we can improve the parser for that case)
local function shouldShowInSummary(idx, name, target, noteText)
  if target then return true end
  if noteText and noteText ~= "" then return true end
  if type(name) == "string" and #name > 1 and name ~= "(unknown)" then
    return true
  end
  return false
end

local function lustsimAll()
  if not _G.MDT then print("  MDT not loaded") return end
  local db = mdtGetDB()
  if not (db and type(db.presets) == "table") then
    print("  MDT.presets unavailable")
    return
  end
  print("|cffff8800ZZK lustsim — dungeons with presets:|r")
  local indices = {}
  for idx in pairs(db.presets) do
    if type(idx) == "number" then table.insert(indices, idx) end
  end
  table.sort(indices)

  local shown, found, unparseable, hidden = 0, 0, 0, 0
  for _, idx in ipairs(indices) do
    local preset = getPresetForDungeonIdx(idx)
    local name = (MDT.dungeonList and MDT.dungeonList[idx]) or "(unknown)"
    local target = preset and findLustTargetFromPreset(preset) or nil
    local noteText = preset and not target and findLustNoteText(preset) or nil

    if shouldShowInSummary(idx, name, target, noteText) then
      shown = shown + 1
      if not preset then
        print(string.format("  [%d] %s  preset missing", idx, tostring(name)))
      elseif target then
        found = found + 1
        print(string.format("  [%d] %s  ✓ %d hits  (noteSource=%s)",
          idx, tostring(name), #(target.hits or {}),
          tostring(target.noteSource)))
      else
        if noteText then unparseable = unparseable + 1 end
        print(string.format("  [%d] %s  ✗ no targets%s",
          idx, tostring(name),
          noteText and "  (note found but unparseable: '" ..
            (noteText:gsub("[\r\n]+", " "):sub(1, 60)) .. "…')" or ""))
      end
    else
      hidden = hidden + 1
    end
  end
  print(string.format(
    "  Summary: shown=%d  ✓ parsed=%d  ✗ unparseable notes=%d  hidden (stale MDT entries)=%d",
    shown, found, unparseable, hidden))
  print("Use /zzk lustsim <dungeonIdx> for a full per-dungeon dump.")
end

function Keys.LustReminderSim(arg)
  -- Always also print the API availability check, so we can confirm the
  -- forces-detection path is wired correctly even when we're not in a key.
  print(string.format(
    "|cffff8800ZZK API check:|r C_Scenario.GetStepInfo=%s  C_ScenarioInfo.GetCriteriaInfo=%s",
    tostring(_G.C_Scenario and type(C_Scenario.GetStepInfo) or "nil"),
    tostring(_G.C_ScenarioInfo and type(C_ScenarioInfo.GetCriteriaInfo) or "nil")))
  local idx = tonumber(arg)
  if idx then
    lustsimOne(idx)
  else
    lustsimAll()
  end
end
