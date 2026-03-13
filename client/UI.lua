-- CreatureCodex Browser UI
-- Main panel: creature list (left), spell details (right), stats bar, action buttons

local PANEL_WIDTH = 750
local PANEL_HEIGHT = 500
local MIN_WIDTH = 600
local MIN_HEIGHT = 400
local LIST_WIDTH = 260
local ROW_HEIGHT = 20
local VISIBLE_ROWS = 17
local SPELL_VISIBLE = 16
local VERSION = GetAddOnMetadata and GetAddOnMetadata("CreatureCodex", "Version")
                or C_AddOns and C_AddOns.GetAddOnMetadata("CreatureCodex", "Version")
                or "1.0.0"

local _bitband = bitband or (bit and bit.band) or function(a, b) return 0 end

local SCHOOL_COLORS = {
    [0x1]  = {1.0, 1.0, 0.0},       -- Physical (yellow)
    [0x2]  = {1.0, 0.8, 0.0},       -- Holy
    [0x4]  = {1.0, 0.2, 0.0},       -- Fire
    [0x8]  = {0.2, 1.0, 0.2},       -- Nature
    [0x10] = {0.4, 0.6, 1.0},       -- Frost
    [0x20] = {0.6, 0.2, 0.8},       -- Shadow
    [0x40] = {0.9, 0.5, 0.9},       -- Arcane
}

local function GetSchoolColor(school)
    if school and SCHOOL_COLORS[school] then
        return unpack(SCHOOL_COLORS[school])
    end
    return 0.8, 0.8, 0.8
end

local function GetSchoolName(school)
    if not school or school == 0 then return "Unknown" end
    local names = {
        [0x1] = "Physical", [0x2] = "Holy", [0x4] = "Fire",
        [0x8] = "Nature", [0x10] = "Frost", [0x20] = "Shadow", [0x40] = "Arcane",
    }
    -- Handle multi-school
    local parts = {}
    for mask, name in pairs(names) do
        if _bitband(school, mask) ~= 0 then
            parts[#parts + 1] = name
        end
    end
    return #parts > 0 and table.concat(parts, "/") or "Unknown"
end

-- Sort cache
local sortedCreatures = {}
local selectedEntry = nil
local sortedSpells = {}
local creatureScrollOffset = 0
local spellScrollOffset = 0
local searchText = ""
local resultCount  -- forward declaration; assigned when action bar is built

local function RebuildCreatureList()
    sortedCreatures = {}
    if not CreatureCodexDB or not CreatureCodexDB.creatures then return end

    local filter = searchText:lower()
    for entry, data in pairs(CreatureCodexDB.creatures) do
        local name = data.name or "Unknown"
        local spellCount = 0
        for _ in pairs(data.spells or {}) do spellCount = spellCount + 1 end

        if filter == "" or name:lower():find(filter, 1, true) or tostring(entry):find(filter, 1, true) then
            sortedCreatures[#sortedCreatures + 1] = {
                entry = entry,
                name = name,
                spellCount = spellCount,
                lastSeen = data.lastSeen or 0,
            }
        end
    end

    table.sort(sortedCreatures, function(a, b)
        return a.name < b.name
    end)
end

local function RebuildSpellList()
    sortedSpells = {}
    if not selectedEntry or not CreatureCodexDB or not CreatureCodexDB.creatures then return end

    local creature = CreatureCodexDB.creatures[selectedEntry]
    if not creature or not creature.spells then return end

    for spellId, spell in pairs(creature.spells) do
        sortedSpells[#sortedSpells + 1] = {
            id = spellId,
            name = spell.name or "Unknown",
            school = spell.school or 0,
            castCount = spell.castCount or 0,
            auraCount = spell.auraCount or 0,
            total = (spell.castCount or 0) + (spell.auraCount or 0),
            zones = spell.zones or {},
            dbKnown = spell.dbKnown,
            serverConfirmed = spell.serverConfirmed,
            cooldownMin = spell.cooldownMin,
            cooldownAvg = spell.cooldownAvg,
            hpMin = spell.hpMin,
            hpMax = spell.hpMax,
        }
    end

    table.sort(sortedSpells, function(a, b) return a.total > b.total end)
end

-- ============================================================
-- Build the main frame
-- ============================================================

local f = CreateFrame("Frame", "CreatureCodexBrowserFrame", UIParent, "BackdropTemplate")
f:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
f:SetPoint("CENTER")
f:SetMovable(true)
f:SetResizable(true)
if f.SetResizeBounds then
    f:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT)
elseif f.SetMinResize then
    f:SetMinResize(MIN_WIDTH, MIN_HEIGHT)
end
f:EnableMouse(true)
f:SetClampedToScreen(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    -- Save position and size for next session
    if CreatureCodexDB then
        local point, _, relPoint, xOfs, yOfs = self:GetPoint()
        CreatureCodexDB.browserPos = { point = point, relPoint = relPoint, x = xOfs, y = yOfs }
        CreatureCodexDB.browserSize = { w = self:GetWidth(), h = self:GetHeight() }
    end
end)
f:SetFrameStrata("HIGH")
f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 },
})
f:SetBackdropColor(0.05, 0.05, 0.1, 0.95)
f:Hide()
tinsert(UISpecialFrames, "CreatureCodexBrowserFrame")

-- Title bar
local titleBg = f:CreateTexture(nil, "ARTWORK")
titleBg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
titleBg:SetSize(320, 64)
titleBg:SetPoint("TOP", 0, 12)

local titleIcon = f:CreateTexture(nil, "OVERLAY")
titleIcon:SetSize(18, 18)
titleIcon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
titleIcon:SetPoint("TOP", f, "TOP", -70, -3)

local titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
titleText:SetPoint("LEFT", titleIcon, "RIGHT", 6, 0)
titleText:SetText("CreatureCodex  |cff666666v" .. VERSION .. "|r")
titleText:SetTextColor(0, 0.8, 1)

-- Close button
local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", -4, -4)

-- ============================================================
-- Stats bar (top)
-- ============================================================

local statsBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
statsBar:SetSize(PANEL_WIDTH - 32, 28)
statsBar:SetPoint("TOPLEFT", 16, -28)
statsBar:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
statsBar:SetBackdropColor(0, 0, 0, 0.4)
statsBar:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.6)

local statsText = statsBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
statsText:SetPoint("LEFT", 8, 0)
statsText:SetTextColor(0.7, 0.7, 0.7)

local snifferText = statsBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
snifferText:SetPoint("RIGHT", -8, 0)

local statsUpdateTimer = 0
local function UpdateStats()
    local totalC, totalS = CreatureCodex_CountDB()
    local sc, ss, sa = CreatureCodex_GetSessionStats()
    local sessionPart = ""
    if sc > 0 or ss > 0 or (sa and sa > 0) then
        sessionPart = format("  |cff66ff66(+%d new)|r", sc + ss)
    end
    statsText:SetText(format("%d creatures  |  %d spells%s", totalC, totalS, sessionPart))
    local srvCasts, srvActive = CreatureCodex_GetServerStats()
    if srvActive then
        snifferText:SetText(format("|cff00ff00CreatureCodex: Active|r  %d server casts", srvCasts))
        snifferText:SetTextColor(0.3, 1, 0.3)
    elseif totalC > 0 or sc > 0 then
        snifferText:SetText("|cff88ccffCreatureCodex: Scanning|r")
        snifferText:SetTextColor(0.5, 0.7, 1)
    else
        snifferText:SetText("|cff888888CreatureCodex: Ready|r")
        snifferText:SetTextColor(0.5, 0.5, 0.5)
    end
end

-- Auto-update stats bar every 0.5s when visible
f:HookScript("OnUpdate", function(_, elapsed)
    statsUpdateTimer = statsUpdateTimer + elapsed
    if statsUpdateTimer >= 0.5 then
        statsUpdateTimer = 0
        if f:IsShown() then UpdateStats() end
    end
end)

-- ============================================================
-- Search box
-- ============================================================

local searchFrame = CreateFrame("Frame", nil, f, "BackdropTemplate")
searchFrame:SetSize(LIST_WIDTH, 24)
searchFrame:SetPoint("TOPLEFT", 16, -84)
searchFrame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
searchFrame:SetBackdropColor(0, 0, 0, 0.5)
searchFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)

local searchIcon = searchFrame:CreateTexture(nil, "OVERLAY")
searchIcon:SetSize(12, 12)
searchIcon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
searchIcon:SetPoint("LEFT", 4, 0)
searchIcon:SetVertexColor(0.6, 0.6, 0.6)

local searchBox = CreateFrame("EditBox", nil, searchFrame)
searchBox:SetPoint("LEFT", searchIcon, "RIGHT", 4, 0)
searchBox:SetPoint("RIGHT", -4, 0)
searchBox:SetHeight(20)
searchBox:SetFontObject("GameFontHighlightSmall")
searchBox:SetAutoFocus(false)
searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
searchBox:SetScript("OnTextChanged", function(self)
    searchText = self:GetText() or ""
    creatureScrollOffset = 0
    RebuildCreatureList()
    CreatureCodex_RefreshCreatureList()
end)

-- Placeholder text
local placeholder = searchBox:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
placeholder:SetPoint("LEFT", 0, 0)
placeholder:SetText("Search creatures...")
searchBox:SetScript("OnEditFocusGained", function() placeholder:Hide() end)
searchBox:SetScript("OnEditFocusLost", function(self)
    if self:GetText() == "" then placeholder:Show() end
end)

-- ============================================================
-- Creature list (left panel)
-- ============================================================

local listPanel = CreateFrame("Frame", nil, f, "BackdropTemplate")
listPanel:SetSize(LIST_WIDTH, PANEL_HEIGHT - 186)
listPanel:SetPoint("TOPLEFT", 16, -110)
listPanel:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
listPanel:SetBackdropColor(0, 0, 0, 0.3)
listPanel:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.6)

-- Creature row buttons
local creatureRows = {}
for i = 1, VISIBLE_ROWS do
    local row = CreateFrame("Button", nil, listPanel)
    row:RegisterForClicks("LeftButtonUp")
    row:SetSize(LIST_WIDTH - 4, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 2, -(i - 1) * ROW_HEIGHT - 2)

    -- Alternating row stripe for readability
    if i % 2 == 0 then
        local stripe = row:CreateTexture(nil, "BACKGROUND", nil, -1)
        stripe:SetAllPoints()
        stripe:SetColorTexture(1, 1, 1, 0.03)
    end

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(0, 0.6, 1, 0.15)

    local selected = row:CreateTexture(nil, "BACKGROUND")
    selected:SetAllPoints()
    selected:SetColorTexture(0, 0.4, 0.8, 0.3)
    selected:Hide()
    row.selectedTex = selected

    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameText:SetPoint("LEFT", 6, 0)
    nameText:SetPoint("RIGHT", -40, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)
    row.nameText = nameText

    local countText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countText:SetPoint("RIGHT", -6, 0)
    countText:SetTextColor(0.5, 0.5, 0.5)
    row.countText = countText

    row:SetScript("OnClick", function(self)
        if not self.entry then return end
        if IsControlKeyDown() then
            local name = CreatureCodexDB.creatures[self.entry] and CreatureCodexDB.creatures[self.entry].name or "Unknown"
            CreatureCodex_ShowURL("npc", self.entry, name)
            return
        end
        if IsShiftKeyDown() and ChatEdit_GetActiveWindow() then
            local name = CreatureCodexDB.creatures[self.entry] and CreatureCodexDB.creatures[self.entry].name or "Unknown"
            ChatEdit_InsertLink(format("[CreatureCodex: %s (%d)]", name, self.entry))
            return
        end
        selectedEntry = self.entry
        RebuildSpellList()
        spellScrollOffset = 0
        CreatureCodex_RefreshCreatureList()
        CreatureCodex_RefreshSpellList()
    end)

    row:SetScript("OnEnter", function(self)
        if not self.entry then return end
        local creature = CreatureCodexDB and CreatureCodexDB.creatures and CreatureCodexDB.creatures[self.entry]
        if not creature then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(creature.name or "Unknown", 1, 0.82, 0)
        GameTooltip:AddLine("Entry: " .. self.entry, 0.6, 0.6, 0.6)
        if creature.firstSeen then
            GameTooltip:AddLine("First seen: " .. date("%Y-%m-%d %H:%M", creature.firstSeen), 0.5, 0.5, 0.5)
        end
        if creature.lastSeen then
            GameTooltip:AddLine("Last seen: " .. date("%Y-%m-%d %H:%M", creature.lastSeen), 0.5, 0.5, 0.5)
        end
        GameTooltip:AddLine(self.countText:GetText() .. " spells recorded", 0.4, 0.8, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cff00ff00Ctrl-click|r Wowhead  |cff00ccffShift-click|r chat link", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    creatureRows[i] = row
end

-- Creature scroll bar
local creatureSlider = CreateFrame("Slider", nil, listPanel, "BackdropTemplate")
creatureSlider:SetWidth(12)
creatureSlider:SetPoint("TOPRIGHT", -1, -2)
creatureSlider:SetPoint("BOTTOMRIGHT", -1, 2)
creatureSlider:SetOrientation("VERTICAL")
creatureSlider:SetMinMaxValues(0, 1)
creatureSlider:SetValue(0)
creatureSlider:SetValueStep(1)
creatureSlider:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
})
creatureSlider:SetBackdropColor(0, 0, 0, 0.3)

local creatureThumb = creatureSlider:CreateTexture(nil, "OVERLAY")
creatureThumb:SetColorTexture(0.4, 0.4, 0.4, 0.8)
creatureThumb:SetSize(10, 30)
creatureSlider:SetThumbTexture(creatureThumb)

creatureSlider:SetScript("OnValueChanged", function(self, value)
    creatureScrollOffset = math.floor(value)
    CreatureCodex_RefreshCreatureList()
end)

listPanel:EnableMouseWheel(true)
listPanel:SetScript("OnMouseWheel", function(_, delta)
    local newVal = creatureScrollOffset - delta * 3
    newVal = math.max(0, math.min(newVal, math.max(0, #sortedCreatures - VISIBLE_ROWS)))
    creatureSlider:SetValue(newVal)
end)

function CreatureCodex_RefreshCreatureList()
    local maxScroll = math.max(0, #sortedCreatures - VISIBLE_ROWS)
    creatureSlider:SetMinMaxValues(0, maxScroll)

    for i = 1, VISIBLE_ROWS do
        local row = creatureRows[i]
        local idx = creatureScrollOffset + i
        local data = sortedCreatures[idx]

        if data then
            row.entry = data.entry
            row.nameText:SetText(data.name)
            row.countText:SetText(data.spellCount)

            if data.entry == selectedEntry then
                row.selectedTex:Show()
                row.nameText:SetTextColor(0, 0.8, 1)
            else
                row.selectedTex:Hide()
                row.nameText:SetTextColor(1, 0.82, 0)
            end
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
    end

    -- Update result count in action bar
    if resultCount then
        resultCount:SetText(#sortedCreatures .. " creatures")
    end
end

-- ============================================================
-- Spell detail panel (right side)
-- ============================================================

local spellPanel = CreateFrame("Frame", nil, f, "BackdropTemplate")
spellPanel:SetSize(PANEL_WIDTH - LIST_WIDTH - 48, PANEL_HEIGHT - 186)
spellPanel:SetPoint("TOPLEFT", listPanel, "TOPRIGHT", 8, 0)
spellPanel:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
spellPanel:SetBackdropColor(0, 0, 0, 0.3)
spellPanel:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.6)

-- Spell header
local spellHeader = spellPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
spellHeader:SetPoint("TOPLEFT", 8, -6)
spellHeader:SetText("Select a creature")
spellHeader:SetTextColor(0.6, 0.6, 0.6)

local entryLabel = spellPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
entryLabel:SetPoint("TOPRIGHT", -8, -8)
entryLabel:SetTextColor(0.4, 0.4, 0.4)

-- Column headers
local colHeaderY = -26
local function MakeColHeader(parent, text, anchor, xoff, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", xoff, colHeaderY)
    fs:SetWidth(width)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    fs:SetTextColor(0.5, 0.5, 0.5)
    return fs
end

MakeColHeader(spellPanel, "Spell", nil, 8, 180)
MakeColHeader(spellPanel, "School", nil, 195, 70)
MakeColHeader(spellPanel, "Casts", nil, 270, 45)
MakeColHeader(spellPanel, "Auras", nil, 318, 45)
MakeColHeader(spellPanel, "Total", nil, 366, 45)

-- Divider line under column headers
local divider = spellPanel:CreateTexture(nil, "ARTWORK")
divider:SetColorTexture(0.3, 0.3, 0.3, 0.6)
divider:SetSize(spellPanel:GetWidth() - 16, 1)
divider:SetPoint("TOPLEFT", 8, -38)

-- Spell rows
local spellRows = {}
for i = 1, SPELL_VISIBLE do
    local row = CreateFrame("Button", nil, spellPanel)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetSize(spellPanel:GetWidth() - 16, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 8, -40 - (i - 1) * ROW_HEIGHT)

    -- Alternating row stripe
    if i % 2 == 0 then
        local stripe = row:CreateTexture(nil, "BACKGROUND", nil, -1)
        stripe:SetAllPoints()
        stripe:SetColorTexture(1, 1, 1, 0.03)
    end

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.05)

    local nameFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameFs:SetPoint("LEFT", 0, 0)
    nameFs:SetWidth(180)
    nameFs:SetJustifyH("LEFT")
    nameFs:SetWordWrap(false)
    row.nameFs = nameFs

    local schoolFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    schoolFs:SetPoint("LEFT", 187, 0)
    schoolFs:SetWidth(70)
    schoolFs:SetJustifyH("LEFT")
    row.schoolFs = schoolFs

    local castFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    castFs:SetPoint("LEFT", 262, 0)
    castFs:SetWidth(45)
    castFs:SetJustifyH("RIGHT")
    row.castFs = castFs

    local auraFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    auraFs:SetPoint("LEFT", 310, 0)
    auraFs:SetWidth(45)
    auraFs:SetJustifyH("RIGHT")
    row.auraFs = auraFs

    local totalFs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    totalFs:SetPoint("LEFT", 358, 0)
    totalFs:SetWidth(45)
    totalFs:SetJustifyH("RIGHT")
    totalFs:SetTextColor(0, 1, 0)
    row.totalFs = totalFs

    row:SetScript("OnClick", function(self, btn)
        if not self.spellData then return end
        local sid = self.spellData.id

        -- Ctrl-click: open Wowhead URL popup
        if IsControlKeyDown() then
            CreatureCodex_ShowURL("spell", sid, self.spellData.name)
            return
        end

        -- Shift-click: insert spell link into chat
        if IsShiftKeyDown() and ChatEdit_GetActiveWindow() then
            local GetSpellLink = C_Spell and C_Spell.GetSpellLink or GetSpellLink
            if GetSpellLink then
                local link = GetSpellLink(sid)
                if link then
                    ChatEdit_InsertLink(link)
                    return
                end
            end
        end

        if btn == "RightButton" and selectedEntry then
            local sname = self.spellData.name
            -- Remove from current creature's data
            local creature = CreatureCodexDB.creatures[selectedEntry]
            if creature and creature.spells then
                creature.spells[sid] = nil
            end
            -- Add to global blacklist
            CreatureCodex_IgnoreSpell(sid, sname)
            -- Refresh display
            RebuildCreatureList()
            RebuildSpellList()
            CreatureCodex_RefreshCreatureList()
            CreatureCodex_RefreshSpellList()
            UpdateStats()
            PlaySound(882)
            print("|cff00ccff[CreatureCodex]|r Spell " .. sid .. " (" .. sname .. ") ignored. Open the |cffffa040Ignored|r tab to undo.")
        end
    end)

    row:SetScript("OnEnter", function(self)
        if self.spellData then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            -- Try to show the actual spell tooltip if available
            if GameTooltip.SetSpellByID then
                pcall(GameTooltip.SetSpellByID, GameTooltip, self.spellData.id)
            else
                GameTooltip:SetText(self.spellData.name, 1, 1, 1)
            end
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("Spell ID:", tostring(self.spellData.id), 0.5, 0.5, 0.5, 1, 1, 1)
            GameTooltip:AddDoubleLine("School:", GetSchoolName(self.spellData.school), 0.5, 0.5, 0.5, GetSchoolColor(self.spellData.school))
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("Casts:", BreakUpLargeNumbers(self.spellData.castCount), 0.5, 0.5, 0.5, 1, 0.82, 0)
            GameTooltip:AddDoubleLine("Auras:", BreakUpLargeNumbers(self.spellData.auraCount), 0.5, 0.5, 0.5, 0.5, 0.8, 1)
            GameTooltip:AddDoubleLine("Total:", BreakUpLargeNumbers(self.spellData.total), 0.5, 0.5, 0.5, 0, 1, 0)

            -- Timing data
            if self.spellData.cooldownMin and self.spellData.cooldownMin > 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddDoubleLine("Cooldown (est):",
                    string.format("%.1fs - %.1fs", self.spellData.cooldownMin, self.spellData.cooldownAvg or self.spellData.cooldownMin),
                    0.5, 0.5, 0.5, 1, 0.5, 0)
            end

            -- HP phase data
            if self.spellData.hpMin and self.spellData.hpMax then
                GameTooltip:AddDoubleLine("HP range seen:",
                    string.format("%d%% - %d%%", self.spellData.hpMin, self.spellData.hpMax),
                    0.5, 0.5, 0.5, 1, 0.3, 0.3)
            end

            -- DB status
            if self.spellData.dbKnown then
                GameTooltip:AddLine("Status: In creature_template_spell", 0.5, 1, 0.5)
            elseif self.spellData.total > 0 then
                GameTooltip:AddLine("Status: NEW — not yet in database", 0.3, 1, 0.3)
            end

            local zoneList = {}
            for zone in pairs(self.spellData.zones) do
                zoneList[#zoneList + 1] = zone
            end
            if #zoneList > 0 then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Zones: " .. table.concat(zoneList, ", "), 0.6, 0.6, 0.6, true)
            end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cff00ff00Shift-click|r to link  |cffff6666Right-click|r to ignore", 0.5, 0.5, 0.5)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    spellRows[i] = row
end

-- Spell scroll
local spellSlider = CreateFrame("Slider", nil, spellPanel, "BackdropTemplate")
spellSlider:SetWidth(12)
spellSlider:SetPoint("TOPRIGHT", -1, -40)
spellSlider:SetPoint("BOTTOMRIGHT", -1, 2)
spellSlider:SetOrientation("VERTICAL")
spellSlider:SetMinMaxValues(0, 1)
spellSlider:SetValue(0)
spellSlider:SetValueStep(1)
spellSlider:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
spellSlider:SetBackdropColor(0, 0, 0, 0.3)

local spellThumb = spellSlider:CreateTexture(nil, "OVERLAY")
spellThumb:SetColorTexture(0.4, 0.4, 0.4, 0.8)
spellThumb:SetSize(10, 30)
spellSlider:SetThumbTexture(spellThumb)

spellSlider:SetScript("OnValueChanged", function(self, value)
    spellScrollOffset = math.floor(value)
    CreatureCodex_RefreshSpellList()
end)

spellPanel:EnableMouseWheel(true)
spellPanel:SetScript("OnMouseWheel", function(_, delta)
    local newVal = spellScrollOffset - delta * 3
    newVal = math.max(0, math.min(newVal, math.max(0, #sortedSpells - SPELL_VISIBLE)))
    spellSlider:SetValue(newVal)
end)

function CreatureCodex_RefreshSpellList()
    if not selectedEntry then
        spellHeader:SetText("Select a creature")
        spellHeader:SetTextColor(0.6, 0.6, 0.6)
        entryLabel:SetText("")
        for i = 1, SPELL_VISIBLE do spellRows[i]:Hide() end
        return
    end

    local creature = CreatureCodexDB and CreatureCodexDB.creatures and CreatureCodexDB.creatures[selectedEntry]
    if not creature then
        -- Creature was deleted or reset — clear stale selection
        selectedEntry = nil
        spellHeader:SetText("Select a creature")
        spellHeader:SetTextColor(0.6, 0.6, 0.6)
        entryLabel:SetText("")
        for i = 1, SPELL_VISIBLE do spellRows[i]:Hide() end
        return
    end

    spellHeader:SetText(creature.name or "Unknown")
    spellHeader:SetTextColor(1, 0.82, 0)
    entryLabel:SetText("Entry: " .. selectedEntry)

    local maxScroll = math.max(0, #sortedSpells - SPELL_VISIBLE)
    spellSlider:SetMinMaxValues(0, maxScroll)

    for i = 1, SPELL_VISIBLE do
        local row = spellRows[i]
        local idx = spellScrollOffset + i
        local data = sortedSpells[idx]

        if data then
            row.spellData = data

            -- DB diff status indicator + name coloring
            local statusIcon, nameR, nameG, nameB
            if data.dbKnown and data.total > 0 then
                -- White: confirmed (in DB and observed)
                statusIcon = "|cffffffff\226\156\147|r "
                nameR, nameG, nameB = 1, 1, 1
            elseif data.dbKnown and data.total == 0 then
                -- Gray: DB-only (in DB but not observed this session)
                statusIcon = "|cff888888\226\128\148|r "
                nameR, nameG, nameB = 0.5, 0.5, 0.5
            elseif not data.dbKnown and data.total > 0 then
                -- Green: new discovery (observed but NOT in DB)
                statusIcon = "|cff00ff00+|r "
                nameR, nameG, nameB = 0.3, 1, 0.3
            else
                statusIcon = ""
                nameR, nameG, nameB = 0.8, 0.8, 0.8
            end

            row.nameFs:SetText(statusIcon .. data.name .. "  |cff666666[" .. data.id .. "]|r")
            row.nameFs:SetTextColor(nameR, nameG, nameB)
            row.schoolFs:SetText(GetSchoolName(data.school))
            row.schoolFs:SetTextColor(GetSchoolColor(data.school))
            row.castFs:SetText(BreakUpLargeNumbers(data.castCount))
            row.auraFs:SetText(BreakUpLargeNumbers(data.auraCount))
            row.totalFs:SetText(BreakUpLargeNumbers(data.total))
            row:Show()
        else
            row.spellData = nil
            row:Hide()
        end
    end
end

-- ============================================================
-- Tab system (Browse | Ignored | Settings)
-- ============================================================

local currentTab = "browse"

local function MakeButton(parent, text, width, color)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:RegisterForClicks("LeftButtonUp")
    btn:SetSize(width, 26)
    btn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(color[1], color[2], color[3], 0.6)
    btn:SetBackdropBorderColor(color[1], color[2], color[3], 0.9)

    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText(text)
    label:SetTextColor(1, 1, 1)

    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(color[1], color[2], color[3], 0.9)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(color[1], color[2], color[3], 0.6)
    end)

    return btn
end

-- Tab bar (just below stats bar)
local tabBar = CreateFrame("Frame", nil, f)
tabBar:SetSize(PANEL_WIDTH - 32, 24)
tabBar:SetPoint("TOPLEFT", 16, -58)

local tabButtons = {}
local TAB_COLORS = {
    active   = {0, 0.5, 0.8},
    inactive = {0.15, 0.15, 0.2},
}

local function MakeTab(text, tabId, xOff)
    local btn = CreateFrame("Button", nil, tabBar, "BackdropTemplate")
    btn:SetSize(100, 22)
    btn:SetPoint("LEFT", xOff, 0)
    btn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
    })
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText(text)
    btn.label = label
    btn.tabId = tabId
    tabButtons[#tabButtons + 1] = btn
    return btn
end

local tabBrowse   = MakeTab("Browse", "browse", 0)
local tabIgnored  = MakeTab("Ignored", "ignored", 106)
local tabSettings = MakeTab("Settings", "settings", 212)

-- Forward-declare SwitchTab; defined after all panels exist
local SwitchTab

-- Bottom action bar (only visible on Browse tab)
local actionBar = CreateFrame("Frame", "CreatureCodexActionBar", f)
actionBar:SetSize(PANEL_WIDTH - 32, 30)
actionBar:SetPoint("BOTTOMLEFT", 16, 12)

-- Export button
local exportBtn = MakeButton(actionBar, "Export Data", 120, {0, 0.5, 0.8})
exportBtn:SetPoint("LEFT", 0, 0)
exportBtn:SetScript("OnClick", function()
    PlaySound(852)
    CreatureCodex_Export()
end)

-- Refresh button
local refreshBtn = MakeButton(actionBar, "Refresh", 90, {0.3, 0.5, 0.3})
refreshBtn:SetPoint("LEFT", exportBtn, "RIGHT", 8, 0)
refreshBtn:SetScript("OnClick", function()
    RebuildCreatureList()
    RebuildSpellList()
    CreatureCodex_RefreshCreatureList()
    CreatureCodex_RefreshSpellList()
    UpdateStats()
    PlaySound(852)
end)

-- Ignore NPC button
local blacklistBtn = MakeButton(actionBar, "Ignore NPC", 100, {0.5, 0.3, 0.1})
blacklistBtn:SetPoint("LEFT", refreshBtn, "RIGHT", 8, 0)
blacklistBtn:SetScript("OnClick", function()
    if selectedEntry then
        local name = CreatureCodexDB.creatures[selectedEntry] and CreatureCodexDB.creatures[selectedEntry].name or "Unknown"
        CreatureCodexDB.creatureBlacklist[selectedEntry] = true
        if not CreatureCodexDB.ignored then CreatureCodexDB.ignored = {} end
        CreatureCodexDB.ignored[selectedEntry] = { name = name, ignoredAt = time() }
        CreatureCodexDB.creatures[selectedEntry] = nil
        selectedEntry = nil
        RebuildCreatureList()
        RebuildSpellList()
        CreatureCodex_RefreshCreatureList()
        CreatureCodex_RefreshSpellList()
        UpdateStats()
        PlaySound(882)
        print("|cff00ccff[CreatureCodex]|r " .. name .. " ignored. Open the |cffffa040Ignored|r tab to undo.")
    end
end)

-- Result count label (far right of action bar)
resultCount = actionBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
resultCount:SetPoint("RIGHT", 0, 0)
resultCount:SetTextColor(0.5, 0.5, 0.5)

-- ============================================================
-- Wowhead URL popup (Ctrl-click on creatures/spells)
-- ============================================================

local urlPopup = CreateFrame("Frame", "CreatureCodexURLPopup", UIParent, "BackdropTemplate")
urlPopup:SetSize(420, 70)
urlPopup:SetPoint("CENTER")
urlPopup:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 2,
})
urlPopup:SetBackdropColor(0.05, 0.05, 0.1, 0.95)
urlPopup:SetBackdropBorderColor(0, 0.5, 0.8, 0.9)
urlPopup:SetFrameStrata("DIALOG")
urlPopup:SetMovable(true)
urlPopup:EnableMouse(true)
urlPopup:RegisterForDrag("LeftButton")
urlPopup:SetScript("OnDragStart", urlPopup.StartMoving)
urlPopup:SetScript("OnDragStop", urlPopup.StopMovingOrSizing)
urlPopup:Hide()

local urlTitle = urlPopup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
urlTitle:SetPoint("TOP", 0, -8)
urlTitle:SetTextColor(0, 0.8, 1)

local urlBox = CreateFrame("EditBox", nil, urlPopup, "BackdropTemplate")
urlBox:SetPoint("BOTTOMLEFT", 10, 10)
urlBox:SetPoint("BOTTOMRIGHT", -10, 10)
urlBox:SetHeight(22)
urlBox:SetFontObject("GameFontHighlightSmall")
urlBox:SetAutoFocus(false)
urlBox:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
urlBox:SetBackdropColor(0, 0, 0, 0.6)
urlBox:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
urlBox:SetTextInsets(4, 4, 0, 0)
urlBox:SetScript("OnEscapePressed", function() urlPopup:Hide() end)
urlBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)

local urlClose = CreateFrame("Button", nil, urlPopup, "UIPanelCloseButton")
urlClose:SetPoint("TOPRIGHT", 2, 2)
urlClose:SetScript("OnClick", function() urlPopup:Hide() end)

function CreatureCodex_ShowURL(urlType, id, name)
    local url
    if urlType == "npc" then
        url = "https://www.wowhead.com/npc=" .. id
    elseif urlType == "spell" then
        url = "https://www.wowhead.com/spell=" .. id
    else
        return
    end
    urlTitle:SetText((name or "") .. " (" .. urlType .. " " .. id .. ")")
    urlBox:SetText(url)
    urlPopup:Show()
    urlBox:SetFocus()
    urlBox:HighlightText()
end

-- ============================================================
-- Ignored creatures panel (toggled via button)
-- ============================================================

local ignoredPanel = CreateFrame("Frame", nil, f, "BackdropTemplate")
ignoredPanel:SetSize(PANEL_WIDTH - 32, PANEL_HEIGHT - 100)
ignoredPanel:SetPoint("TOPLEFT", 16, -84)
ignoredPanel:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
ignoredPanel:SetBackdropColor(0, 0, 0, 0.3)
ignoredPanel:SetBackdropBorderColor(0.5, 0.3, 0.1, 0.6)
ignoredPanel:Hide()

local ignoredTitle = ignoredPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
ignoredTitle:SetPoint("TOP", 0, -8)
ignoredTitle:SetText("Ignored Creatures")
ignoredTitle:SetTextColor(0.8, 0.5, 0.2)

local ignoredScroll = CreateFrame("ScrollFrame", nil, ignoredPanel, "UIPanelScrollFrameTemplate")
ignoredScroll:SetPoint("TOPLEFT", 8, -28)
ignoredScroll:SetPoint("BOTTOMRIGHT", -28, 8)
local ignoredContent = CreateFrame("Frame", nil, ignoredScroll)
ignoredContent:SetSize(PANEL_WIDTH - 80, 1)
ignoredScroll:SetScrollChild(ignoredContent)

local ignoredRows = {}

local function MakeIgnoredRow(parent, y, label, color, onUnignore)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(PANEL_WIDTH - 80, 22)
    row:SetPoint("TOPLEFT", 0, -y)

    local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameText:SetPoint("LEFT", 4, 0)
    nameText:SetText(color .. label .. "|r")

    local unignoreBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
    unignoreBtn:SetSize(70, 18)
    unignoreBtn:SetPoint("RIGHT", -4, 0)
    unignoreBtn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    unignoreBtn:SetBackdropColor(0.2, 0.5, 0.2, 0.6)
    unignoreBtn:SetBackdropBorderColor(0.3, 0.6, 0.3, 0.9)
    local btnLabel = unignoreBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btnLabel:SetPoint("CENTER")
    btnLabel:SetText("Unignore")
    btnLabel:SetTextColor(1, 1, 1)
    unignoreBtn:SetScript("OnClick", onUnignore)

    return row
end

local function RefreshIgnoredPanel()
    for _, row in ipairs(ignoredRows) do row:Hide() end
    wipe(ignoredRows)

    local y = 0
    local creatureCount, spellCount = 0, 0

    -- Section: Ignored Creatures
    local creatures = CreatureCodex_GetIgnoredCreatures()
    local hasCreatures = next(creatures) ~= nil
    if hasCreatures then
        local header = CreateFrame("Frame", nil, ignoredContent)
        header:SetSize(PANEL_WIDTH - 80, 18)
        header:SetPoint("TOPLEFT", 0, -y)
        local hText = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        hText:SetPoint("LEFT", 4, 0)
        hText:SetText("Creatures")
        hText:SetTextColor(0.8, 0.5, 0.2)
        ignoredRows[#ignoredRows + 1] = header
        y = y + 20

        for entry, info in pairs(creatures) do
            creatureCount = creatureCount + 1
            local row = MakeIgnoredRow(ignoredContent, y,
                format("%s  |cff888888(entry %d)|r", info.name or "Unknown", entry),
                "|cffffa040",
                function()
                    CreatureCodex_UnignoreCreature(entry)
                    PlaySound(852)
                    print(format("|cff00ccff[CreatureCodex]|r Unignored %s (entry %d). Walk near it to recapture.", info.name or "Unknown", entry))
                    RefreshIgnoredPanel()
                end)
            ignoredRows[#ignoredRows + 1] = row
            y = y + 24
        end
        y = y + 8  -- spacing between sections
    end

    -- Section: Ignored Spells
    local spells = CreatureCodex_GetIgnoredSpells()
    local hasSpells = next(spells) ~= nil
    if hasSpells then
        local header = CreateFrame("Frame", nil, ignoredContent)
        header:SetSize(PANEL_WIDTH - 80, 18)
        header:SetPoint("TOPLEFT", 0, -y)
        local hText = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        hText:SetPoint("LEFT", 4, 0)
        hText:SetText("Spells")
        hText:SetTextColor(0.4, 0.6, 1)
        ignoredRows[#ignoredRows + 1] = header
        y = y + 20

        for spellId, info in pairs(spells) do
            spellCount = spellCount + 1
            local row = MakeIgnoredRow(ignoredContent, y,
                format("%s  |cff888888[%d]|r", info.name or "Unknown", spellId),
                "|cff6699ff",
                function()
                    CreatureCodex_UnignoreSpell(spellId)
                    PlaySound(852)
                    print(format("|cff00ccff[CreatureCodex]|r Unignored spell %s (%d).", info.name or "Unknown", spellId))
                    RefreshIgnoredPanel()
                end)
            ignoredRows[#ignoredRows + 1] = row
            y = y + 24
        end
    end

    if not hasCreatures and not hasSpells then
        local empty = CreateFrame("Frame", nil, ignoredContent)
        empty:SetSize(PANEL_WIDTH - 80, 22)
        empty:SetPoint("TOPLEFT", 0, -y)
        local emptyText = empty:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        emptyText:SetPoint("LEFT", 4, 0)
        emptyText:SetText("|cff666666No ignored creatures or spells.|r")
        ignoredRows[#ignoredRows + 1] = empty
        y = y + 24
    end

    ignoredContent:SetHeight(math.max(y, 1))
    ignoredTitle:SetText(format("Ignored  |cffffa040%d creatures|r  |cff6699ff%d spells|r", creatureCount, spellCount))
end

-- ============================================================
-- Settings panel
-- ============================================================

local settingsPanel = CreateFrame("Frame", nil, f, "BackdropTemplate")
settingsPanel:SetSize(PANEL_WIDTH - 32, PANEL_HEIGHT - 100)
settingsPanel:SetPoint("TOPLEFT", 16, -84)
settingsPanel:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
})
settingsPanel:SetBackdropColor(0, 0, 0, 0.3)
settingsPanel:SetBackdropBorderColor(0.3, 0.3, 0.5, 0.6)
settingsPanel:Hide()

local settingsTitle = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
settingsTitle:SetPoint("TOP", 0, -8)
settingsTitle:SetText("Settings")
settingsTitle:SetTextColor(0.6, 0.6, 0.8)

-- Debug toggle
local debugBtn = MakeButton(settingsPanel, "Toggle Debug", 140, {0.3, 0.3, 0.5})
debugBtn:SetPoint("TOPLEFT", 16, -40)
debugBtn:SetScript("OnClick", function()
    CreatureCodex_ToggleDebug()
    PlaySound(852)
    local state = CreatureCodex_IsDebug() and "|cff00ff00ON|r" or "|cffff4444OFF|r"
    print("|cff00ccff[CreatureCodex]|r Debug mode: " .. state)
end)

-- Reset All
local resetBtn = MakeButton(settingsPanel, "Reset All Data", 140, {0.6, 0.15, 0.15})
resetBtn:SetPoint("TOPLEFT", debugBtn, "BOTTOMLEFT", 0, -24)
resetBtn:SetScript("OnClick", function()
    StaticPopup_Show("CREATURECODEX_RESET_CONFIRM")
end)

StaticPopupDialogs["CREATURECODEX_RESET_CONFIRM"] = {
    text = "Reset ALL CreatureCodex data?\nThis cannot be undone.",
    button1 = "Reset",
    button2 = "Cancel",
    OnAccept = function()
        if CreatureCodexDB then
            CreatureCodexDB.creatures = {}
            CreatureCodexDB.creatureBlacklist = {}
            CreatureCodexDB.spellBlacklist = {}
            CreatureCodexDB.ignored = {}
            CreatureCodexDB.ignoredSpells = {}
        end
        selectedEntry = nil
        RebuildCreatureList()
        RebuildSpellList()
        CreatureCodex_RefreshCreatureList()
        CreatureCodex_RefreshSpellList()
        UpdateStats()
        PlaySound(882)
        print("|cff00ccff[CreatureCodex]|r All data has been reset.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- Version info at bottom of settings
local versionInfo = settingsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
versionInfo:SetPoint("BOTTOMLEFT", 16, 12)
versionInfo:SetText("|cff666666CreatureCodex v" .. VERSION .. "|r")

-- ============================================================
-- SwitchTab — show/hide panels per tab
-- ============================================================

SwitchTab = function(tabId)
    currentTab = tabId

    -- Update tab button appearance
    for _, btn in ipairs(tabButtons) do
        if btn.tabId == tabId then
            btn:SetBackdropColor(TAB_COLORS.active[1], TAB_COLORS.active[2], TAB_COLORS.active[3], 0.8)
            btn:SetBackdropBorderColor(TAB_COLORS.active[1], TAB_COLORS.active[2], TAB_COLORS.active[3], 1)
            btn.label:SetTextColor(1, 1, 1)
        else
            btn:SetBackdropColor(TAB_COLORS.inactive[1], TAB_COLORS.inactive[2], TAB_COLORS.inactive[3], 0.6)
            btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.6)
            btn.label:SetTextColor(0.6, 0.6, 0.6)
        end
    end

    -- Hide everything first
    searchFrame:Hide()
    listPanel:Hide()
    spellPanel:Hide()
    actionBar:Hide()
    ignoredPanel:Hide()
    settingsPanel:Hide()

    if tabId == "browse" then
        searchFrame:Show()
        listPanel:Show()
        spellPanel:Show()
        actionBar:Show()
    elseif tabId == "ignored" then
        RefreshIgnoredPanel()
        ignoredPanel:Show()
    elseif tabId == "settings" then
        settingsPanel:Show()
    end
end

-- Wire tab buttons
for _, btn in ipairs(tabButtons) do
    btn:SetScript("OnClick", function(self)
        PlaySound(852)
        SwitchTab(self.tabId)
    end)
end

-- Initialize to Browse tab
SwitchTab("browse")

-- ============================================================
-- Resize grip (bottom-right corner, Simulationcraft pattern)
-- ============================================================

local resizeBtn = CreateFrame("Button", nil, f)
resizeBtn:SetPoint("BOTTOMRIGHT", -6, 6)
resizeBtn:SetSize(16, 16)
resizeBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
resizeBtn:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
resizeBtn:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
resizeBtn:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then
        f:StartSizing("BOTTOMRIGHT")
    end
end)
resizeBtn:SetScript("OnMouseUp", function()
    f:StopMovingOrSizing()
    if CreatureCodexDB then
        CreatureCodexDB.browserSize = { w = f:GetWidth(), h = f:GetHeight() }
    end
end)

-- ============================================================
-- Toggle function (called by minimap button and /cc)
-- ============================================================

function CreatureCodex_ToggleUI()
    if f:IsShown() then
        f:Hide()
        PlaySound(840)   -- IG_CHARACTER_INFO_CLOSE
    else
        -- Restore saved position
        if CreatureCodexDB and CreatureCodexDB.browserPos then
            local p = CreatureCodexDB.browserPos
            f:ClearAllPoints()
            f:SetPoint(p.point, UIParent, p.relPoint, p.x, p.y)
        end
        -- Restore saved size
        if CreatureCodexDB and CreatureCodexDB.browserSize then
            f:SetSize(CreatureCodexDB.browserSize.w, CreatureCodexDB.browserSize.h)
        end
        RebuildCreatureList()
        if selectedEntry then RebuildSpellList() end
        CreatureCodex_RefreshCreatureList()
        CreatureCodex_RefreshSpellList()
        UpdateStats()
        resultCount:SetText(#sortedCreatures .. " creatures")
        SwitchTab("browse")
        f:Show()
        PlaySound(839)   -- IG_CHARACTER_INFO_OPEN
    end
end

