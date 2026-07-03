----------------------------------------------------------------------
-- ZugZug Keys — Settings Panel
-- Registered under "ZugZug Keys" in the Blizzard AddOns options. Features
-- are grouped into translucent section cards with green headers.
--
-- Layout model (four things working together):
--   * Flow anchoring — every element anchors to the PREVIOUS element's
--     bottom, so a row that wraps to more lines pushes everything below it
--     down instead of overlapping (fixed y-offsets caused that bug).
--   * Wrap-safe rows — a checkbox is a fixed 26px tall, but its label can
--     wrap past that. Each toggle/radio lives in a row frame whose height
--     is measured from the wrapped label, so the next row still clears it.
--   * Section cards WRAP their rows — the rows join the normal flow
--     (anchored to the previous element, NOT to the card); the card's edges
--     anchor AROUND them (top→header, bottom→last row, sides→panel). The
--     direction matters: if the rows anchored to the card AND the card
--     anchored to the rows, WoW rejects it as a circular dependency.
--   * Panel height is measured from the last row after layout (and on
--     resize), so the scroll range is always exactly the content height.
----------------------------------------------------------------------

local Keys = _G.ZugZugKeys

-- ZugZug brand green, reused for headers / accents / checked states.
local GREEN     = { 0.56, 0.75, 0.25 }
local GREEN_HEX = "8fbf3f"

-- Text right-edge inset (inside a card) so labels wrap before the border.
local RIGHT_PAD   = 16
local CARD_MARGIN = 14   -- card inset from the panel's left/right edges
local CARD_PAD    = 14   -- content inset from the card's left edge

-- Indent tiers, measured from the panel's left edge (the flow chains back
-- to the panel, so every indent is panel-relative).
local IND_ITEM    = CARD_MARGIN + CARD_PAD        -- 28: header + top-level rows
local IND_NOTE    = CARD_MARGIN + CARD_PAD + 26   -- 54: note under a top row
local IND_SUB     = CARD_MARGIN + CARD_PAD + 14   -- 42: nested sub-option
local IND_SUB2    = CARD_MARGIN + CARD_PAD + 28   -- 56: doubly-nested (radios)
local IND_SUBNOTE = CARD_MARGIN + CARD_PAD + 40   -- 68: note under a sub-option

-- Prefer the mid-size header font when present; fall back gracefully.
local SECTION_FONT = _G.GameFontNormalMed2 and "GameFontNormalMed2" or "GameFontNormal"
local TITLE_FONT   = _G.GameFontNormalHuge and "GameFontNormalHuge" or "GameFontNormalLarge"

local function CreateSettingsPanel()
  local canvas = CreateFrame("Frame", "ZugZugKeysSettingsPanel")
  canvas.name = "ZugZug Keys"

  -- Scroll wrapper: the panel has outgrown small resolutions / UI scales.
  local scrollFrame = CreateFrame("ScrollFrame", "ZugZugKeysSettingsScroll", canvas, "UIPanelScrollFrameTemplate")
  scrollFrame:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -8)
  scrollFrame:SetPoint("BOTTOMRIGHT", canvas, "BOTTOMRIGHT", -28, 8)
  local panel = CreateFrame("Frame", "ZugZugKeysSettingsContent", scrollFrame)
  panel:SetSize(600, 880)
  scrollFrame:SetScrollChild(panel)

  -- Every wrap-safe check row, re-fitted to its wrapped label after layout.
  local checkRows = {}

  ------------------------------------------------------------------
  -- Flow engine
  ------------------------------------------------------------------
  local last, lastIndent = nil, 0 -- previous content element

  local function place(region, indent, gap)
    if last then
      region:SetPoint("TOPLEFT", last, "BOTTOMLEFT", indent - lastIndent, -(gap or 10))
    else
      region:SetPoint("TOPLEFT", panel, "TOPLEFT", indent, -16)
    end
    last, lastIndent = region, indent
  end

  ------------------------------------------------------------------
  -- Row builders
  ------------------------------------------------------------------
  -- A checkbox + wrapping label inside a self-sizing row frame. The label
  -- anchors RIGHT to the card so it wraps; fitRow (run after layout) sets
  -- the row height to contain the wrapped text so the flow clears it.
  local function CreateCheckRow(parent, markup, onClick)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(10, 26)  -- height re-fitted after layout
    local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOPLEFT", cb, "TOPRIGHT", 4, -6)
    text:SetPoint("RIGHT", parent, "RIGHT", -RIGHT_PAD, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(true)
    text:SetText(markup)
    cb:SetScript("OnClick", function(self)
      if onClick then onClick(self:GetChecked(), self) end
    end)
    row.cb, row.text = cb, text
    checkRows[#checkRows + 1] = row
    return row
  end

  local function CreateToggle(parent, label, dbKey, subtitle, onChange)
    local markup = label .. (subtitle and ("  |cff888888" .. subtitle .. "|r") or "")
    local row = CreateCheckRow(parent, markup, function(checked)
      ZugZugKeysDB[dbKey] = checked
      if onChange then onChange(checked) end
    end)
    row.cb:SetChecked(ZugZugKeysDB[dbKey])
    return row
  end

  -- Explanation paragraph under a toggle. Parented to the card (so it draws
  -- above the card backing) but its RIGHT edge anchors to the PANEL, not the
  -- card: notes sit in the flow the card's bottom depends on, so anchoring
  -- them to the card would be circular (same reason as the section divider).
  -- The next element anchors to this note's wrapped bottom, so it's flow-safe.
  local function CreateNote(parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetPoint("RIGHT", panel, "RIGHT", -(CARD_MARGIN + RIGHT_PAD), 0)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    fs:SetText("|cff666666" .. text .. "|r")
    return fs
  end

  ------------------------------------------------------------------
  -- Section cards
  ------------------------------------------------------------------
  local TOP_WRAP = 12
  local function beginSection(titleText, gapAbove)
    local card = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    card:SetBackdrop({
      bgFile   = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      edgeSize = 1,
    })
    card:SetBackdropColor(0.055, 0.07, 0.05, 0.55)
    card:SetBackdropBorderColor(GREEN[1], GREEN[2], GREEN[3], 0.18)

    -- Header joins the flow (anchored to whatever preceded this section).
    local header = card:CreateFontString(nil, "OVERLAY", SECTION_FONT)
    header:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
    header:SetText(titleText)
    place(header, IND_ITEM, gapAbove or 24)

    -- Card wraps the header: top-left derives from the header (so the card
    -- top sits TOP_WRAP above it and its left edge lands at CARD_MARGIN),
    -- right pins to the panel, bottom is closed in endSection.
    card:SetPoint("TOPLEFT", header, "TOPLEFT", -CARD_PAD, TOP_WRAP)
    card:SetPoint("RIGHT", panel, "RIGHT", -CARD_MARGIN, 0)

    local bullet = card:CreateTexture(nil, "ARTWORK")
    bullet:SetColorTexture(GREEN[1], GREEN[2], GREEN[3], 0.9)
    bullet:SetSize(3, 13)
    bullet:SetPoint("RIGHT", header, "LEFT", -6, 0)

    -- Divider's right edge anchors to the PANEL, not the card: the card
    -- depends on the last row, whose flow runs through this divider, so
    -- anchoring the divider to the card would close a dependency loop.
    local div = card:CreateTexture(nil, "ARTWORK")
    div:SetColorTexture(GREEN[1], GREEN[2], GREEN[3], 0.20)
    div:SetHeight(1)
    place(div, IND_ITEM, 7)
    div:SetPoint("RIGHT", panel, "RIGHT", -(CARD_MARGIN + CARD_PAD), 0)

    return card
  end

  local function endSection(card, bottomPad)
    if card and last then
      card:SetPoint("BOTTOM", last, "BOTTOM", 0, -(bottomPad or 12))
    end
  end

  ------------------------------------------------------------------
  -- Header
  ------------------------------------------------------------------
  local title = panel:CreateFontString(nil, "OVERLAY", TITLE_FONT)
  title:SetJustifyH("LEFT")
  title:SetWordWrap(false)
  title:SetText("|cff" .. GREEN_HEX .. "ZugZug|r Keys")
  place(title, CARD_MARGIN, 2)

  local accent = panel:CreateTexture(nil, "ARTWORK")
  accent:SetColorTexture(GREEN[1], GREEN[2], GREEN[3], 0.7)
  accent:SetHeight(2)
  place(accent, CARD_MARGIN, 8)
  accent:SetPoint("RIGHT", panel, "RIGHT", -CARD_MARGIN, 0)

  local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  sub:SetPoint("RIGHT", panel, "RIGHT", -CARD_MARGIN, 0)
  sub:SetJustifyH("LEFT")
  sub:SetWordWrap(true)
  sub:SetTextColor(0.7, 0.7, 0.7)
  sub:SetText("Mythic+ tools and tweaks. Lust Reminder is opt-in; the rest are on by default.")
  place(sub, CARD_MARGIN, 8)

  ------------------------------------------------------------------
  -- General
  ------------------------------------------------------------------
  local gen = beginSection("General", 22)

  local bnToggle = CreateToggle(gen, "BNet Status Broadcast", "bnStatus",
    "(updates your Battle.net message when a key starts)")
  place(bnToggle, IND_ITEM, 10)
  local bnNote = CreateNote(gen,
    "Posts once at key start with start/estimated finish time. Restores your previous message after the key ends.")
  place(bnNote, IND_NOTE, 4)

  local infoToggle = CreateToggle(gen, "Group Key Info", "groupKeyInfo",
    "(shows group title + dungeon when you join via LFG)",
    function() if Keys.UpdateGroupKeyInfoFeature then Keys.UpdateGroupKeyInfoFeature() end end)
  place(infoToggle, IND_ITEM, 14)
  local infoNote = CreateNote(gen,
    "Stays open even after the group disbands until you enter that instance, or close it manually.")
  place(infoNote, IND_NOTE, 4)

  local lockToggle = CreateToggle(gen, "Lock frame position", "groupKeyInfoLocked")
  place(lockToggle, IND_SUB, 8)

  local resetBtn = CreateFrame("Button", nil, gen, "UIPanelButtonTemplate")
  resetBtn:SetSize(140, 22)
  resetBtn:SetText("Reset Position")
  resetBtn:SetScript("OnClick", function()
    if Keys.ResetGroupKeyInfoPosition then Keys.ResetGroupKeyInfoPosition() end
  end)
  place(resetBtn, IND_SUB + 2, 8)

  local flToggle = CreateToggle(gen, "Friends List Overlay", "friendsListOverlay",
    "(shows +level + est. finish on friends running a ZugZug key)",
    function() if Keys.RefreshFriendsListOverlay then Keys.RefreshFriendsListOverlay() end end)
  place(flToggle, IND_ITEM, 14)

  endSection(gen, 12)

  ------------------------------------------------------------------
  -- Lust Reminder
  ------------------------------------------------------------------
  local lust = beginSection("Lust Reminder", 34)

  local lustToggle = CreateToggle(lust, "Enable Lust Reminder", "lustReminder",
    "(alerts you when to lust in-key)")
  place(lustToggle, IND_ITEM, 10)
  local lustNote = CreateNote(lust,
    "Fires a screen popup + sound at the planned lust moment. Calls come from WCL top-log consensus or your MDT route (priority below); with neither it defaults to lust-on-first-boss. A lead-up line shows the forces % approaching the target. Non-lust classes still get the forces-bar marks (no popup) so they can line their own cooldowns up.")
  place(lustNote, IND_NOTE, 4)

  local lustSoundToggle = CreateToggle(lust, "Play alert sound", "lustReminderSound")
  place(lustSoundToggle, IND_SUB, 8)
  local lustFallbackToggle = CreateToggle(lust, "First-boss / curated fallback when no route", "lustReminderCuratedFallback")
  place(lustFallbackToggle, IND_SUB, 4)
  local lustBarMarksToggle = CreateToggle(lust, "Mark planned lusts on the forces bar", "lustReminderBarMarks",
    "(green ticks; %-based calls only)",
    function() if Keys.RefreshForcesBarMarks then Keys.RefreshForcesBarMarks() end end)
  place(lustBarMarksToggle, IND_SUB, 4)
  local lustDebugToggle = CreateToggle(lust, "Debug logging", "lustReminderDebug")
  place(lustDebugToggle, IND_SUB, 4)

  -- Alert lead stepper: fire "LUST NOW" N forces-% before the target so
  -- the cast lands as the pull hits the threshold, not after.
  local leadValue
  local function leadText()
    return string.format("Alert lead: |cff" .. GREEN_HEX .. "%d%%|r before target", ZugZugKeysDB.lustReminderLeadPct or 3)
  end
  local minusBtn = CreateFrame("Button", nil, lust, "UIPanelButtonTemplate")
  minusBtn:SetSize(24, 22)
  minusBtn:SetText("-")
  place(minusBtn, IND_SUB, 12)
  local plusBtn = CreateFrame("Button", nil, lust, "UIPanelButtonTemplate")
  plusBtn:SetSize(24, 22)
  plusBtn:SetText("+")
  plusBtn:SetPoint("LEFT", minusBtn, "RIGHT", 4, 0)
  leadValue = lust:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  leadValue:SetPoint("LEFT", plusBtn, "RIGHT", 10, 0)
  leadValue:SetText(leadText())
  local function stepLead(delta)
    local v = (ZugZugKeysDB.lustReminderLeadPct or 3) + delta
    if v < 0 then v = 0 end
    if v > 10 then v = 10 end
    ZugZugKeysDB.lustReminderLeadPct = v
    leadValue:SetText(leadText())
  end
  minusBtn:SetScript("OnClick", function() stepLead(-1) end)
  plusBtn:SetScript("OnClick", function() stepLead(1) end)

  -- Call source priority: which source wins when both are available.
  local srcLabel = lust:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  srcLabel:SetTextColor(0.85, 0.85, 0.85)
  srcLabel:SetText("Call source priority")
  place(srcLabel, IND_SUB, 14)

  local wclRow, mdtRow
  local function refreshSourceButtons()
    local src = ZugZugKeysDB.lustReminderSource or "wcl"
    wclRow.cb:SetChecked(src == "wcl")
    mdtRow.cb:SetChecked(src == "mdt")
  end
  -- UICheckButtonTemplate + mutual exclusion gives radio behaviour with a
  -- guaranteed-present template. (UIRadioButtonTemplate looks rounder, but
  -- a wrong template name fails the whole panel via the register pcall.)
  local function makeSourceBtn(value, label, subtitle)
    return CreateCheckRow(lust, label .. "  |cff888888" .. subtitle .. "|r", function()
      ZugZugKeysDB.lustReminderSource = value
      refreshSourceButtons()
    end)
  end
  wclRow = makeSourceBtn("wcl", "WCL top logs", "(weekly consensus from the highest keys)")
  place(wclRow, IND_SUB2, 6)
  mdtRow = makeSourceBtn("mdt", "My MDT route", "(your imported route's lust marker)")
  place(mdtRow, IND_SUB2, 2)
  refreshSourceButtons()

  local announceToggle = CreateToggle(lust, "Announce lust plan on ready check", "lustReminderAnnounce")
  place(announceToggle, IND_SUB, 12)
  local announceNote = CreateNote(lust,
    "One party-chat line when a ready check fires inside the dungeon, telling the group where lust is planned.")
  place(announceNote, IND_SUBNOTE, 4)

  endSection(lust, 12)

  ------------------------------------------------------------------
  -- Footer
  ------------------------------------------------------------------
  local footer = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  footer:SetPoint("RIGHT", panel, "RIGHT", -CARD_MARGIN, 0)
  footer:SetJustifyH("LEFT")
  footer:SetText("|cff555555Type|r |cff" .. GREEN_HEX .. "/zzk|r|cff555555 for commands  ·  zugzug.info|r")
  place(footer, CARD_MARGIN, 18)

  ------------------------------------------------------------------
  -- Post-layout: fit each wrap-safe row to its wrapped label, then size
  -- the scroll child to exactly the content height. Re-run on show and on
  -- width change so wrapping never clips the last card.
  ------------------------------------------------------------------
  local function fitRow(row)
    local th = row.text:GetStringHeight()
    if th and th > 0 then
      row:SetHeight(math.max(26, math.ceil(th) + 8))
    end
  end
  local function relayout()
    for _, r in ipairs(checkRows) do fitRow(r) end
    -- Measure one frame later, after the re-fitted heights have flowed.
    C_Timer.After(0, function()
      local top    = panel:GetTop()
      local bottom = footer:GetBottom()
      if top and bottom then
        panel:SetHeight(top - bottom + 24)
      end
    end)
  end
  scrollFrame:SetScript("OnSizeChanged", function(_, w)
    if w and w > 0 then panel:SetWidth(w) end
    C_Timer.After(0, relayout)
  end)
  panel:SetScript("OnShow", function() C_Timer.After(0, relayout) end)

  return canvas
end

----------------------------------------------------------------------
-- Register with the Settings system
----------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self)
  local ok, err = pcall(function()
    local panel = CreateSettingsPanel()
    local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(category)
    Keys.settingsCategory = category
  end)
  if not ok then
    print("|cff8fbf3fZugZug Keys:|r Settings panel failed: " .. tostring(err))
  end
  self:UnregisterEvent("PLAYER_LOGIN")
end)

----------------------------------------------------------------------
-- /zzk slash command — open settings + show toggles state
----------------------------------------------------------------------

SLASH_ZUGZUGKEYS1 = "/zzk"
SLASH_ZUGZUGKEYS2 = "/zzkeys"
SlashCmdList["ZUGZUGKEYS"] = function(msg)
  local cmd = (msg and msg:match("^(%S+)") or ""):lower()
  if cmd == "settings" or cmd == "options" or cmd == "config" or cmd == "" then
    local ok = pcall(function()
      if Keys.settingsCategory then
        Settings.OpenToCategory(Keys.settingsCategory:GetID())
      else
        Settings.OpenToCategory("ZugZug Keys")
      end
    end)
    if not ok then print("|cff8fbf3fZugZug Keys:|r Could not open settings.") end
    return
  end
  if cmd == "refresh" then
    if Keys.refreshStatus then
      Keys.refreshStatus()
      print("|cff8fbf3fZugZug Keys:|r status refreshed (broadcast updated if in a key + toggle on)")
    else
      print("|cff8fbf3fZugZug Keys:|r refresh unavailable (Status module not loaded)")
    end
    return
  end
  if cmd == "friends" or cmd == "refreshfriends" then
    if Keys.RefreshFriendsListOverlay then
      Keys.RefreshFriendsListOverlay()
      print("|cff8fbf3fZugZug Keys:|r friends list overlay refreshed")
    end
    return
  end
  if cmd == "hideinfo" or cmd == "closeinfo" then
    if Keys.HideGroupKeyInfo then
      Keys.HideGroupKeyInfo()
      print("|cff8fbf3fZugZug Keys:|r group key info hidden")
    end
    return
  end
  if cmd == "lust" or cmd == "luststatus" then
    if Keys.LustReminderStatus then
      Keys.LustReminderStatus()
    else
      print("|cff8fbf3fZugZug Keys:|r Lust Reminder module not loaded")
    end
    return
  end
  if cmd:sub(1, 7) == "lustsim" then
    -- /zzk lustsim                  — summary across every MDT dungeon
    -- /zzk lustsim 1                — full dump for dungeonIdx 1
    local rest = msg:match("^%S+%s+(%S+)")
    if Keys.LustReminderSim then Keys.LustReminderSim(rest) end
    return
  end
  print("|cff8fbf3fZugZug Keys|r — Mythic+ tools")
  print("  /zzk settings  — open the settings panel")
  print("  /zzk refresh   — re-fire the key-start broadcast for the current key")
  print("  /zzk hideinfo  — close the group key info box")
  print("  /zzk friends   — manually refresh the friends list overlay")
  print("  /zzk lust      — Lust Reminder status (targets, forces %, errors)")
  print("  /zzk lustsim [dungeonIdx]  — preview lust-target parsing for any MDT route")
end
