----------------------------------------------------------------------
-- ZugZug Keys — Settings Panel
-- Registered under "ZugZug Keys" in the Blizzard AddOns options. Each
-- feature is its own toggle; all default off.
----------------------------------------------------------------------

local Keys = _G.ZugZugKeys

local function CreateToggle(parent, x, y, label, dbKey, subtitle, onChange)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  cb.text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  cb.text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
  cb.text:SetText(label .. (subtitle and ("  |cff888888" .. subtitle .. "|r") or ""))
  cb:SetChecked(ZugZugKeysDB[dbKey])
  cb:SetScript("OnClick", function(self)
    ZugZugKeysDB[dbKey] = self:GetChecked()
    if onChange then onChange(self:GetChecked()) end
  end)
  return cb
end

local function CreateSettingsPanel()
  local canvas = CreateFrame("Frame", "ZugZugKeysSettingsPanel")
  canvas.name = "ZugZug Keys"

  local title = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("|cff8fbf3fZugZug|r Keys Settings")

  local sub = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  sub:SetText("Mythic+ tools and tweaks — each feature is off by default.")

  -- BNet status broadcast
  local bnToggle = CreateToggle(canvas, 16, -70, "BNet Status Broadcast", "bnStatus",
    "(updates your Battle.net custom message when a key starts)")

  local bnNote = canvas:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  bnNote:SetPoint("TOPLEFT", bnToggle, "BOTTOMLEFT", 4, -2)
  bnNote:SetText("|cff666666Posts once at key start with start/estimated finish time. Restores your previous message after the key ends.|r")

  -- Group key info
  local infoToggle = CreateToggle(canvas, 16, -130, "Group Key Info", "groupKeyInfo",
    "(small box showing group title + dungeon when you join via LFG)",
    function() if Keys.UpdateGroupKeyInfoFeature then Keys.UpdateGroupKeyInfoFeature() end end)

  local infoNote = canvas:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  infoNote:SetPoint("TOPLEFT", infoToggle, "BOTTOMLEFT", 4, -2)
  infoNote:SetText("|cff666666Stays open even after the group disbands until you enter that instance, or close it manually.|r")

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
  print("|cff8fbf3fZugZug Keys|r — Mythic+ tools")
  print("  /zzk settings  — open the settings panel")
  print("  /zzk status    — show which features are on")
  print("  /zzk refresh   — re-fire the key-start broadcast for the current key")
  print("  /zzk forcebcast [text] — push text to BNet (works outside a key)")
  print("  /zzk testbcast — diagnose the BNet broadcast API")
  print("  /zzk hideinfo  — close the group key info box")
  print("  /zzk friends   — manually refresh the friends list overlay")
  print("  /zzk friendsdebug — diagnose what UI is exposing in your client")
  print("  /zzk debug     — toggle verbose event logging")
end
