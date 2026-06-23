-- Gnomer Racer - Race + Scavenger Party Hunt v3
HomeLapTimerDB = HomeLapTimerDB or {}

local ADDON_PREFIX = "GNOMER1"
local frame = CreateFrame("Frame")

local running = false
local runLocked = false
local startTime = nil
local lastTriggerTime = 0
local currentSoftInteractGUID = nil

local huntRunning = false
local huntStartTime = nil
local huntIndex = 1
local selectedScavIndex = nil

local partyHuntRunning = false
local partyHuntOrder = {}
local partyHuntIndex = 1
local partyHuntScores = {}
local partyHuntHost = nil
local partyHuntCount = 6

local TRIGGER_COOLDOWN = 1.5
local MAX_LEADERBOARD = 5

local timerFrame
local configFrame

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00Gnomer Racer:|r " .. msg)
end

local function FormatTime(seconds)
    if not seconds then return "--.--" end
    return string.format("%.2f", seconds)
end

local function GetPlayerName()
    local name, realm = UnitFullName("player")
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name or "Unknown"
end

local function Trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function IsLikelyPlayerHousing()
    local zone = string.lower(GetRealZoneText() or "")
    local subzone = string.lower(GetSubZoneText() or "")
    local instanceName = string.lower((select(1, GetInstanceInfo())) or "")
    local text = zone .. " " .. subzone .. " " .. instanceName

    return text:find("housing")
        or text:find("house")
        or text:find("neighborhood")
        or text:find("home")
        or text:find("estate")
        or text:find("residence")
end

local function CreateBlankProfile(name)
    return {
        name = name,
        owner = nil,

        startObject = nil,
        finishObject = nil,
        lastLapTime = nil,
        bestLapTime = nil,
        leaderboard = {},

        scavObjects = {},
        scavLastTime = nil,
        scavBestTime = nil,
        scavLeaderboard = {},
    }
end

local function EnsureDB()
    HomeLapTimerDB.profiles = HomeLapTimerDB.profiles or {}

    if not HomeLapTimerDB.profiles["Default"] then
        HomeLapTimerDB.profiles["Default"] = CreateBlankProfile("Default")
    end

    HomeLapTimerDB.activeProfile = HomeLapTimerDB.activeProfile or "Default"
end

local function GetActiveProfileName()
    EnsureDB()
    return HomeLapTimerDB.activeProfile
end

local function GetProfile()
    EnsureDB()

    local name = HomeLapTimerDB.activeProfile
    HomeLapTimerDB.profiles[name] = HomeLapTimerDB.profiles[name] or CreateBlankProfile(name)

    local db = HomeLapTimerDB.profiles[name]
    db.leaderboard = db.leaderboard or {}
    db.scavObjects = db.scavObjects or {}
    db.scavLeaderboard = db.scavLeaderboard or {}

    return db
end

local function GetSortedProfileNames()
    EnsureDB()

    local names = {}
    for name in pairs(HomeLapTimerDB.profiles) do
        table.insert(names, name)
    end

    table.sort(names)
    return names
end

local function IsOwner()
    return GetProfile().owner == GetPlayerName()
end

local function HasOwner()
    local owner = GetProfile().owner
    return owner ~= nil and owner ~= ""
end

local function CanEdit()
    return not HasOwner() or IsOwner()
end

local function RequireOwner()
    if CanEdit() then return true end
    Print("Only the owner can edit this profile.")
    return false
end

local function CanTrigger()
    local now = GetTime()
    if now - lastTriggerTime < TRIGGER_COOLDOWN then return false end
    lastTriggerTime = now
    return true
end

local function SortBoard(board)
    table.sort(board, function(a, b)
        return (a.time or 999999) < (b.time or 999999)
    end)

    while #board > MAX_LEADERBOARD do
        table.remove(board)
    end
end

local function SerializeOrder(order)
    local parts = {}

    for _, obj in ipairs(order or {}) do
        table.insert(parts, tostring(obj.label or "Unnamed") .. "###" .. tostring(obj.guid or ""))
    end

    return table.concat(parts, "|||")
end

local function DeserializeOrder(text)
    local order = {}
    if not text or text == "" then return order end

    for item in string.gmatch(text, "([^|]+)") do
        local label, guid = strsplit("###", item)
        if label and guid then
            table.insert(order, { label = label, guid = guid })
        end
    end

    return order
end

local function SerializeScores(scores)
    local parts = {}

    for name, score in pairs(scores or {}) do
        table.insert(parts, tostring(name) .. "###" .. tostring(score))
    end

    return table.concat(parts, "|||")
end

local function DeserializeScores(text)
    local scores = {}
    if not text or text == "" then return scores end

    for item in string.gmatch(text, "([^|]+)") do
        local name, score = strsplit("###", item)
        if name and score then
            scores[name] = tonumber(score) or 0
        end
    end

    return scores
end

local function ShuffleObjects(objects)
    local copy = {}

    for _, obj in ipairs(objects or {}) do
        table.insert(copy, obj)
    end

    for i = #copy, 2, -1 do
        local j = math.random(i)
        copy[i], copy[j] = copy[j], copy[i]
    end

    return copy
end

local function StyleBackdrop(f)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })

    f:SetBackdropBorderColor(1, 0.82, 0, 1)
end

local function MakeMovable(f)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
end

local function AddWindowButtons(win, normalHeight, hiddenKey, minimizedKey, contentList)
    local closeBtn = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("TOPRIGHT", -6, -6)

    local minBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    minBtn:SetSize(24, 20)
    minBtn:SetPoint("RIGHT", closeBtn, "LEFT", -2, 0)
    minBtn:SetText("-")

    local function SetMinimized(minimized)
        HomeLapTimerDB[minimizedKey] = minimized

        if minimized then
            win:SetHeight(42)
            minBtn:SetText("+")
            for _, child in ipairs(contentList) do child:Hide() end
        else
            win:SetHeight(normalHeight)
            minBtn:SetText("-")
            for _, child in ipairs(contentList) do child:Show() end
        end
    end

    minBtn:SetScript("OnClick", function()
        SetMinimized(not HomeLapTimerDB[minimizedKey])
    end)

    closeBtn:SetScript("OnClick", function()
        win:Hide()
        HomeLapTimerDB[hiddenKey] = true
    end)

    win.SetHLTMinimized = SetMinimized
end

-- TIMER FRAME
timerFrame = CreateFrame("Frame", "GnomerRacerTimerFrame", UIParent, "BackdropTemplate")
timerFrame:SetSize(360, 330)
timerFrame:SetPoint("CENTER", UIParent, "CENTER", 300, 120)
MakeMovable(timerFrame)
StyleBackdrop(timerFrame)

local timerTitle = timerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
timerTitle:SetPoint("TOP", 0, -12)
timerTitle:SetText("Gnomer Racer")

local profileLabel = timerFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
profileLabel:SetPoint("TOP", 0, -32)
profileLabel:SetWidth(310)
profileLabel:SetText("Profile: Default")

local timerValue = timerFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightHuge")
timerValue:SetPoint("TOP", 0, -58)
timerValue:SetText("0.00")

local statusLabel = timerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
statusLabel:SetPoint("TOP", 0, -94)
statusLabel:SetText("Status: Ready")

local armButton = CreateFrame("Button", nil, timerFrame, "UIPanelButtonTemplate")
armButton:SetSize(220, 30)
armButton:SetPoint("TOP", 0, -120)
armButton:SetText("RESET / ARM NEXT RUN")

local lastLabel = timerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
lastLabel:SetPoint("TOPLEFT", 30, -158)
lastLabel:SetText("Last")

local bestLabel = timerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
bestLabel:SetPoint("TOPRIGHT", -30, -158)
bestLabel:SetText("Best")

local lastValue = timerFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
lastValue:SetPoint("TOPLEFT", 30, -176)
lastValue:SetText("--.--")

local bestValue = timerFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
bestValue:SetPoint("TOPRIGHT", -30, -176)
bestValue:SetText("--.--")

local lbTitle = timerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
lbTitle:SetPoint("TOP", 0, -205)
lbTitle:SetText("Top 5 Runs")

local lbRows = {}

for i = 1, MAX_LEADERBOARD do
    local row = timerFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row:SetPoint("TOPLEFT", 30, -228 - ((i - 1) * 14))
    row:SetWidth(300)
    row:SetJustifyH("LEFT")
    row:SetText(i .. ". --")
    lbRows[i] = row
end

local announceButton = CreateFrame("Button", nil, timerFrame, "UIPanelButtonTemplate")
announceButton:SetSize(140, 25)
announceButton:SetPoint("BOTTOMLEFT", 30, 16)
announceButton:SetText("Announce")

local clearLbButton = CreateFrame("Button", nil, timerFrame, "UIPanelButtonTemplate")
clearLbButton:SetSize(140, 25)
clearLbButton:SetPoint("BOTTOMRIGHT", -30, 16)
clearLbButton:SetText("Clear Board")

-- CONFIG FRAME
configFrame = CreateFrame("Frame", "GnomerRacerConfigFrame", UIParent, "BackdropTemplate")
configFrame:SetSize(520, 540)
configFrame:SetPoint("CENTER", UIParent, "CENTER", -280, 120)
MakeMovable(configFrame)
StyleBackdrop(configFrame)

local configTitle = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
configTitle:SetPoint("TOP", 0, -12)
configTitle:SetText("Gnomer Racer - Config")

local activeProfileLabel = configFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
activeProfileLabel:SetPoint("TOP", 0, -36)
activeProfileLabel:SetWidth(450)
activeProfileLabel:SetText("Active Profile: Default")

local ownerLabel = configFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
ownerLabel:SetPoint("TOP", 0, -56)
ownerLabel:SetWidth(450)
ownerLabel:SetText("Owner: Unclaimed")

-- PROFILE PANEL
local profilePanel = CreateFrame("Frame", nil, configFrame, "BackdropTemplate")
profilePanel:SetSize(470, 88)
profilePanel:SetPoint("TOP", 0, -82)
profilePanel:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
})
profilePanel:SetBackdropBorderColor(0.2, 0.65, 1, 1)

local profilePanelTitle = profilePanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
profilePanelTitle:SetPoint("TOPLEFT", 14, -10)
profilePanelTitle:SetText("Track Profile")

local profileNameBox = CreateFrame("EditBox", nil, profilePanel, "InputBoxTemplate")
profileNameBox:SetSize(165, 24)
profileNameBox:SetPoint("TOPLEFT", 18, -38)
profileNameBox:SetAutoFocus(false)

local createUseButton = CreateFrame("Button", nil, profilePanel, "UIPanelButtonTemplate")
createUseButton:SetSize(95, 24)
createUseButton:SetPoint("LEFT", profileNameBox, "RIGHT", 12, 0)
createUseButton:SetText("Create / Use")

local deleteProfileButton = CreateFrame("Button", nil, profilePanel, "UIPanelButtonTemplate")
deleteProfileButton:SetSize(70, 24)
deleteProfileButton:SetPoint("LEFT", createUseButton, "RIGHT", 8, 0)
deleteProfileButton:SetText("Delete")

local detailsButton = CreateFrame("Button", nil, profilePanel, "UIPanelButtonTemplate")
detailsButton:SetSize(70, 24)
detailsButton:SetPoint("LEFT", deleteProfileButton, "RIGHT", 8, 0)
detailsButton:SetText("Details")

local profilesListLabel = profilePanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
profilesListLabel:SetPoint("TOPLEFT", 18, -66)
profilesListLabel:SetWidth(430)
profilesListLabel:SetJustifyH("LEFT")
profilesListLabel:SetText("Profiles: Default")

-- TABS
local raceTab = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
raceTab:SetSize(115, 26)
raceTab:SetPoint("TOPLEFT", 38, -184)
raceTab:SetText("Race")

local scavSetupTab = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
scavSetupTab:SetSize(140, 26)
scavSetupTab:SetPoint("LEFT", raceTab, "RIGHT", 8, 0)
scavSetupTab:SetText("Scavenger Setup")

local scavPlayTab = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
scavPlayTab:SetSize(140, 26)
scavPlayTab:SetPoint("LEFT", scavSetupTab, "RIGHT", 8, 0)
scavPlayTab:SetText("Scavenger Play")

local racePage = CreateFrame("Frame", nil, configFrame)
racePage:SetSize(450, 300)
racePage:SetPoint("TOP", 0, -222)

local scavSetupPage = CreateFrame("Frame", nil, configFrame)
scavSetupPage:SetSize(450, 300)
scavSetupPage:SetPoint("TOP", 0, -222)

local scavPlayPage = CreateFrame("Frame", nil, configFrame)
scavPlayPage:SetSize(450, 300)
scavPlayPage:SetPoint("TOP", 0, -222)

local function ShowTab(tab)
    racePage:Hide()
    scavSetupPage:Hide()
    scavPlayPage:Hide()

    raceTab:SetText("Race")
    scavSetupTab:SetText("Scavenger Setup")
    scavPlayTab:SetText("Scavenger Play")

    if tab == "race" then
        racePage:Show()
        raceTab:SetText("* Race *")
    elseif tab == "setup" then
        scavSetupPage:Show()
        scavSetupTab:SetText("* Scavenger Setup *")
    else
        scavPlayPage:Show()
        scavPlayTab:SetText("* Scavenger Play *")
    end
end

raceTab:SetScript("OnClick", function() ShowTab("race") end)
scavSetupTab:SetScript("OnClick", function() ShowTab("setup") end)
scavPlayTab:SetScript("OnClick", function() ShowTab("play") end)

-- RACE PAGE
local function CreateCleanCard(parent, y, titleText, buttonText, color)
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:SetSize(430, 64)
    card:SetPoint("TOP", 0, y)
    card:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    card:SetBackdropBorderColor(color[1], color[2], color[3], 1)

    local title = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -10)
    title:SetText(titleText)
    title:SetTextColor(color[1], color[2], color[3])

    local status = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    status:SetPoint("TOPLEFT", 16, -34)
    status:SetText("NOT SET")

    local btn = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
    btn:SetSize(115, 30)
    btn:SetPoint("RIGHT", -14, 0)
    btn:SetText(buttonText)

    return { frame = card, status = status, button = btn }
end

local startCard = CreateCleanCard(racePage, -5, "Start Object", "Set Start", {0.2, 1, 0.2})
local finishCard = CreateCleanCard(racePage, -78, "Finish Object", "Set Finish", {1, 0.25, 0.25})

local claimOwnerButton = CreateFrame("Button", nil, racePage, "UIPanelButtonTemplate")
claimOwnerButton:SetSize(130, 28)
claimOwnerButton:SetPoint("BOTTOMLEFT", 10, 10)
claimOwnerButton:SetText("Claim Owner")

local releaseOwnerButton = CreateFrame("Button", nil, racePage, "UIPanelButtonTemplate")
releaseOwnerButton:SetSize(130, 28)
releaseOwnerButton:SetPoint("LEFT", claimOwnerButton, "RIGHT", 10, 0)
releaseOwnerButton:SetText("Release Owner")

local clearConfigButton = CreateFrame("Button", nil, racePage, "UIPanelButtonTemplate")
clearConfigButton:SetSize(140, 28)
clearConfigButton:SetPoint("LEFT", releaseOwnerButton, "RIGHT", 10, 0)
clearConfigButton:SetText("Clear Objects")

-- SCAVENGER SETUP PAGE
local scavLabelBox = CreateFrame("EditBox", nil, scavSetupPage, "InputBoxTemplate")
scavLabelBox:SetSize(210, 24)
scavLabelBox:SetPoint("TOPLEFT", 20, -10)
scavLabelBox:SetAutoFocus(false)

local scavLabelText = scavSetupPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
scavLabelText:SetPoint("BOTTOMLEFT", scavLabelBox, "TOPLEFT", 0, 2)
scavLabelText:SetText("Object Label")

local addScavButton = CreateFrame("Button", nil, scavSetupPage, "UIPanelButtonTemplate")
addScavButton:SetSize(90, 26)
addScavButton:SetPoint("LEFT", scavLabelBox, "RIGHT", 10, 0)
addScavButton:SetText("Add")

local renameScavButton = CreateFrame("Button", nil, scavSetupPage, "UIPanelButtonTemplate")
renameScavButton:SetSize(90, 26)
renameScavButton:SetPoint("LEFT", addScavButton, "RIGHT", 8, 0)
renameScavButton:SetText("Rename")

local deleteScavButton = CreateFrame("Button", nil, scavSetupPage, "UIPanelButtonTemplate")
deleteScavButton:SetSize(90, 24)
deleteScavButton:SetPoint("TOPLEFT", scavLabelBox, "BOTTOMLEFT", 0, -8)
deleteScavButton:SetText("Delete")

local clearScavButton = CreateFrame("Button", nil, scavSetupPage, "UIPanelButtonTemplate")
clearScavButton:SetSize(90, 24)
clearScavButton:SetPoint("LEFT", deleteScavButton, "RIGHT", 8, 0)
clearScavButton:SetText("Clear")

local selectedScavText = scavSetupPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
selectedScavText:SetPoint("TOPLEFT", 20, -68)
selectedScavText:SetWidth(420)
selectedScavText:SetJustifyH("LEFT")
selectedScavText:SetText("Selected: --")

local scavListTitle = scavSetupPage:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
scavListTitle:SetPoint("TOPLEFT", 20, -92)
scavListTitle:SetText("Ordered Hunt Objects")

local scavRows = {}

local RefreshConfigUI
local RefreshHuntDisplay

for i = 1, 8 do
    local btn = CreateFrame("Button", nil, scavSetupPage)
    btn:SetSize(405, 16)
    btn:SetPoint("TOPLEFT", 24, -116 - ((i - 1) * 16))

    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetAllPoints()
    text:SetJustifyH("LEFT")
    text:SetText(i .. ". --")

    btn.text = text
    btn.index = i

    btn:SetScript("OnClick", function(self)
        local db = GetProfile()

        if db.scavObjects and db.scavObjects[self.index] then
            selectedScavIndex = self.index
            scavLabelBox:SetText(db.scavObjects[self.index].label or "")

            if RefreshConfigUI then
                RefreshConfigUI()
            end
        end
    end)

    scavRows[i] = btn
end

-- SCAVENGER PLAY PAGE
local huntTitle = scavPlayPage:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
huntTitle:SetPoint("TOP", 0, -8)
huntTitle:SetText("Ordered / Party Scavenger Hunt")

local huntTargetText = scavPlayPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightHuge")
huntTargetText:SetPoint("TOP", 0, -40)
huntTargetText:SetText("Target: --")

local huntProgressText = scavPlayPage:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
huntProgressText:SetPoint("TOP", 0, -82)
huntProgressText:SetText("Progress: 0 / 0")

local startHuntButton = CreateFrame("Button", nil, scavPlayPage, "UIPanelButtonTemplate")
startHuntButton:SetSize(120, 30)
startHuntButton:SetPoint("TOPLEFT", 84, -120)
startHuntButton:SetText("Start Solo")

local resetHuntButton = CreateFrame("Button", nil, scavPlayPage, "UIPanelButtonTemplate")
resetHuntButton:SetSize(120, 30)
resetHuntButton:SetPoint("LEFT", startHuntButton, "RIGHT", 20, 0)
resetHuntButton:SetText("Reset Hunt")

local huntCountBox = CreateFrame("EditBox", nil, scavPlayPage, "InputBoxTemplate")
huntCountBox:SetSize(50, 24)
huntCountBox:SetPoint("TOPLEFT", 90, -165)
huntCountBox:SetAutoFocus(false)
huntCountBox:SetText("6")

local huntCountLabel = scavPlayPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
huntCountLabel:SetPoint("RIGHT", huntCountBox, "LEFT", -8, 0)
huntCountLabel:SetText("Count")

local startPartyHuntButton = CreateFrame("Button", nil, scavPlayPage, "UIPanelButtonTemplate")
startPartyHuntButton:SetSize(150, 26)
startPartyHuntButton:SetPoint("LEFT", huntCountBox, "RIGHT", 14, 0)
startPartyHuntButton:SetText("Start Party Hunt")

local huntBestText = scavPlayPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
huntBestText:SetPoint("TOP", 0, -202)
huntBestText:SetText("Best Solo Hunt: --.--")

local partyScoreText = scavPlayPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
partyScoreText:SetPoint("TOPLEFT", 20, -230)
partyScoreText:SetWidth(410)
partyScoreText:SetJustifyH("LEFT")
partyScoreText:SetText("Party Scores: --")

local timerContent = {
    profileLabel, timerValue, statusLabel, armButton,
    lastLabel, bestLabel, lastValue, bestValue, lbTitle,
    lbRows[1], lbRows[2], lbRows[3], lbRows[4], lbRows[5],
    announceButton, clearLbButton
}

local configContent = {
    activeProfileLabel, ownerLabel, profilePanel,
    raceTab, scavSetupTab, scavPlayTab,
    racePage, scavSetupPage, scavPlayPage
}

AddWindowButtons(timerFrame, 330, "hidden", "timerMinimized", timerContent)
AddWindowButtons(configFrame, 540, "configHidden", "configMinimized", configContent)

local function RefreshRaceLeaderboard()
    local db = GetProfile()
    SortBoard(db.leaderboard)

    for i = 1, MAX_LEADERBOARD do
        local entry = db.leaderboard[i]

        if entry then
            lbRows[i]:SetText(string.format("%d. %s - %.2f", i, entry.name or "Unknown", entry.time or 0))
        else
            lbRows[i]:SetText(i .. ". --")
        end
    end
end

local function RefreshScavList()
    local db = GetProfile()
    db.scavObjects = db.scavObjects or {}

    if selectedScavIndex and not db.scavObjects[selectedScavIndex] then
        selectedScavIndex = nil
    end

    for i = 1, 8 do
        local obj = db.scavObjects[i]

        if obj then
            if selectedScavIndex == i then
                scavRows[i].text:SetText(string.format("|cffffff00>> %d. %s <<|r", i, obj.label or "Unnamed"))
            else
                scavRows[i].text:SetText(string.format("%d. %s", i, obj.label or "Unnamed"))
            end
        else
            scavRows[i].text:SetText(i .. ". --")
        end
    end

    if selectedScavIndex and db.scavObjects[selectedScavIndex] then
        selectedScavText:SetText("Selected: " .. selectedScavIndex .. ". " .. tostring(db.scavObjects[selectedScavIndex].label or "Unnamed"))
    else
        selectedScavText:SetText("Selected: --")
    end
end

local function RefreshProfilesUI()
    profilesListLabel:SetText("Profiles: " .. table.concat(GetSortedProfileNames(), "  |  "))
end

RefreshHuntDisplay = function()
    local db = GetProfile()
    local total = #(db.scavObjects or {})
    local currentObj = db.scavObjects and db.scavObjects[huntIndex]

    if partyHuntRunning then
        total = #(partyHuntOrder or {})
        currentObj = partyHuntOrder[partyHuntIndex]
    end

    if partyHuntRunning and currentObj then
        huntTargetText:SetText("Target: " .. (currentObj.label or "Unnamed"))
        huntProgressText:SetText(string.format("Progress: %d / %d", math.max(partyHuntIndex - 1, 0), total))
    elseif huntRunning and currentObj then
        huntTargetText:SetText("Target: " .. (currentObj.label or "Unnamed"))
        huntProgressText:SetText(string.format("Progress: %d / %d", math.max(huntIndex - 1, 0), total))
    elseif total == 0 then
        huntTargetText:SetText("Target: No objects saved")
        huntProgressText:SetText("Progress: 0 / 0")
    else
        huntTargetText:SetText("Target: --")
        huntProgressText:SetText(string.format("Progress: 0 / %d", total))
    end

    huntBestText:SetText("Best Solo Hunt: " .. FormatTime(db.scavBestTime))

    if partyHuntRunning or next(partyHuntScores or {}) then
        local scoreParts = {}
        for name, score in pairs(partyHuntScores or {}) do
            table.insert(scoreParts, name .. ": " .. tostring(score))
        end
        table.sort(scoreParts)
        partyScoreText:SetText("Party Scores: " .. table.concat(scoreParts, "  |  "))
    else
        partyScoreText:SetText("Party Scores: --")
    end
end

RefreshConfigUI = function()
    local db = GetProfile()
    local activeName = GetActiveProfileName()

    profileLabel:SetText("Profile: " .. activeName)
    activeProfileLabel:SetText("Active Profile: " .. activeName)

    if db.owner then
        if IsOwner() then
            ownerLabel:SetText("|cff00ff00Owner: " .. db.owner .. " (You)|r")
        else
            ownerLabel:SetText("|cffff4040Owner: " .. db.owner .. "|r")
        end
    else
        ownerLabel:SetText("|cffffff00Owner: Unclaimed|r")
    end

    startCard.status:SetText(db.startObject and "|cff00ff00READY|r" or "|cffff4040NOT SET|r")
    finishCard.status:SetText(db.finishObject and "|cff00ff00READY|r" or "|cffff4040NOT SET|r")

    if CanEdit() then
        startCard.button:Enable()
        finishCard.button:Enable()
        releaseOwnerButton:Enable()
        clearConfigButton:Enable()
        clearLbButton:Enable()
        addScavButton:Enable()
        renameScavButton:Enable()
        deleteScavButton:Enable()
        clearScavButton:Enable()
    else
        startCard.button:Disable()
        finishCard.button:Disable()
        releaseOwnerButton:Disable()
        clearConfigButton:Disable()
        clearLbButton:Disable()
        addScavButton:Disable()
        renameScavButton:Disable()
        deleteScavButton:Disable()
        clearScavButton:Disable()
    end

    if HasOwner() then
        claimOwnerButton:Disable()
    else
        claimOwnerButton:Enable()
    end

    RefreshProfilesUI()
    RefreshRaceLeaderboard()
    RefreshScavList()
    RefreshHuntDisplay()
end

local function UpdateTimerDisplay()
    local db = GetProfile()
    local current = 0

    if running and startTime then
        current = GetTime() - startTime
    end

    timerValue:SetText(FormatTime(current))
    lastValue:SetText(FormatTime(db.lastLapTime))
    bestValue:SetText(FormatTime(db.bestLapTime))

    if running then
        statusLabel:SetText("Status: Running")
        timerValue:SetTextColor(0.2, 1, 0.2)
    elseif runLocked then
        statusLabel:SetText("Status: Finished - Reset to arm")
        timerValue:SetTextColor(1, 0.82, 0)
    else
        statusLabel:SetText("Status: Ready")
        timerValue:SetTextColor(0.85, 0.85, 0.85)
    end

    RefreshHuntDisplay()
end

local function StopAllRuns()
    running = false
    runLocked = false
    startTime = nil

    huntRunning = false
    huntStartTime = nil
    huntIndex = 1

    partyHuntRunning = false
    partyHuntOrder = {}
    partyHuntIndex = 1
    partyHuntScores = {}
    partyHuntHost = nil
end

local function UpdateHousingVisibility()
    if not timerFrame or not configFrame then return end

    local inHousing = IsLikelyPlayerHousing()

    if inHousing then
        if not HomeLapTimerDB.hidden then
            timerFrame:Show()
        end

        if not HomeLapTimerDB.configHidden then
            configFrame:Show()
        end
    else
        timerFrame:Hide()
        configFrame:Hide()
        StopAllRuns()
    end

    UpdateTimerDisplay()
end

local function ForceUIVisible()
    timerFrame:ClearAllPoints()
    timerFrame:SetPoint("CENTER", UIParent, "CENTER", 300, 120)
    timerFrame:Show()

    configFrame:ClearAllPoints()
    configFrame:SetPoint("CENTER", UIParent, "CENTER", -280, 120)
    configFrame:Show()

    HomeLapTimerDB.hidden = false
    HomeLapTimerDB.configHidden = false
    HomeLapTimerDB.timerMinimized = false
    HomeLapTimerDB.configMinimized = false

    timerFrame.SetHLTMinimized(false)
    configFrame.SetHLTMinimized(false)

    Print("UI reset and shown.")
end

-- PROFILE ACTIONS
createUseButton:SetScript("OnClick", function()
    local name = Trim(profileNameBox:GetText())

    if name == "" then
        Print("Enter a profile name first.")
        return
    end

    EnsureDB()

    if not HomeLapTimerDB.profiles[name] then
        HomeLapTimerDB.profiles[name] = CreateBlankProfile(name)
        Print("Created profile: " .. name)
    else
        Print("Switched to profile: " .. name)
    end

    HomeLapTimerDB.activeProfile = name
    StopAllRuns()
    selectedScavIndex = nil

    RefreshConfigUI()
    UpdateTimerDisplay()
end)

deleteProfileButton:SetScript("OnClick", function()
    EnsureDB()

    local active = GetActiveProfileName()

    if active == "Default" then
        Print("Cannot delete Default profile.")
        return
    end

    HomeLapTimerDB.profiles[active] = nil
    HomeLapTimerDB.activeProfile = "Default"

    StopAllRuns()
    selectedScavIndex = nil

    Print("Deleted profile: " .. active)

    RefreshConfigUI()
    UpdateTimerDisplay()
end)

detailsButton:SetScript("OnClick", function()
    local db = GetProfile()

    Print("Profile: " .. GetActiveProfileName())
    Print("Owner: " .. tostring(db.owner or "Unclaimed"))
    Print("Start GUID: " .. tostring(db.startObject))
    Print("Finish GUID: " .. tostring(db.finishObject))
    Print("Scavenger objects: " .. tostring(#(db.scavObjects or {})))
    Print("Zone text: " .. tostring(GetRealZoneText()) .. " / " .. tostring(GetSubZoneText()) .. " / " .. tostring((select(1, GetInstanceInfo()))))
    Print("Detected housing: " .. tostring(IsLikelyPlayerHousing()))
end)

-- RACE LEADERBOARD
local function AddRaceTime(playerName, lapTime, fromNetwork)
    local db = GetProfile()

    table.insert(db.leaderboard, {
        name = playerName,
        time = lapTime,
        updated = time()
    })

    SortBoard(db.leaderboard)
    RefreshRaceLeaderboard()

    if not fromNetwork then
        Print(string.format("Leaderboard updated: %s - %.2f", playerName, lapTime))
    end
end

local function GetAnnounceChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return "SAY"
end

local function AnnounceRaceLeaderboard()
    local db = GetProfile()
    local channel = GetAnnounceChannel()

    SendChatMessage("Gnomer Racer - " .. GetActiveProfileName() .. " Top 5:", channel)

    if not db.leaderboard or #db.leaderboard == 0 then
        SendChatMessage("No times recorded yet.", channel)
        return
    end

    SortBoard(db.leaderboard)

    for i = 1, MAX_LEADERBOARD do
        local entry = db.leaderboard[i]

        if entry then
            SendChatMessage(string.format("%d. %s - %.2f sec", i, entry.name or "Unknown", entry.time or 0), channel)
        end
    end
end

local function ClearRaceLeaderboard()
    if not RequireOwner() then return end

    local db = GetProfile()
    db.leaderboard = {}

    Print("Race leaderboard cleared.")
    RefreshRaceLeaderboard()
end

announceButton:SetScript("OnClick", AnnounceRaceLeaderboard)
clearLbButton:SetScript("OnClick", ClearRaceLeaderboard)

local function SendPartyAddonMessage(msg)
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        C_ChatInfo.SendAddonMessage(ADDON_PREFIX, msg, "INSTANCE_CHAT")
    elseif IsInRaid() then
        C_ChatInfo.SendAddonMessage(ADDON_PREFIX, msg, "RAID")
    elseif IsInGroup() then
        C_ChatInfo.SendAddonMessage(ADDON_PREFIX, msg, "PARTY")
    end
end

local function BroadcastPartyHuntState()
    local msg = "SCAV_STATE\t"
        .. GetActiveProfileName() .. "\t"
        .. tostring(partyHuntIndex) .. "\t"
        .. SerializeScores(partyHuntScores)

    SendPartyAddonMessage(msg)
end

local function BroadcastRaceTime(lapTime)
    local msg = "RACE\t" .. GetActiveProfileName() .. "\t" .. GetPlayerName() .. "\t" .. string.format("%.3f", lapTime)
    SendPartyAddonMessage(msg)
end

local function AnnouncePartyHuntFound(playerName, itemName, score)
    SendChatMessage(playerName .. ' found "' .. tostring(itemName) .. '"! Total score: ' .. tostring(score), GetAnnounceChannel())
end

local function AnnouncePartyHuntFinal()
    local results = {}

    for name, score in pairs(partyHuntScores or {}) do
        table.insert(results, { name = name, score = score })
    end

    table.sort(results, function(a, b)
        return (a.score or 0) > (b.score or 0)
    end)

    if #results == 0 then
        SendChatMessage("Gnomer Racer hunt finished. No points scored.", GetAnnounceChannel())
        return
    end

    local winner = results[1]
    SendChatMessage(winner.name .. " won the Gnomer Racer hunt with " .. winner.score .. " points!", GetAnnounceChannel())

    for _, entry in ipairs(results) do
        SendChatMessage(entry.name .. " finished with " .. entry.score .. " points.", GetAnnounceChannel())
    end
end

-- CONFIG SAVE
local function SaveCurrentObject(slotName)
    if not RequireOwner() then return end

    local db = GetProfile()

    if not currentSoftInteractGUID then
        Print("No interactable object detected. Hover the object first.")
        return
    end

    if slotName == "start" then
        db.startObject = currentSoftInteractGUID
        Print("Start object saved.")
    elseif slotName == "finish" then
        db.finishObject = currentSoftInteractGUID
        Print("Finish object saved.")
    end

    RefreshConfigUI()
end

startCard.button:SetScript("OnClick", function() SaveCurrentObject("start") end)
finishCard.button:SetScript("OnClick", function() SaveCurrentObject("finish") end)

claimOwnerButton:SetScript("OnClick", function()
    local db = GetProfile()

    if HasOwner() then
        Print("Owner already set: " .. tostring(db.owner))
        return
    end

    db.owner = GetPlayerName()

    Print("You claimed owner.")
    RefreshConfigUI()
end)

releaseOwnerButton:SetScript("OnClick", function()
    local db = GetProfile()

    if not IsOwner() then
        Print("Only the owner can release ownership.")
        return
    end

    db.owner = nil

    Print("Owner released.")
    RefreshConfigUI()
end)

clearConfigButton:SetScript("OnClick", function()
    if not RequireOwner() then return end

    local db = GetProfile()
    db.startObject = nil
    db.finishObject = nil

    Print("Start/finish cleared.")
    RefreshConfigUI()
end)

-- SCAVENGER SETUP
addScavButton:SetScript("OnClick", function()
    if not RequireOwner() then return end

    local db = GetProfile()
    local label = Trim(scavLabelBox:GetText())

    if label == "" then
        Print("Enter an object label first.")
        return
    end

    if not currentSoftInteractGUID then
        Print("No interactable object detected. Hover the object first.")
        return
    end

    table.insert(db.scavObjects, {
        label = label,
        guid = currentSoftInteractGUID,
    })

    selectedScavIndex = #db.scavObjects
    scavLabelBox:SetText(label)

    Print("Added scavenger object: " .. label)
    RefreshConfigUI()
end)

renameScavButton:SetScript("OnClick", function()
    if not RequireOwner() then return end

    local db = GetProfile()
    local label = Trim(scavLabelBox:GetText())

    if not selectedScavIndex or not db.scavObjects[selectedScavIndex] then
        Print("Select a scavenger item first.")
        return
    end

    if label == "" then
        Print("Enter a new label first.")
        return
    end

    db.scavObjects[selectedScavIndex].label = label

    Print("Renamed scavenger item to: " .. label)
    RefreshConfigUI()
end)

deleteScavButton:SetScript("OnClick", function()
    if not RequireOwner() then return end

    local db = GetProfile()

    if not selectedScavIndex or not db.scavObjects[selectedScavIndex] then
        Print("Select a scavenger item first.")
        return
    end

    local removed = table.remove(db.scavObjects, selectedScavIndex)

    Print("Deleted scavenger item: " .. tostring(removed.label or "Unnamed"))

    selectedScavIndex = nil
    scavLabelBox:SetText("")

    huntRunning = false
    huntStartTime = nil
    huntIndex = 1

    partyHuntRunning = false
    partyHuntOrder = {}
    partyHuntIndex = 1
    partyHuntScores = {}
    partyHuntHost = nil

    RefreshConfigUI()
end)

clearScavButton:SetScript("OnClick", function()
    if not RequireOwner() then return end

    local db = GetProfile()
    db.scavObjects = {}

    selectedScavIndex = nil
    scavLabelBox:SetText("")

    huntRunning = false
    huntStartTime = nil
    huntIndex = 1

    partyHuntRunning = false
    partyHuntOrder = {}
    partyHuntIndex = 1
    partyHuntScores = {}
    partyHuntHost = nil

    Print("Scavenger objects cleared.")
    RefreshConfigUI()
end)

-- TIMER LOGIC
local function ArmNextRun()
    running = false
    runLocked = false
    startTime = nil

    Print("Timer reset. Start object is armed again.")
    UpdateTimerDisplay()
end

armButton:SetScript("OnClick", ArmNextRun)

local function StartRun()
    if runLocked then
        Print("Run is locked after finish. Click RESET / ARM NEXT RUN.")
        return
    end

    running = true
    startTime = GetTime()

    Print("Run started.")
    UpdateTimerDisplay()
end

local function FinishRun()
    if not running or not startTime then return end

    local db = GetProfile()
    local lapTime = GetTime() - startTime

    running = false
    runLocked = true
    startTime = nil

    db.lastLapTime = lapTime

    if not db.bestLapTime or lapTime < db.bestLapTime then
        db.bestLapTime = lapTime
        Print(string.format("Finished! %.2f sec | NEW BEST!", lapTime))
    else
        Print(string.format("Finished! %.2f sec | Best: %.2f sec", lapTime, db.bestLapTime))
    end

    AddRaceTime(GetPlayerName(), lapTime, false)
    BroadcastRaceTime(lapTime)

    Print("Timer locked. Click RESET / ARM NEXT RUN when ready.")

    RefreshRaceLeaderboard()
    UpdateTimerDisplay()
end

local function ForceStop()
    running = false
    startTime = nil

    Print("Run stopped.")
    UpdateTimerDisplay()
end

-- HUNT LOGIC
local function StartHunt()
    local db = GetProfile()

    if #(db.scavObjects or {}) == 0 then
        Print("No scavenger objects saved.")
        return
    end

    partyHuntRunning = false
    partyHuntOrder = {}
    partyHuntIndex = 1
    partyHuntScores = {}
    partyHuntHost = nil

    huntRunning = true
    huntStartTime = GetTime()
    huntIndex = 1

    Print("Solo scavenger hunt started. Find: " .. tostring(db.scavObjects[1].label))
    RefreshHuntDisplay()
end

local function ResetHunt()
    huntRunning = false
    huntStartTime = nil
    huntIndex = 1

    partyHuntRunning = false
    partyHuntOrder = {}
    partyHuntIndex = 1
    partyHuntScores = {}
    partyHuntHost = nil

    Print("Scavenger hunt reset.")
    RefreshHuntDisplay()
end

local function FinishHunt()
    local db = GetProfile()
    local huntTime = GetTime() - huntStartTime

    huntRunning = false
    huntStartTime = nil
    huntIndex = 1

    db.scavLastTime = huntTime

    if not db.scavBestTime or huntTime < db.scavBestTime then
        db.scavBestTime = huntTime
        Print(string.format("Solo hunt complete! %.2f sec | NEW BEST!", huntTime))
    else
        Print(string.format("Solo hunt complete! %.2f sec | Best: %.2f sec", huntTime, db.scavBestTime))
    end

    table.insert(db.scavLeaderboard, {
        name = GetPlayerName(),
        time = huntTime,
        updated = time(),
    })

    SortBoard(db.scavLeaderboard)
    RefreshHuntDisplay()
end

local function StartPartyHunt()
    local db = GetProfile()
    local objects = db.scavObjects or {}

    if #objects == 0 then
        Print("No scavenger objects saved.")
        return
    end

    local count = tonumber(huntCountBox:GetText()) or 6
    if count < 1 then count = 1 end
    if count > #objects then count = #objects end

    partyHuntCount = count
    partyHuntOrder = ShuffleObjects(objects)

    while #partyHuntOrder > count do
        table.remove(partyHuntOrder)
    end

    partyHuntRunning = true
    partyHuntIndex = 1
    partyHuntScores = {}
    partyHuntHost = GetPlayerName()

    huntRunning = true
    huntStartTime = GetTime()
    huntIndex = 1

    local msg = "SCAV_START\t"
        .. GetActiveProfileName() .. "\t"
        .. partyHuntHost .. "\t"
        .. SerializeOrder(partyHuntOrder)

    SendPartyAddonMessage(msg)

    Print("Party hunt started. Find: " .. tostring(partyHuntOrder[1].label))
    ShowTab("play")
    configFrame:Show()
    HomeLapTimerDB.configHidden = false
    RefreshHuntDisplay()
end

startHuntButton:SetScript("OnClick", StartHunt)
resetHuntButton:SetScript("OnClick", ResetHunt)
startPartyHuntButton:SetScript("OnClick", StartPartyHunt)

local function AdvancePartyHunt(finderName, sentScore)
    if not partyHuntRunning then return end

    local foundObj = partyHuntOrder and partyHuntOrder[partyHuntIndex]
    if not foundObj then return end

    if sentScore then
        partyHuntScores[finderName] = sentScore
    else
        partyHuntScores[finderName] = (partyHuntScores[finderName] or 0) + 1
    end

    local newScore = partyHuntScores[finderName] or 0

    Print(tostring(finderName) .. " found: " .. tostring(foundObj.label))
    AnnouncePartyHuntFound(finderName, foundObj.label, newScore)

    partyHuntIndex = partyHuntIndex + 1

    if partyHuntIndex > #(partyHuntOrder or {}) then
        Print("Party hunt complete!")
        AnnouncePartyHuntFinal()
        partyHuntRunning = false
        huntRunning = false
        huntStartTime = nil
    else
        Print("Next: " .. tostring(partyHuntOrder[partyHuntIndex].label))
    end

    BroadcastPartyHuntState()
    RefreshHuntDisplay()
end

local function HandleHuntClick()
    if partyHuntRunning then
        local target = partyHuntOrder and partyHuntOrder[partyHuntIndex]
        if not target then return false end

        if currentSoftInteractGUID == target.guid then
            local playerName = GetPlayerName()
            local nextScore = (partyHuntScores[playerName] or 0) + 1

            local msg = "SCAV_FOUND\t"
                .. GetActiveProfileName() .. "\t"
                .. playerName .. "\t"
                .. tostring(nextScore)

            SendPartyAddonMessage(msg)
            AdvancePartyHunt(playerName, nextScore)
            return true
        end

        return false
    end

    if not huntRunning or not huntStartTime then return false end

    local db = GetProfile()
    local target = db.scavObjects and db.scavObjects[huntIndex]

    if not target then return false end

    if currentSoftInteractGUID == target.guid then
        Print("Found: " .. tostring(target.label))

        huntIndex = huntIndex + 1

        if huntIndex > #(db.scavObjects or {}) then
            FinishHunt()
        else
            Print("Next: " .. tostring(db.scavObjects[huntIndex].label))
            RefreshHuntDisplay()
        end

        return true
    end

    return false
end

local function HandleDoorClick()
    if not IsLikelyPlayerHousing() then return end

    local db = GetProfile()

    if not currentSoftInteractGUID then return end
    if not CanTrigger() then return end

    if HandleHuntClick() then return end

    if runLocked then return end

    if currentSoftInteractGUID == db.startObject then
        if not running then StartRun() end
    elseif currentSoftInteractGUID == db.finishObject then
        if running then FinishRun() end
    end
end

-- ADDON MESSAGE
local function HandleAddonMessage(prefix, msg)
    if prefix ~= ADDON_PREFIX then return end

    local kind, profileName, a, b, c = strsplit("\t", msg)

    if kind == "RACE" then
        if profileName ~= GetActiveProfileName() then return end

        local playerName = a
        local t = tonumber(b)
        if not t then return end

        AddRaceTime(playerName, t, true)
        Print(string.format("Received race time: %s - %.2f", playerName, t))
        return
    end

    if kind == "SCAV_START" then
        local hostName = a
        local orderText = b

        if profileName and profileName ~= "" then
            if not HomeLapTimerDB.profiles[profileName] then
                HomeLapTimerDB.profiles[profileName] = CreateBlankProfile(profileName)
            end
            HomeLapTimerDB.activeProfile = profileName
        end

        partyHuntHost = hostName
        partyHuntOrder = DeserializeOrder(orderText)
        partyHuntIndex = 1
        partyHuntScores = {}
        partyHuntRunning = true

        huntRunning = true
        huntStartTime = GetTime()
        huntIndex = 1

        if partyHuntOrder[1] then
            Print("Party hunt started by " .. tostring(hostName) .. ". Find: " .. tostring(partyHuntOrder[1].label))
        else
            Print("Party hunt started, but no objects were received.")
        end

        ShowTab("play")
        configFrame:Show()
        HomeLapTimerDB.configHidden = false

        RefreshConfigUI()
        RefreshHuntDisplay()
        return
    end

    if kind == "SCAV_FOUND" then
        if profileName ~= GetActiveProfileName() then return end

        local finderName = a
        local sentScore = tonumber(b)

        AdvancePartyHunt(finderName, sentScore)
        return
    end

    if kind == "SCAV_STATE" then
        if profileName ~= GetActiveProfileName() then return end

        local index = tonumber(a)
        local scoresText = b

        if index then
            partyHuntIndex = index
        end

        partyHuntScores = DeserializeScores(scoresText)
        RefreshHuntDisplay()
        return
    end
end

-- EVENTS
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_SOFT_INTERACT_CHANGED")
frame:RegisterEvent("GLOBAL_MOUSE_DOWN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("ZONE_CHANGED")
frame:RegisterEvent("ZONE_CHANGED_INDOORS")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
        EnsureDB()

        if HomeLapTimerDB.hidden == nil then HomeLapTimerDB.hidden = false end
        if HomeLapTimerDB.configHidden == nil then HomeLapTimerDB.configHidden = false end
        if HomeLapTimerDB.timerMinimized == nil then HomeLapTimerDB.timerMinimized = false end
        if HomeLapTimerDB.configMinimized == nil then HomeLapTimerDB.configMinimized = false end

        if HomeLapTimerDB.hidden then timerFrame:Hide() else timerFrame:Show() end
        if HomeLapTimerDB.configHidden then configFrame:Hide() else configFrame:Show() end

        timerFrame.SetHLTMinimized(HomeLapTimerDB.timerMinimized)
        configFrame.SetHLTMinimized(HomeLapTimerDB.configMinimized)

        ShowTab("race")
        RefreshConfigUI()
        UpdateTimerDisplay()

        C_Timer.After(1, UpdateHousingVisibility)

        Print("Loaded. Party scavenger hunt active.")
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        EnsureDB()
        StopAllRuns()
        RefreshConfigUI()
        UpdateTimerDisplay()

        C_Timer.After(1, UpdateHousingVisibility)
        return
    end

    if event == "ZONE_CHANGED"
    or event == "ZONE_CHANGED_INDOORS"
    or event == "ZONE_CHANGED_NEW_AREA" then
        C_Timer.After(1, UpdateHousingVisibility)
        return
    end

    if event == "PLAYER_SOFT_INTERACT_CHANGED" then
        currentSoftInteractGUID = ...
        return
    end

    if event == "GLOBAL_MOUSE_DOWN" then
        local button = ...

        if button == "RightButton" then
            HandleDoorClick()
        end

        return
    end

    if event == "CHAT_MSG_ADDON" then
        HandleAddonMessage(...)
        return
    end
end)

frame:SetScript("OnUpdate", function()
    if timerFrame and timerFrame:IsShown() then
        UpdateTimerDisplay()
    elseif configFrame and configFrame:IsShown() then
        RefreshHuntDisplay()
    end
end)

-- SLASH
SLASH_GNOMERRACER1 = "/gnomer"
SLASH_GNOMERRACER2 = "/lap"

local function ToggleConfig()
    if configFrame:IsShown() then
        configFrame:Hide()
        HomeLapTimerDB.configHidden = true
    else
        configFrame:Show()
        HomeLapTimerDB.configHidden = false
    end
end

SlashCmdList["GNOMERRACER"] = function(msg)
    msg = string.lower((msg or ""):trim())

    if msg == "" then
        ToggleConfig()
        return
    end

    if msg == "resetui" then
        ForceUIVisible()
        return
    end

    if msg == "show" then
        timerFrame:Show()
        HomeLapTimerDB.hidden = false
        return
    end

    if msg == "hide" then
        timerFrame:Hide()
        HomeLapTimerDB.hidden = true
        return
    end

    if msg == "arm" then
        ArmNextRun()
        return
    end

    if msg == "stop" then
        ForceStop()
        return
    end

    if msg == "hunt" then
        ShowTab("play")
        configFrame:Show()
        HomeLapTimerDB.configHidden = false
        return
    end

    if msg == "where" then
        Print("Zone: " .. tostring(GetRealZoneText()))
        Print("Subzone: " .. tostring(GetSubZoneText()))
        Print("Instance: " .. tostring((select(1, GetInstanceInfo()))))
        Print("Detected housing: " .. tostring(IsLikelyPlayerHousing()))
        return
    end

    Print("Commands:")
    Print("/gnomer - open/close config")
    Print("/gnomer resetui - reset windows")
    Print("/gnomer show - show timer")
    Print("/gnomer hide - hide timer")
    Print("/gnomer arm - arm next run")
    Print("/gnomer stop - stop current run")
    Print("/gnomer hunt - open scavenger play tab")
    Print("/gnomer where - housing detection debug")
end