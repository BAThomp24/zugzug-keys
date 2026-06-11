----------------------------------------------------------------------
-- ZugZug Keys — Settings Panel
-- Registered under "ZugZug Keys" in the Blizzard AddOns options. Each
-- feature is its own toggle; all default off.
----------------------------------------------------------------------

local Keys = _G.ZugZugKeys

-- All toggle labels and notes need a right-edge anchor so they wrap inside
-- the settings canvas instead of overflowing the AddOns Options window.
-- The canvas's actual width depends on Blizzard's Settings frame, but
-- pinning to `parent` lets the text reflow whenever the panel is resized.
local RIGHT_PAD = 16

local function CreateToggle(parent, x, y, label, dbKey, subtitle, onChange)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  cb.text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  cb.text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
  cb.text:SetPoint("RIGHT", parent, "RIGHT", -RIGHT_PAD, 0)
  cb.text:SetJustifyH("LEFT")
  cb.text:SetWordWrap(true)
  cb.text:SetText(label .. (subtitle and ("  |cff888888" .. subtitle .. "|r") or ""))
  cb:SetChecked(ZugZugKeysDB[dbKey])
  cb:SetScript("OnClick", function(self)
    ZugZugKeysDB[dbKey] = self:GetChecked()
    if onChange then onChange(self:GetChecked()) end
  end)
  return cb
end

-- Helper for the explanation paragraphs under toggles.
local function CreateNote(parent, anchor, text)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 4, -2)
  fs:SetPoint("RIGHT", parent, "RIGHT", -RIGHT_PAD, 0)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(true)
  fs:SetText("|cff666666" .. text .. "|r")
  return fs
end

local function CreateSettingsPanel()
  local canvas = CreateFrame("Frame", "ZugZugKeysSettingsPanel")
  canvas.name = "ZugZug Keys"

  local title = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetPoint("RIGHT", canvas, "RIGHT", -RIGHT_PAD, 0)
  title:SetJustifyH("LEFT")
  title:SetWordWrap(false)
  title:SetText("|cff8fbf3fZugZug|r Keys Settings")

  local sub = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  sub:SetPoint("RIGHT", canvas, "RIGHT", -RIGHT_PAD, 0)
  sub:SetJustifyH("LEFT")
  sub:SetWordWrap(true)
  sub:SetText("Mythic+ tools and tweaks — each feature is off by default.")

  -- BNet status broadcast
  local bnToggle = CreateToggle(canvas, 16, -70, "BNet Status Broadcast", "bnStatus",
    "(updates your Battle.net custom message when a key starts)")
  local bnNote = CreateNote(canvas, bnToggle,
    "Posts once at key start with start/estimated finish time. Restores your previous message after the key ends.")

  -- Group key info
  local infoToggle = CreateToggle(canvas, 16, -130, "Group Key Info", "groupKeyInfo",
    "(small box showing group title + dungeon when you join via LFG)",
    function() if Keys.UpdateGroupKeyInfoFeature then Keys.UpdateGroupKeyInfoFeature() end end)
  local infoNote = CreateNote(canvas, infoToggle,
    "Stays open even after the group disbands until you enter that instance, or close it manually.")

  local lockToggle = CreateToggle(canvas, 32, -180, "Lock frame position", "groupKeyInfoLocked")

  local resetBtn = CreateFrame("Button", nil, canvas, "UIPanelButtonTemplate")
  resetBtn:SetSize(140, 22)
  resetBtn:SetPoint("TOPLEFT", canvas, "TOPLEFT", 32, -210)
  resetBtn:SetText("Reset Position")
  resetBtn:SetScript("OnClick", function()
    if Keys.ResetGroupKeyInfoPosition then Keys.ResetGroupKeyInfoPosition() end
  end)

  -- Friends list overlay
  local flToggle = CreateToggle(canvas, 16, -260, "Friends List Overlay", "friendsListOverlay",
    "(shows +level + estimated finish on friends running a ZugZug-broadcasted key)",
    function() if Keys.RefreshFriendsListOverlay then Keys.RefreshFriendsListOverlay() end end)

  -- Lust Reminder
  local lustToggle = CreateToggle(canvas, 16, -310, "Lust Reminder", "lustReminder",
    "(reads your MDT route for a lust marker and alerts in-key)")
  local lustNote = CreateNote(canvas, lustToggle,
    "Reads your active Mythic Dungeon Tools route, finds a lust note (BL/Hero/Drums/etc.), and fires a screen popup + sound when forces hit the right %. Falls back to a curated boss recommendation when no route is loaded.")

  local lustSoundToggle = CreateToggle(canvas, 32, -360, "Play alert sound", "lustReminderSound")
  local lustFallbackToggle = CreateToggle(canvas, 32, -390, "Use curated boss fallback", "lustReminderCuratedFallback")
  local lustDebugToggle = CreateToggle(canvas, 32, -420, "Debug logging", "lustReminderDebug")

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
  if cmd == "debug" then
    ZugZugKeysDB.mpDebug = not ZugZugKeysDB.mpDebug
    print("|cff8fbf3fZugZug Keys:|r debug "
      .. (ZugZugKeysDB.mpDebug and "|cff4DFF4Don|r" or "|cffFF6666off|r"))
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
  if cmd == "forcebcast" or cmd == "force" then
    if not Keys.sendStatusNow then
      print("|cff8fbf3fZugZug Keys:|r forcebcast unavailable (Status module not loaded)")
      return
    end
    local rest = msg:match("^%S+%s+(.+)$")
    local text = rest or ("ZZK test " .. date("%H:%M:%S"))
    local bn = Keys.sendStatusNow(text)
    print(string.format("|cff8fbf3fZugZug Keys:|r forced broadcast: '%s'  (bn=%s)", text, tostring(bn)))
    if not ZugZugKeysDB.bnStatus then
      print("  |cffFF6666BNet toggle is off — nothing was sent.|r")
    end
    return
  end
  if cmd == "status" then
    print("|cff8fbf3fZugZug Keys:|r feature toggles —")
    print("  BNet Status: " .. (ZugZugKeysDB.bnStatus and "|cff4DFF4Don|r" or "|cffFF6666off|r"))
    print("  Group Key Info: " .. (ZugZugKeysDB.groupKeyInfo and "|cff4DFF4Don|r" or "|cffFF6666off|r"))
    print("  Friends List Overlay: " .. (ZugZugKeysDB.friendsListOverlay and "|cff4DFF4Don|r" or "|cffFF6666off|r"))
    return
  end
  if cmd == "friends" or cmd == "refreshfriends" then
    if Keys.RefreshFriendsListOverlay then
      Keys.RefreshFriendsListOverlay()
      print("|cff8fbf3fZugZug Keys:|r friends list overlay refreshed")
    end
    return
  end
  if cmd == "friendsdebug" or cmd == "fdebug" then
    if Keys.DumpFriendsListDebug then
      Keys.DumpFriendsListDebug()
    else
      print("|cff8fbf3fZugZug Keys:|r friends debug unavailable")
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
  if cmd == "testbcast" or cmd == "testbroadcast" then
    local s = Keys.state
    print("|cff8fbf3fZugZug Keys:|r diagnostic —")
    print(string.format("  inActiveKey=%s · keyName=%s · keyLevel=%s · keyTimeLimit=%s",
      tostring(s.inActiveKey), tostring(s.keyName), tostring(s.keyLevel), tostring(s.keyTimeLimit)))
    print(string.format("  setting bnStatus=%s · API BNSetCustomMessage=%s",
      tostring(ZugZugKeysDB.bnStatus), tostring(BNSetCustomMessage ~= nil)))
    if BNSetCustomMessage then
      local ok, err = pcall(BNSetCustomMessage, "ZZK test " .. date("%H:%M:%S"))
      print("  BNSetCustomMessage call: ok=" .. tostring(ok) .. (ok and "" or (" err=" .. tostring(err))))
    end
    return
  end
  if cmd == "luststatus" or cmd == "lust" then
    if Keys.LustReminderStatus then Keys.LustReminderStatus() end
    return
  end
  if cmd == "lusttest" then
    if Keys.LustReminderTest then Keys.LustReminderTest() end
    return
  end
  if cmd == "lustdump" then
    if Keys.LustReminderDump then Keys.LustReminderDump() end
    return
  end
  if cmd:sub(1, 8) == "lustscan" then
    local rest = cmd:match("lustscan%s+(%d+)")
    if Keys.LustReminderScan then Keys.LustReminderScan(rest) end
    return
  end
  if cmd == "lustunlock" then
    if Keys.LustReminderUnlock then Keys.LustReminderUnlock() end
    return
  end
  if cmd == "lustpresets" then
    if Keys.LustReminderDumpPresets then Keys.LustReminderDumpPresets() end
    return
  end
  print("|cff8fbf3fZugZug Keys|r — Mythic+ tools")
  print("  /zzk settings  — open the settings panel")
  print("  /zzk status    — show which features are on")
  print("  /zzk refresh   — re-fire the key-start broadcast for the current key")
  print("  /zzk forcebcast [text] — push text to BNet (works outside a key)")
  print("  /zzk testbcast — diagnose the BNet broadcast API")
  print("  /zzk hideinfo  — close the group key info box")
  print("  /zzk friends   — manually refresh the friends list overlay")
  print("  /zzk friendsdebug — diagnose what UI is exposing in your client")
  print("  /zzk lust      — show lust reminder status for current key")
  print("  /zzk lusttest  — fire a test lust alert")
  print("  /zzk lustscan [maxSet]  — sweep widget sets 1..maxSet (default 500) for the forces widget")
  print("  /zzk debug     — toggle verbose event logging")
end
