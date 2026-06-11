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

local function isLustNote(text)
  if type(text) ~= "string" or text == "" then return false end
  local lower = text:lower()
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

--- Modern MDT (12.0+) accesses its DB via MDT:GetDB(), not MDT.db. The
--- saved-variable backing store is `MythicDungeonToolsDB.global` per the
--- Ace3 profile model, with presets at `db.presets[dungeonIdx]`.
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
local function getCurrentPreset()
  if not _G.MDT then return nil end

  -- (1) Detect the dungeon via any available signal.
  -- (Diagnostic note: detectCurrentDungeonIdx() is also called directly
  -- from /zzk lust for its source-of-lookup display — no need to cache
  -- the result here, where state hasn't been declared yet.)
  local dungeonIdx = detectCurrentDungeonIdx()
  if dungeonIdx then
    local db = mdtGetDB()
    if db and type(db.presets) == "table" then
      local presets = db.presets[dungeonIdx]
      if type(presets) == "table" then
        local presetIdx = (type(db.currentPreset) == "table"
                            and db.currentPreset[dungeonIdx])
                          or 1
        local preset = presets[presetIdx]
        if type(preset) == "table" then return preset end
      end
    end
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
---   (1) Encounter Journal (most authoritative, but needs an EJ instance
---       context — works during the active key via EJ_GetCurrentInstance)
---   (2) MDT.dungeonEnemies filtered to isBoss, sorted by NPC slot
---       (works in dry-run too, but slot order is a convention not a guarantee)
local function getDungeonBossOrder(preset)
  -- (1) Encounter Journal
  if EJ_GetCurrentInstance and EJ_GetEncounterInfoByIndex then
    local ok, jInstanceID = pcall(EJ_GetCurrentInstance)
    if ok and type(jInstanceID) == "number" and jInstanceID > 0 then
      if EJ_SelectInstance then pcall(EJ_SelectInstance, jInstanceID) end
      local out = {}
      for i = 1, 20 do
        local name, _, journalEncounterID, _, _, _, dungeonEncounterID =
          EJ_GetEncounterInfoByIndex(i)
        if not name then break end
        table.insert(out, {
          name = name,
          encounterID = dungeonEncounterID or journalEncounterID,
        })
      end
      if #out > 0 then return out end
    end
  end
  -- (2) Fallback: MDT enemy data, filter to bosses, sort by slot
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
      table.sort(indexed, function(a, b) return a.slot < b.slot end)
      local out = {}
      for _, b in ipairs(indexed) do
        table.insert(out, { name = b.name, encounterID = b.encounterID })
      end
      return out
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
        table.insert(hits, { pos = s, kind = "pull", pullIndex = num })
      end
      start = e + 1
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
            matchVia = "ordinal:" .. word .. " boss",
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
            matchVia = "ordinal:boss " .. idx,
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
                encounterID = e.encounterID, name = e.name, matchVia = via,
              })
            else
              local pullIdx = findPullContainingSlot(preset, slot)
              if pullIdx then
                table.insert(hits, {
                  pos = pos or 1, kind = "pull",
                  pullIndex = pullIdx, name = e.name, matchVia = via,
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

  -- (3) Deduplicate by (kind + key).
  local out, seen = {}, {}
  for _, h in ipairs(hits) do
    local key = (h.kind == "pull") and ("p" .. h.pullIndex)
                                    or  ("b" .. tostring(h.encounterID))
    if not seen[key] then
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
local function findLustTargetFromMDT()
  local preset = getCurrentPreset()
  if not preset or not preset.value or type(preset.value.pulls) ~= "table" then
    return nil
  end
  -- Forces total is best-effort — if it's 0, we still continue and parse
  -- the note. Pull-based targets without a known total fire on first
  -- combat instead of via forces % (handled in loadTargetForCurrentKey).
  -- Boss-name targets don't need a total at all.
  local total = totalForces(preset) or 0

  ----------------------------------------------------------------
  -- Strategy 1: Tactyks-style — single global note with multiple refs
  ----------------------------------------------------------------
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
    -- Found a lust note but no extractable target — fall through to
    -- per-pull scan so we can still try.
  end

  ----------------------------------------------------------------
  -- Strategy 2: per-pull notes
  ----------------------------------------------------------------
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
  -- Widget auto-discovery via UPDATE_UI_WIDGET. Populated as widgets
  -- update during the key; we use it to find the forces widget without
  -- having to guess which set it lives in.
  seenWidgets         = {},  -- [widgetID] = { type, text, barValue, barMax, tooltip, hits }
  forcesWidgetID      = nil, -- locked once we identify the forces widget
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
  state.seenWidgets = {}
  state.forcesWidgetID = nil
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

--- Capture the scenario step + every criterion into a plain Lua snapshot
--- so we can inspect what M+ is actually exposing without needing to be
--- in-key when the diagnostic command runs.
local function snapshotScenario()
  if not _G.C_ScenarioInfo then return nil, "C_ScenarioInfo namespace nil" end
  if not C_ScenarioInfo.GetStepInfo then return nil, "C_ScenarioInfo.GetStepInfo nil" end
  if not C_ScenarioInfo.GetCriteriaInfo then return nil, "C_ScenarioInfo.GetCriteriaInfo nil" end
  local ok, step = pcall(C_ScenarioInfo.GetStepInfo)
  if not ok then return nil, "GetStepInfo errored: " .. tostring(step) end
  if type(step) ~= "table" then
    return nil, "GetStepInfo returned " .. type(step) .. " (no active scenario)"
  end

  local snap = {
    numCriteria  = step.numCriteria,
    isInProgress = step.isInProgress,
    criteria     = {},
  }
  local count = step.numCriteria or 5
  for i = 1, count do
    local ok2, crit = pcall(C_ScenarioInfo.GetCriteriaInfo, i)
    if not ok2 then
      snap.criteria[i] = { error = tostring(crit) }
    elseif type(crit) ~= "table" then
      snap.criteria[i] = { otherType = type(crit) }
    else
      snap.criteria[i] = {
        quantity           = crit.quantity,
        totalQuantity      = crit.totalQuantity,
        isWeightedProgress = crit.isWeightedProgress,
        description        = crit.description,
        quantityString     = crit.quantityString,
        isFormatted        = crit.isFormatted,
        completed          = crit.completed,
      }
    end
  end
  return snap
end

-- Widget sets that may contain the M+ forces display. 252 is
-- SCENARIO_TRACKER_WIDGET_SET (per KalielsTracker). We scan a wide-ish
-- range so we catch the right one even if Blizzard moves it.
local FORCES_WIDGET_SET_IDS = {
  252, 253, 254, 255, 256, 257, 258, 259, 260,
  261, 262, 263, 264, 265, 266, 267, 268, 269, 270,
  279, 282, 290,
}

--- Try to extract a forces-style percentage from arbitrary text. M+
--- renders the forces text as "1234 / 5678" or "23.4%" or "23%". We try
--- both shapes. Returns the percentage 0..100 or nil.
local function parseForcesText(text)
  if type(text) ~= "string" or text == "" then return nil end
  local num, denom = text:match("(%d+)%s*/%s*(%d+)")
  if num and denom then
    local n, d = tonumber(num), tonumber(denom)
    if n and d and d > 50 then return (n / d) * 100 end
  end
  local pct = text:match("([%d%.]+)%s*%%")
  if pct then
    local p = tonumber(pct)
    if p and p >= 0 and p <= 100 then return p end
  end
  return nil
end

--- Read the value of a single widget by ID + type. Returns the pct value
--- if it's a forces-shaped widget, plus a record of what we saw (for the
--- seenWidgets table).
local function readWidgetByID(widgetID, widgetType)
  if not widgetID then return nil end
  local record = { type = widgetType }
  if widgetType == 2 and C_UIWidgetManager.GetStatusBarWidgetVisualizationInfo then
    local ok, info = pcall(C_UIWidgetManager.GetStatusBarWidgetVisualizationInfo, widgetID)
    if ok and type(info) == "table" then
      record.barValue = info.barValue
      record.barMax   = info.barMax
      record.tooltip  = info.tooltip
      local bv = tonumber(info.barValue)
      local bx = tonumber(info.barMax)
      if bv and bx and bx > 50 then
        return (bv / bx) * 100, record
      end
    end
  elseif widgetType == 8 and C_UIWidgetManager.GetTextWithStateWidgetVisualizationInfo then
    local ok, info = pcall(C_UIWidgetManager.GetTextWithStateWidgetVisualizationInfo, widgetID)
    if ok and type(info) == "table" then
      record.text    = info.text
      record.tooltip = info.tooltip
      local pct = parseForcesText(info.text)
      if pct then return pct, record end
    end
  end
  return nil, record
end

--- Should we accept this widget as the forces widget? Tightened so we
--- don't false-lock onto random progress bars (cooking events, etc.):
---   * pct must be < 95 (real M+ forces starts at 0; if a widget is at
---     100% on our first sight, it's almost certainly not the forces bar)
---   * if tooltip is non-empty, it must look forces-related — anything
---     that mentions "cauldron"/"ingredient"/"meal"/"cooking" is rejected
local function widgetLooksLikeForces(pct, record)
  if type(pct) ~= "number" or pct < 0 or pct >= 95 then return false end
  if type(record) ~= "table" then return false end
  local tip = (type(record.tooltip) == "string") and record.tooltip:lower() or ""
  if tip ~= "" then
    for _, bad in ipairs({ "cauldron", "ingredient", "meal", "cooking",
                          "stoup", "feast", "fishing", "anglers", "angler" }) do
      if tip:find(bad, 1, true) then return false end
    end
  end
  return true
end

--- Called from UPDATE_UI_WIDGET. Records the widget into seenWidgets,
--- and if its value matches the forces shape AND passes the tighter
--- checks above, locks the widget ID for future ticks.
local function onWidgetUpdate(tbl)
  if not state.active or type(tbl) ~= "table" then return end
  local id  = tbl.widgetID
  local typ = tbl.widgetType
  if not id then return end
  local pct, record = readWidgetByID(id, typ)
  if not record then return end
  record.hits = (state.seenWidgets[id] and state.seenWidgets[id].hits or 0) + 1
  state.seenWidgets[id] = record
  if not state.forcesWidgetID and widgetLooksLikeForces(pct, record) then
    state.forcesWidgetID = id
  end
end

--- Scan widget sets for the M+ enemy forces. Strategy:
---   (a) If UPDATE_UI_WIDGET previously identified a forces widget, read
---       that one directly.
---   (b) Walk every widget the event has seen, parse for the forces shape.
---   (c) Fall back to scanning candidate widget sets.
local function readForcesFromWidgets()
  if not _G.C_UIWidgetManager then return nil end

  -- (a) Locked widget — fastest path.
  if state.forcesWidgetID then
    local rec = state.seenWidgets[state.forcesWidgetID]
    local pct, newRec = readWidgetByID(state.forcesWidgetID, rec and rec.type)
    if pct and newRec then
      newRec.hits = (rec and rec.hits or 0) + 1
      state.seenWidgets[state.forcesWidgetID] = newRec
      state.lastForcesSource = "locked widget id=" .. state.forcesWidgetID
      return pct
    end
  end

  -- (b) Walk every UPDATE_UI_WIDGET-discovered widget. Only commit to a
  -- widget that passes the "looks like forces" check.
  for id, rec in pairs(state.seenWidgets) do
    local pct, newRec = readWidgetByID(id, rec.type)
    if pct and newRec and widgetLooksLikeForces(pct, newRec) then
      newRec.hits = (rec.hits or 0) + 1
      state.seenWidgets[id] = newRec
      state.forcesWidgetID = id
      state.lastForcesSource = "discovered widget id=" .. id
      return pct
    end
  end

  -- (c) Fall back to scanning candidate sets.
  if not C_UIWidgetManager.GetAllWidgetsBySetID then return nil end
  for _, setID in ipairs(FORCES_WIDGET_SET_IDS) do
    local ok, widgets = pcall(C_UIWidgetManager.GetAllWidgetsBySetID, setID)
    if ok and type(widgets) == "table" then
      -- Pass 1: StatusBar widgets
      -- Both widget types — accept whichever passes widgetLooksLikeForces.
      for _, w in ipairs(widgets) do
        if w and w.widgetID then
          local pct, record = readWidgetByID(w.widgetID, w.widgetType)
          if pct and record and widgetLooksLikeForces(pct, record) then
            state.lastForcesSource = string.format(
              "widget set=%d id=%d", setID, w.widgetID)
            state.forcesWidgetID = w.widgetID
            state.seenWidgets[w.widgetID] = record
            return pct
          end
        end
      end
    end
  end
  return nil
end

--- Returns the current enemy forces percentage (0..100), or nil. Three
--- strategies in order, narrowest to widest:
---   (1) UI widget StatusBar in the scenario widget sets (12.0 path — this
---       is where Blizzard moved the bar from criteria)
---   (2) Legacy `C_Scenario.GetStepInfo()` position 10 — kept as safety net
---       for non-M+ weighted scenarios
---   (3) New-style criteria iteration via `C_ScenarioInfo.GetCriteriaInfo`
---       — only fires for criteria flagged weightedProgress or matching
---       description/qString heuristics. M+ never reaches here.
local function getEnemyForcesPct()
  -- Always snapshot the new-style criteria for /zzk lust diagnostics.
  local snap, err = snapshotScenario()
  state.criteriaSnapshot    = snap
  state.criteriaSnapshotErr = err
  state.criteriaSnapshotAt  = GetTime()

  -- Primary: UI Widget Manager (the 12.0 path for M+).
  local widgetPct = readForcesFromWidgets()
  if widgetPct then
    state.lastStepPct = widgetPct
    return widgetPct
  end

  -- Fallback: legacy step-info (works for some non-M+ scenarios).
  if _G.C_Scenario and C_Scenario.GetStepInfo then
    local ok, p = pcall(function() return select(10, C_Scenario.GetStepInfo()) end)
    if ok and type(p) == "number" and p > 0 then
      state.lastStepPct = p
      return p
    end
  end

  -- Fallback: criteria walk (other scenario types).
  if snap then
    for _, c in ipairs(snap.criteria) do
      if type(c) == "table" and not c.error and not c.otherType then
        local q  = tonumber(c.quantity) or 0
        local tq = tonumber(c.totalQuantity) or 0
        if tq > 0 then
          if c.isWeightedProgress then return (q / tq) * 100 end
          local desc = (type(c.description) == "string") and c.description:lower() or ""
          if desc:find("force", 1, true) then return (q / tq) * 100 end
          local qStr = (type(c.quantityString) == "string") and c.quantityString or ""
          if qStr:find("%%", 1, true) then return (q / tq) * 100 end
        end
      end
    end
  end
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
      fireAlert(t, string.format("forces %.0f%% (target %.0f%%, via %s)",
        pct, t.targetPct, tostring(triggerSource or "?")))
    end
  end
end

local function onEncounterStart(encounterID)
  if not state.active then return end
  for _, t in ipairs(state.targets) do
    if not t.fired and t.kind == "boss" and t.encounterID == encounterID then
      fireAlert(t, "boss engaged")
      return
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
frame:RegisterEvent("UPDATE_UI_WIDGET")
frame:SetScript("OnEvent", function(_, event, arg1)
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
    onEncounterStart(arg1)
    return
  end
  if event == "PLAYER_REGEN_DISABLED" then
    onRegenDisabled()
    return
  end
  if event == "UPDATE_UI_WIDGET" then
    onWidgetUpdate(arg1)
    return
  end
end)

----------------------------------------------------------------------
-- Exposed for /zzk slash subcommands
----------------------------------------------------------------------

function Keys.LustReminderStatus()
  local _, classToken = UnitClass("player")
  print("|cffff8800ZugZug Keys (lust):|r")
  print("  enabled = " .. tostring(ZugZugKeysDB.lustReminder)
    .. "  class = " .. tostring(classToken)
    .. "  canPlayerLust = " .. tostring(canPlayerLust()))
  if not canPlayerLust() then
    print("  |cffffaa00(reminder is suppressed in-key — your class doesn't bring a lust spell. /zzk lusttest still previews.)|r")
  end
  print("  state.active = " .. tostring(state.active)
    .. "  firstCombatHandled = " .. tostring(state.firstCombatHandled))
  print("  source = " .. tostring(state.source) .. "  noteSource = " .. tostring(state.noteSource))
  if state.presetName then
    print("  preset: '" .. tostring(state.presetName) .. "'")
  end
  if state.routeNote then
    print("  note: " .. tostring(state.routeNote))
  end
  -- Full detection chain so we can see exactly which signal MDT matched.
  do
    local okC, cMapID = pcall(C_ChallengeMode.GetActiveChallengeMapID)
    local okM, uiMapID = pcall(C_Map.GetBestMapForUnit, "player")
    local _, instType, _, _, _, _, _, instanceID = GetInstanceInfo()
    print(string.format("  active key mapID=%s, player UIMapID=%s, instance(%s)=%s",
      tostring(okC and cMapID or "?"),
      tostring(okM and uiMapID or "?"),
      tostring(instType), tostring(instanceID)))
    local dungeonIdx, source = detectCurrentDungeonIdx()
    print("  detectCurrentDungeonIdx() = " .. tostring(dungeonIdx)
      .. "  source: " .. tostring(source))
    print("  MDT.zoneIdToDungeonIdx exists: "
      .. tostring(_G.MDT and type(MDT.zoneIdToDungeonIdx) == "table"))
    local db = mdtGetDB()
    if dungeonIdx and db and type(db.presets) == "table"
        and type(db.presets[dungeonIdx]) == "table" then
      local presets = db.presets[dungeonIdx]
      local presetIdx = (type(db.currentPreset) == "table"
                          and db.currentPreset[dungeonIdx]) or 1
      local preset = presets[presetIdx]
      print(string.format("  → preset[%d]=%q  (out of %d for this dungeon)",
        presetIdx, tostring(preset and preset.text or "?"), #presets))
    elseif dungeonIdx then
      local dungName = _G.MDT and MDT.dungeonList and MDT.dungeonList[dungeonIdx]
                      or "(unknown)"
      print(string.format("  → MDT has no presets[%d] entry — open MDT, switch to %s, import a route",
        dungeonIdx, tostring(dungName)))
    end
  end
  -- Boss order for the currently-resolved dungeon, so we can verify
  -- ordinal references ("first boss" / "last boss") would resolve.
  local previewPreset = getCurrentPreset()
  if previewPreset then
    local bo = getDungeonBossOrder(previewPreset)
    if #bo > 0 then
      print("  boss order (" .. #bo .. "):")
      for i, b in ipairs(bo) do
        print(string.format("    %d. %s (encID %s)", i, tostring(b.name), tostring(b.encounterID)))
      end
    else
      print("  boss order: (none — EJ unavailable and MDT enemy data has no isBoss entries)")
    end
  end
  print("  targets (" .. tostring(#state.targets) .. "):")
  for i, t in ipairs(state.targets) do
    if t.kind == "pull" then
      local label = t.name and (t.name .. " (pull " .. t.pullIndex .. ")")
                            or ("pull " .. tostring(t.pullIndex))
      print(string.format("    [%d] %s @ %.1f%% — fired=%s%s",
        i, label, t.targetPct or 0, tostring(t.fired),
        t.fireOnFirstCombat and " (waits for combat)" or ""))
    else
      local label = t.name and (t.name .. " (encID " .. tostring(t.encounterID) .. ")")
                            or ("boss encID=" .. tostring(t.encounterID))
      print(string.format("    [%d] %s — fired=%s", i, label, tostring(t.fired)))
    end
  end
  print("  MDT loaded = " .. tostring(_G.MDT ~= nil))
  -- Live forces lookup (right now, this very call)
  local liveOk, livePct = pcall(getEnemyForcesPct)
  local liveStr
  if not liveOk then
    liveStr = "|cffff6666pcall error: " .. tostring(livePct) .. "|r"
  elseif livePct == nil then
    liveStr = "nil (no active scenario / no weighted-progress criterion)"
  else
    liveStr = string.format("%.2f", livePct)
  end
  print("  current forces % (live call) = " .. liveStr)
  -- In-key diagnostics
  print("  diagnostics:")
  print(string.format("    SCENARIO_CRITERIA_UPDATE fired: %d times",
    state.scenarioUpdateCount or 0))
  print(string.format("    tickForcesCheck calls: %d", state.forcesCheckCount or 0))
  print(string.format("    last forces %% seen: %s%s",
    state.lastForcesPct and string.format("%.2f", state.lastForcesPct) or "nil",
    state.lastForcesAt and string.format(" (%.1fs ago)", GetTime() - state.lastForcesAt) or ""))
  -- Show the legacy C_Scenario.GetStepInfo() position-10 value separately
  -- so we can tell which detection path is firing.
  if _G.C_Scenario and C_Scenario.GetStepInfo then
    local ok, p = pcall(function() return select(10, C_Scenario.GetStepInfo()) end)
    print(string.format("    C_Scenario.GetStepInfo() pos-10 (live): ok=%s value=%s (type=%s)",
      tostring(ok), tostring(p), type(p)))
  else
    print("    C_Scenario.GetStepInfo not available")
  end
  if state.lastForcesSource then
    print("    last forces source: " .. tostring(state.lastForcesSource))
  end
  -- Widgets that UPDATE_UI_WIDGET has surfaced so far. The forces widget
  -- shows up here automatically once it ticks during the key.
  local seenCount = 0
  for _ in pairs(state.seenWidgets) do seenCount = seenCount + 1 end
  if seenCount > 0 then
    print(string.format("    UPDATE_UI_WIDGET seen %d widgets, forcesWidgetID=%s:",
      seenCount, tostring(state.forcesWidgetID)))
    for id, rec in pairs(state.seenWidgets) do
      if rec.type == 8 then
        print(string.format("      [text type=8] id=%d hits=%d text=%q tooltip=%q parsed=%s",
          id, rec.hits or 0, tostring(rec.text or ""), tostring(rec.tooltip or ""),
          tostring(parseForcesText(rec.text))))
      elseif rec.type == 2 then
        print(string.format("      [bar  type=2] id=%d hits=%d val=%s/%s tooltip=%q",
          id, rec.hits or 0, tostring(rec.barValue), tostring(rec.barMax),
          tostring(rec.tooltip or "")))
      else
        print(string.format("      [type=%s] id=%d hits=%d", tostring(rec.type), id, rec.hits or 0))
      end
    end
  end
  -- Dump scenario widget sets. The M+ forces display lives here in 12.0,
  -- as a TextWithState (type 8) widget — we render the actual text so we
  -- can confirm which one is the forces and what the parsing recovered.
  if _G.C_UIWidgetManager and C_UIWidgetManager.GetAllWidgetsBySetID then
    for _, setID in ipairs(FORCES_WIDGET_SET_IDS) do
      local ok, widgets = pcall(C_UIWidgetManager.GetAllWidgetsBySetID, setID)
      if ok and type(widgets) == "table" and #widgets > 0 then
        print(string.format("    widget set %d: %d widgets", setID, #widgets))
        for _, w in ipairs(widgets) do
          if w.widgetType == 2 and C_UIWidgetManager.GetStatusBarWidgetVisualizationInfo then
            local ok2, info = pcall(C_UIWidgetManager.GetStatusBarWidgetVisualizationInfo, w.widgetID)
            if ok2 and type(info) == "table" then
              print(string.format("      [bar] id=%d barValue=%s barMax=%s tooltip=%q",
                w.widgetID, tostring(info.barValue), tostring(info.barMax),
                tostring(info.tooltip or "")))
            else
              print(string.format("      [bar] id=%s pcall=%s", tostring(w.widgetID), tostring(ok2)))
            end
          elseif w.widgetType == 8 and C_UIWidgetManager.GetTextWithStateWidgetVisualizationInfo then
            local ok2, info = pcall(C_UIWidgetManager.GetTextWithStateWidgetVisualizationInfo, w.widgetID)
            if ok2 and type(info) == "table" then
              local parsedPct = parseForcesText(info.text)
              print(string.format("      [text] id=%d text=%q tooltip=%q parsed=%s",
                w.widgetID, tostring(info.text or ""), tostring(info.tooltip or ""),
                parsedPct and string.format("%.1f%%", parsedPct) or "nil"))
            else
              print(string.format("      [text] id=%s pcall=%s", tostring(w.widgetID), tostring(ok2)))
            end
          else
            print(string.format("      [type=%s] id=%s", tostring(w.widgetType), tostring(w.widgetID)))
          end
        end
      end
    end
  end
  print(string.format("    backupTicker active: %s", tostring(backupTicker ~= nil)))
  if state.lastForcesErr then
    print("    last forces error: |cffff6666" .. tostring(state.lastForcesErr) .. "|r")
  end
  -- Persistent criteria snapshot (captured every tick during the key, so
  -- it survives across CHALLENGE_MODE_COMPLETED for post-mortem inspection).
  if state.criteriaSnapshot then
    local snap = state.criteriaSnapshot
    print(string.format("    last criteria snapshot%s: numCriteria=%s, isInProgress=%s",
      state.criteriaSnapshotAt
        and string.format(" (%.1fs ago)", GetTime() - state.criteriaSnapshotAt) or "",
      tostring(snap.numCriteria), tostring(snap.isInProgress)))
    for i, c in ipairs(snap.criteria) do
      if c.error then
        print(string.format("      crit[%d]: pcall error=%s", i, c.error))
      elseif c.otherType then
        print(string.format("      crit[%d]: returned %s (not a table)", i, c.otherType))
      else
        print(string.format(
          "      crit[%d]: q=%s/%s weighted=%s formatted=%s completed=%s",
          i, tostring(c.quantity), tostring(c.totalQuantity),
          tostring(c.isWeightedProgress), tostring(c.isFormatted),
          tostring(c.completed)))
        print(string.format("                 desc=%q  qStr=%q",
          tostring(c.description or ""), tostring(c.quantityString or "")))
      end
    end
  elseif state.criteriaSnapshotErr then
    print("    last criteria snapshot: |cffff6666" .. state.criteriaSnapshotErr .. "|r")
  else
    print("    last criteria snapshot: none captured yet")
  end

  -- Dry-run: when not in a key, try to parse whatever route is currently
  -- selected in MDT so the user can validate setup before going in.
  if not state.active and _G.MDT then
    print("  |cffaaaaaa--- dry-run parse of currently-selected MDT route ---|r")
    local preset = getCurrentPreset()
    if not preset then
      print("  dry-run: no preset returned by getCurrentPreset()")
      return
    end
    print("  dry-run: preset = " .. tostring(preset)
      .. (preset.text and ("  text=" .. tostring(preset.text)) or "")
      .. (preset.name and ("  name=" .. tostring(preset.name)) or ""))
    if not preset.value or type(preset.value.pulls) ~= "table" then
      print("  dry-run: preset has no .value.pulls — unexpected MDT shape")
      return
    end
    local total = totalForces(preset)
    print(string.format("  dry-run: dungeonIdx=%s, total forces=%s, pulls=%d, objects(top-level)=%s, objects(.value)=%s",
      tostring(getDungeonIdx(preset)),
      tostring(total),
      #preset.value.pulls,
      preset.objects and tostring(#preset.objects) or "nil",
      preset.value.objects and tostring(#preset.value.objects) or "nil"))
    -- Find note text
    local noteText = findLustNoteText(preset)
    if noteText then
      print("  dry-run: matched lust note text — " .. noteText)
      local hits = extractTargetsFromNote(noteText, preset)
      local lead = ZugZugKeysDB.lustReminderLeadPct or 3
      print("  dry-run: would set up " .. #hits .. " target(s) using a " .. lead .. "% lead:")
      if #hits == 0 then
        print("    (none — couldn't extract any pull or enemy reference)")
      end
      for i, h in ipairs(hits) do
        local viaTag = h.matchVia and ("  [match=" .. h.matchVia .. "]") or ""
        if h.kind == "pull" then
          local cum  = cumulativeCountBeforePull(preset, h.pullIndex)
          local pct  = (total > 0) and ((cum / total) * 100) or 0
          local fire = (pct < 3) and "first combat" or string.format("forces ≥ %.1f%%", pct - lead)
          local label
          if h.name then
            label = string.format("%s (pull %d)", h.name, h.pullIndex)
          else
            label = "pull " .. h.pullIndex
          end
          print(string.format("    [%d] %s  →  %.1f%% forces (%d / %d)  — fires at %s%s",
            i, label, pct, cum, total, fire, viaTag))
        else
          print(string.format("    [%d] %s (encounterID %s)  — fires at ENCOUNTER_START%s",
            i, h.name or "boss", tostring(h.encounterID), viaTag))
        end
      end
    else
      print("  dry-run: no lust note found in objects[]; scanning per-pull notes…")
      local count = 0
      for i, pull in ipairs(preset.value.pulls) do
        local note = pull.text or pull.note or pull.notes
        if isLustNote(note) then
          print(string.format("  dry-run: per-pull match at pull %d — %s", i, tostring(note)))
          count = count + 1
        end
      end
      if count == 0 then
        print("  dry-run: no per-pull lust notes matched either")
      end
    end
  end
end

--- Preview a Tactyks-style multi-fire sequence so you can sanity-check
--- the popup, sound, and numbering ("LUST 1/3", "LUST 2/3", "LUST 3/3")
--- without being in a live key.
--- Exhaustively scan every widget-set ID from 1..maxSet looking for
--- widgets that could be the forces display. Used to find the right set
--- when our short candidate list misses (Blizzard occasionally moves it).
function Keys.LustReminderScan(maxSet)
  maxSet = tonumber(maxSet) or 500
  if not _G.C_UIWidgetManager or not C_UIWidgetManager.GetAllWidgetsBySetID then
    print("|cffff8800ZugZug Keys:|r C_UIWidgetManager not available.")
    return
  end
  print(string.format("|cffff8800ZugZug Keys:|r scanning widget sets 1..%d ...", maxSet))
  local foundSets, total = 0, 0
  for setID = 1, maxSet do
    local ok, widgets = pcall(C_UIWidgetManager.GetAllWidgetsBySetID, setID)
    if ok and type(widgets) == "table" and #widgets > 0 then
      foundSets = foundSets + 1
      total = total + #widgets
      print(string.format("  set %d (%d widgets):", setID, #widgets))
      for _, w in ipairs(widgets) do
        if w.widgetType == 8 and C_UIWidgetManager.GetTextWithStateWidgetVisualizationInfo then
          local ok2, info = pcall(C_UIWidgetManager.GetTextWithStateWidgetVisualizationInfo, w.widgetID)
          if ok2 and type(info) == "table" then
            local pct = parseForcesText(info.text)
            print(string.format("    [text] id=%d text=%q parsed=%s",
              w.widgetID, tostring(info.text or ""),
              pct and string.format("%.1f%%", pct) or "nil"))
          end
        elseif w.widgetType == 2 and C_UIWidgetManager.GetStatusBarWidgetVisualizationInfo then
          local ok2, info = pcall(C_UIWidgetManager.GetStatusBarWidgetVisualizationInfo, w.widgetID)
          if ok2 and type(info) == "table" then
            print(string.format("    [bar] id=%d val=%s/%s tooltip=%q",
              w.widgetID, tostring(info.barValue), tostring(info.barMax),
              tostring(info.tooltip or "")))
          end
        else
          print(string.format("    [type=%s] id=%s", tostring(w.widgetType), tostring(w.widgetID)))
        end
      end
    end
  end
  print(string.format("|cffff8800ZugZug Keys:|r scan complete — %d populated sets, %d widgets total.",
    foundSets, total))
end

--- Clear the locked forces widget ID + every widget we've recorded.
--- Useful if a wrong widget got locked early; the next UPDATE_UI_WIDGET
--- batch will re-discover the right one with the tightened heuristic.
function Keys.LustReminderUnlock()
  state.forcesWidgetID = nil
  state.seenWidgets    = {}
  print("|cffff8800ZugZug Keys:|r forces widget unlocked. Will re-discover on next widget update.")
end

function Keys.LustReminderTest()
  -- Clear any live state so the preview is clean.
  state.targets    = {}
  state.source     = "test"
  state.noteSource = "object"
  state.routeNote  = "test sequence (no live key)"

  local samples = {
    { kind = "pull", pullIndex = 1,  targetPct = 0,  fired = false },
    { kind = "pull", pullIndex = 6,  targetPct = 25, fired = false },
    { kind = "pull", pullIndex = 11, targetPct = 55, fired = false },
  }
  for _, t in ipairs(samples) do table.insert(state.targets, t) end

  print("|cffff8800ZugZug Keys:|r firing 3-alert lust preview "
    .. "(once now, then 4s and 8s later).")
  fireAlert(samples[1], "preview")
  C_Timer.After(4, function() fireAlert(samples[2], "preview") end)
  C_Timer.After(8, function() fireAlert(samples[3], "preview") end)
  -- Clear state after the last popup auto-hides so a subsequent /zzk lust
  -- shows the live (or empty) targets table rather than the preview.
  C_Timer.After(18, function()
    if state.source == "test" then state.targets = {}; state.source = nil; state.routeNote = nil end
  end)
end

--- Dump every place MDT might store presets, organised by dungeon idx
--- so we can see exactly where each route lives. Useful when a route is
--- visible in MDT's UI but the lust reminder claims none exists.
function Keys.LustReminderDumpPresets()
  if not _G.MDT then print("|cffff8800ZZK:|r MDT not loaded") return end

  print("|cffff8800ZZK lust PRESETS (slim):|r")

  -- (1) MDT:CountPresets per Midnight S1 dungeon idx — tells us where MDT
  -- thinks routes actually exist, without us needing to know the storage path.
  if type(MDT.CountPresets) == "function" then
    print("  MDT:CountPresets(idx):")
    for idx = 150, 160 do
      local ok, count = pcall(MDT.CountPresets, MDT, idx)
      if ok and type(count) == "number" and count > 0 then
        local name = (MDT.dungeonList and MDT.dungeonList[idx]) or "?"
        print(string.format("    idx=%d (%s): %d presets", idx, tostring(name), count))
      end
    end
  end

  -- (2) MDT:GetDB() top-level structure — find the right path for enumeration.
  if type(MDT.GetDB) == "function" then
    local okDB, db = pcall(MDT.GetDB, MDT)
    if okDB and type(db) == "table" then
      print("  MDT:GetDB() top-level:")
      for k in pairs(db) do
        print(string.format("    .%s = %s", tostring(k), type(db[k])))
      end
      if type(db.presets) == "table" then
        local cnt = 0
        for _ in pairs(db.presets) do cnt = cnt + 1 end
        print(string.format("    db.presets has %d dungeon buckets", cnt))
      end
    end
  end

  -- (3) MythicDungeonToolsDB.global.currentPreset — your dump said 200
  -- entries; let's see the first few to understand what's stored.
  local svdb = _G.MythicDungeonToolsDB
  if type(svdb) == "table" and type(svdb.global) == "table"
      and type(svdb.global.currentPreset) == "table" then
    print("  MythicDungeonToolsDB.global.currentPreset (first 8 keys):")
    local i = 0
    for k, v in pairs(svdb.global.currentPreset) do
      i = i + 1
      if i > 8 then break end
      print(string.format("    [%s] = %s (%s)", tostring(k), tostring(v), type(v)))
    end
  end

  -- (5) Original probes (kept compact).
  local stores = {
    { path = "MDT.db.global.presets",  t = MDT.db and MDT.db.global  and MDT.db.global.presets  },
    { path = "MDT.db.profile.presets", t = MDT.db and MDT.db.profile and MDT.db.profile.presets },
    { path = "MDT.db.char.presets",    t = MDT.db and MDT.db.char    and MDT.db.char.presets    },
    { path = "MDT.presets",            t = MDT.presets                                          },
    { path = "MDT.presetCache",        t = MDT.presetCache                                      },
  }
  for _, s in ipairs(stores) do
    if type(s.t) == "table" then
      print("  " .. s.path .. ":")
      local found = 0
      for idx, presets in pairs(s.t) do
        found = found + 1
        local dungeonName = MDT.dungeonList and MDT.dungeonList[idx]
        local mapID = mdtMapIDForDungeon(idx)
        local presetCount = (type(presets) == "table") and #presets or 0
        print(string.format("    [%s] %s (mapID=%s) — %d presets",
          tostring(idx), tostring(dungeonName or "?"),
          tostring(mapID or "?"), presetCount))
        if type(presets) == "table" then
          for i, p in ipairs(presets) do
            if i <= 5 then
              print(string.format("      [%d] %q", i, tostring(p and p.text or "?")))
            end
          end
        end
      end
      if found == 0 then print("    (empty table)") end
    else
      print("  " .. s.path .. " = " .. type(s.t))
    end
  end

  -- Also show what the "currentPreset" pointer is per dungeon.
  if MDT.db and MDT.db.global and type(MDT.db.global.currentPreset) == "table" then
    print("  MDT.db.global.currentPreset (last-selected preset per dungeon):")
    for idx, presetIdx in pairs(MDT.db.global.currentPreset) do
      local dungeonName = MDT.dungeonList and MDT.dungeonList[idx]
      print(string.format("    [%s] %s → presetIdx %s",
        tostring(idx), tostring(dungeonName or "?"), tostring(presetIdx)))
    end
  end
end

--- Dump the current MDT preset's top-level structure so we can see where
--- Tactyks (or any author) actually stores notes and per-pull counts.
function Keys.LustReminderDump()
  print("|cffff8800ZZK lust DUMP:|r")
  if not _G.MDT then print("  MDT not loaded") return end

  local okPreset, preset = pcall(getCurrentPreset)
  if not okPreset then
    print("  |cffff6666getCurrentPreset() ERRORED:|r " .. tostring(preset))
    return
  end
  if not preset then
    print("  getCurrentPreset() returned nil")
    return
  end
  print("  preset resolved: text=" .. tostring(preset.text)
    .. "  has .value=" .. tostring(type(preset.value) == "table")
    .. "  has .objects=" .. tostring(type(preset.objects) == "table"))

  local function listKeys(label, t, valueDepth)
    if type(t) ~= "table" then
      print("  " .. label .. " is " .. type(t)) return
    end
    print("  " .. label .. " keys:")
    for k, v in pairs(t) do
      local kind = type(v)
      local extra = ""
      if kind == "table" then
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        extra = " (entries=" .. n .. ")"
      elseif kind == "string" then
        extra = "  -> " .. (#v <= 80 and v or v:sub(1, 80) .. "…")
      elseif kind == "number" or kind == "boolean" then
        extra = "  = " .. tostring(v)
      end
      print(string.format("    .%s = %s%s", tostring(k), kind, extra))
    end
  end

  listKeys("preset", preset)
  if type(preset.value) == "table" then
    listKeys("preset.value", preset.value)
    if type(preset.value.pulls) == "table" and preset.value.pulls[1] then
      print("  preset.value.pulls[1] full dump:")
      for k, v in pairs(preset.value.pulls[1]) do
        if type(v) == "table" then
          local fields = {}
          for k2, v2 in pairs(v) do
            table.insert(fields, tostring(k2) .. "=" .. tostring(v2))
          end
          print(string.format("    [%s] table { %s }",
            tostring(k), table.concat(fields, ", ")))
        else
          print(string.format("    [%s] = %s (%s)", tostring(k), tostring(v), type(v)))
        end
      end
    end
    -- Look anywhere notes might live (sub-keys of preset.value)
    for _, k in ipairs({ "objects", "notes", "comments", "metadata", "freeNotes",
                        "presetNotes", "n", "preview" }) do
      local v = preset.value[k]
      if v ~= nil then
        print(string.format("  preset.value.%s = %s (type=%s)", k, tostring(v), type(v)))
      end
    end
  end

  -- preset.objects (TOP-LEVEL) — Tactyks puts notes here.
  if type(preset.objects) == "table" then
    local n = 0
    for _ in pairs(preset.objects) do n = n + 1 end
    print("  preset.objects (top-level) entries: " .. n)
    for i, obj in ipairs(preset.objects) do
      if i > 6 then break end
      if type(obj) == "table" then
        print("  preset.objects[" .. i .. "]:")
        for k, v in pairs(obj) do
          if type(v) == "string" then
            local rep = (#v <= 120 and v) or (v:sub(1, 120) .. "…")
            print(string.format("      .%s = string  -> %s", tostring(k), rep))
          elseif type(v) == "table" then
            local nn = 0
            for _ in pairs(v) do nn = nn + 1 end
            print(string.format("      .%s = table (entries=%d) — full dump:", tostring(k), nn))
            for k2, v2 in pairs(v) do
              local r2 = tostring(v2)
              if type(v2) == "string" then
                r2 = (#v2 <= 120 and v2) or (v2:sub(1, 120) .. "…")
              elseif type(v2) == "table" then
                local mm = 0
                for _ in pairs(v2) do mm = mm + 1 end
                r2 = "table (entries=" .. mm .. ")"
              end
              print(string.format("          [%s] = %s (%s)",
                tostring(k2), r2, type(v2)))
            end
          else
            print(string.format("      .%s = %s (%s)", tostring(k), tostring(v), type(v)))
          end
        end
      else
        print("  preset.objects[" .. i .. "] = " .. tostring(obj) .. " (" .. type(obj) .. ")")
      end
    end
  else
    print("  preset.objects (top-level) = nil/" .. type(preset.objects))
  end
  -- Also probe MDT's top-level enemy/totals API
  print("  MDT.GetEnemyForces type = " .. tostring(type(MDT.GetEnemyForces)))
  if type(MDT.GetEnemyForces) == "function" then
    local ok, val = pcall(MDT.GetEnemyForces, MDT)
    print("  MDT:GetEnemyForces() = " .. tostring(ok) .. " / " .. tostring(val))
  end
  print("  MDT.GetCurrentSubLevel type = " .. tostring(type(MDT.GetCurrentSubLevel)))
  if type(MDT.GetCurrentSubLevel) == "function" then
    local ok, val = pcall(MDT.GetCurrentSubLevel, MDT)
    print("  MDT:GetCurrentSubLevel() = " .. tostring(ok) .. " / " .. tostring(val))
  end
  print("  MDT.dungeonEnemies type = " .. tostring(type(MDT.dungeonEnemies)))
  if type(MDT.dungeonEnemies) == "table" then
    local cnt = 0
    for _ in pairs(MDT.dungeonEnemies) do cnt = cnt + 1 end
    print("    dungeonEnemies dungeon entries = " .. cnt)
  end
  print("  MDT.dungeonTotalCount type = " .. tostring(type(MDT.dungeonTotalCount)))
  if type(MDT.dungeonTotalCount) == "table" then
    for k, v in pairs(MDT.dungeonTotalCount) do
      print(string.format("    dungeonTotalCount[%s] = %s", tostring(k), tostring(v)))
    end
  end
end
