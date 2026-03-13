-- CreatureCodex Export — Raw, SQL (creature_template_spell), SmartAI stubs

local function SanitizeName(name)
    if not name then return "Unknown" end
    return name:gsub("[|\n\r'\\]", "")
end

local function SqlEscape(str)
    if not str then return "Unknown" end
    return str:gsub("\\", "\\\\"):gsub("'", "\\'")
end

-- ============================================================
-- Export format generators
-- ============================================================

local function GenerateRawExport()
    local lines = {"CCEXPORT:v3"}
    local creatureCount = 0

    local entries = {}
    for entry in pairs(CreatureCodexDB.creatures) do
        entries[#entries + 1] = entry
    end
    table.sort(entries)

    for _, entry in ipairs(entries) do
        local creature = CreatureCodexDB.creatures[entry]
        local parts = {entry .. ":" .. SanitizeName(creature.name)}

        local spellList = {}
        for spellId, spell in pairs(creature.spells or {}) do
            spellList[#spellList + 1] = {id = spellId, data = spell}
        end
        table.sort(spellList, function(a, b)
            local ac, bc = (a.data.castCount or 0), (b.data.castCount or 0)
            if ac ~= bc then return ac > bc end
            return a.id < b.id
        end)

        for _, s in ipairs(spellList) do
            local total = (s.data.castCount or 0) + (s.data.auraCount or 0)
            parts[#parts + 1] = s.id .. ":" .. total .. ":" .. (s.data.school or 0) .. ":" .. SanitizeName(s.data.name)
        end

        lines[#lines + 1] = table.concat(parts, "|")
        creatureCount = creatureCount + 1
    end

    lines[#lines + 1] = "END"
    return table.concat(lines, "\n"), creatureCount
end

local function GenerateSQL()
    local lines = {
        "-- CreatureCodex SQL Export — creature_template_spell",
        "-- Format: TrinityCore standard (DELETE+INSERT, backtick columns)",
        "-- WARNING: DELETE statements below will remove ALL existing spells for each creature.",
        "-- Use the 'New Only' export tab if you want to add spells without removing existing ones.",
        "-- Generated: " .. date("%Y-%m-%d %H:%M:%S"),
        "-- Collector: " .. (CreatureCodexDB.collector or "unknown"),
        "",
    }
    local creatureCount, spellCount = 0, 0

    local entries = {}
    for entry in pairs(CreatureCodexDB.creatures) do
        entries[#entries + 1] = entry
    end
    table.sort(entries)

    for _, entry in ipairs(entries) do
        local creature = CreatureCodexDB.creatures[entry]
        local spellList = {}
        for spellId, spell in pairs(creature.spells or {}) do
            -- Only export spells that were actually observed casting (not aura-only or DB-only imports)
            if (spell.castCount or 0) > 0 then
                spellList[#spellList + 1] = {id = spellId, data = spell}
            end
        end

        if #spellList > 0 then
            table.sort(spellList, function(a, b)
                local ac, bc = (a.data.castCount or 0), (b.data.castCount or 0)
                if ac ~= bc then return ac > bc end
                return a.id < b.id
            end)

            lines[#lines + 1] = "-- " .. SanitizeName(creature.name) .. " (entry " .. entry .. ") — " .. #spellList .. " spells"
            lines[#lines + 1] = "DELETE FROM `creature_template_spell` WHERE `CreatureID` = " .. entry .. ";"

            for idx, s in ipairs(spellList) do
                local dbKnown = s.data.dbKnown and " -- DB-confirmed" or " -- NEW"
                lines[#lines + 1] = "INSERT INTO `creature_template_spell` (`CreatureID`, `Index`, `Spell`) VALUES ("
                    .. entry .. ", " .. (idx - 1) .. ", " .. s.id .. ");" .. dbKnown
                spellCount = spellCount + 1
            end
            lines[#lines + 1] = ""
            creatureCount = creatureCount + 1
        end
    end

    return table.concat(lines, "\n"), creatureCount, spellCount
end

local function GenerateSmartAI()
    local lines = {
        "-- CreatureCodex SmartAI Stubs — auto-generated from observed cast patterns",
        "-- Generated: " .. date("%Y-%m-%d %H:%M:%S"),
        "-- WARNING: These are estimates based on observed cast frequency.",
        "-- Review and adjust cooldowns before using in production.",
        "",
    }
    local creatureCount = 0

    local entries = {}
    for entry in pairs(CreatureCodexDB.creatures) do
        entries[#entries + 1] = entry
    end
    table.sort(entries)

    for _, entry in ipairs(entries) do
        local creature = CreatureCodexDB.creatures[entry]
        local spellList = {}
        for spellId, spell in pairs(creature.spells or {}) do
            if (spell.castCount or 0) >= 2 then
                spellList[#spellList + 1] = {id = spellId, data = spell}
            end
        end

        if #spellList > 0 then
            -- Sort by total casts descending (most-used first)
            table.sort(spellList, function(a, b)
                return (a.data.castCount or 0) > (b.data.castCount or 0)
            end)

            lines[#lines + 1] = "-- " .. SanitizeName(creature.name) .. " (entry " .. entry .. ")"
            lines[#lines + 1] = "DELETE FROM `smart_scripts` WHERE `entryorguid` = " .. entry .. " AND `source_type` = 0;"

            for idx, s in ipairs(spellList) do
                -- Estimate cooldown from timing data if available
                local cdMin, cdMax
                if s.data.cooldownMin and s.data.cooldownMin > 0 then
                    cdMin = math.floor(s.data.cooldownMin * 1000)
                    cdMax = math.floor((s.data.cooldownMax or s.data.cooldownMin * 1.5) * 1000)
                else
                    -- Fallback: estimate from observation time and cast count
                    local duration = (s.data.lastSeen or 0) - (s.data.firstSeen or 0)
                    if duration > 0 and s.data.castCount > 1 then
                        local avgInterval = duration / (s.data.castCount - 1)
                        cdMin = math.floor(math.max(avgInterval * 0.7, 3) * 1000)
                        cdMax = math.floor(math.max(avgInterval * 1.3, 6) * 1000)
                    else
                        cdMin = 8000
                        cdMax = 15000
                    end
                end

                -- Determine target type from spell behavior
                -- 1 = self, 2 = victim (current target), 6 = spell's default
                local targetType = 2
                if (s.data.auraCount or 0) > (s.data.castCount or 0) then
                    targetType = 1  -- Likely self-buff
                end

                -- event_type 0 = UpdateIC (in combat, repeat)
                -- action_type 11 = Cast
                local hpMin = ""
                if s.data.hpMin and s.data.hpMin < 40 then
                    -- Spell seen below 40% HP at least once — use HP% event instead
                    lines[#lines + 1] = string.format(
                        "INSERT INTO `smart_scripts` (`entryorguid`,`source_type`,`id`,`link`,`event_type`,`event_phase_mask`,`event_chance`,`event_flags`,`event_param1`,`event_param2`,`event_param3`,`event_param4`,`action_type`,`action_param1`,`action_param2`,`action_param3`,`target_type`,`comment`) VALUES "
                        .. "(%d,0,%d,0,2,0,100,0,%d,%d,0,0,11,%d,0,0,%d,'%s - %s (HP phase)');",
                        entry, idx - 1,
                        math.floor(s.data.hpMin), math.floor(s.data.hpMax or s.data.hpMin + 10),
                        s.id, targetType,
                        SqlEscape(creature.name), SqlEscape(s.data.name or "Unknown"))
                else
                    lines[#lines + 1] = string.format(
                        "INSERT INTO `smart_scripts` (`entryorguid`,`source_type`,`id`,`link`,`event_type`,`event_phase_mask`,`event_chance`,`event_flags`,`event_param1`,`event_param2`,`event_param3`,`event_param4`,`action_type`,`action_param1`,`action_param2`,`action_param3`,`target_type`,`comment`) VALUES "
                        .. "(%d,0,%d,0,0,0,100,0,%d,%d,%d,%d,11,%d,0,0,%d,'%s - %s');",
                        entry, idx - 1,
                        cdMin, cdMax, cdMin, cdMax,
                        s.id, targetType,
                        SqlEscape(creature.name), SqlEscape(s.data.name or "Unknown"))
                end
            end
            lines[#lines + 1] = ""
            creatureCount = creatureCount + 1
        end
    end

    return table.concat(lines, "\n"), creatureCount
end

local function GenerateNewDiscoveriesSQL()
    local lines = {
        "-- CreatureCodex — New Discoveries Only (spells NOT in creature_template_spell)",
        "-- Generated: " .. date("%Y-%m-%d %H:%M:%S"),
        "",
    }
    local newCount = 0

    local entries = {}
    for entry in pairs(CreatureCodexDB.creatures) do
        entries[#entries + 1] = entry
    end
    table.sort(entries)

    for _, entry in ipairs(entries) do
        local creature = CreatureCodexDB.creatures[entry]
        local newSpells = {}
        for spellId, spell in pairs(creature.spells or {}) do
            if not spell.dbKnown and (spell.castCount or 0) > 0 then
                newSpells[#newSpells + 1] = {id = spellId, data = spell}
            end
        end

        if #newSpells > 0 then
            table.sort(newSpells, function(a, b) return a.id < b.id end)

            -- Need to know the max existing index to append after it
            local maxIdx = -1
            for _, spell in pairs(creature.spells or {}) do
                if spell.dbKnown then maxIdx = maxIdx + 1 end
            end

            lines[#lines + 1] = "-- " .. SanitizeName(creature.name) .. " (entry " .. entry .. ") — " .. #newSpells .. " NEW spells"
            for _, s in ipairs(newSpells) do
                maxIdx = maxIdx + 1
                lines[#lines + 1] = "INSERT IGNORE INTO `creature_template_spell` (`CreatureID`, `Index`, `Spell`) VALUES ("
                    .. entry .. ", " .. maxIdx .. ", " .. s.id .. "); -- " .. SanitizeName(s.data.name or "Unknown")
                newCount = newCount + 1
            end
            lines[#lines + 1] = ""
        end
    end

    if newCount == 0 then
        return "-- No new discoveries to export. All observed spells are already in the database.", 0
    end

    return table.concat(lines, "\n"), newCount
end

-- ============================================================
-- Export UI with tabs
-- ============================================================

local currentExportMode = "raw"

local function ShowExportWindow(text, summary)
    if not CreatureCodexExportFrame then
        local f = CreateFrame("Frame", "CreatureCodexExportFrame", UIParent, "BasicFrameTemplateWithInset")
        f:SetSize(720, 500)
        f:SetPoint("CENTER")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetFrameStrata("DIALOG")

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetPoint("TOP", f, "TOP", 0, -5)
        title:SetText("CreatureCodex Export")
        f.title = title

        -- Tab buttons
        local tabY = -24
        local function MakeTab(parent, text, mode, xOff)
            local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
            btn:SetSize(100, 22)
            btn:SetPoint("TOPLEFT", xOff, tabY)
            btn:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8x8",
                edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
            })
            local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            label:SetPoint("CENTER")
            label:SetText(text)
            btn.label = label
            btn.mode = mode
            btn:SetScript("OnClick", function()
                currentExportMode = mode
                CreatureCodex_Export()
            end)
            return btn
        end

        f.tabRaw = MakeTab(f, "Raw Data", "raw", 12)
        f.tabSQL = MakeTab(f, "SQL (Spells)", "sql", 118)
        f.tabSmartAI = MakeTab(f, "SQL (SmartAI)", "smartai", 224)
        f.tabNew = MakeTab(f, "New Only", "new", 330)
        f.tabs = {f.tabRaw, f.tabSQL, f.tabSmartAI, f.tabNew}

        local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 12, tabY - 26)
        scroll:SetPoint("BOTTOMRIGHT", -30, 10)

        local editBox = CreateFrame("EditBox", nil, scroll)
        editBox:SetMultiLine(true)
        editBox:SetAutoFocus(false)
        editBox:SetFontObject(ChatFontNormal)
        editBox:SetWidth(655)
        editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        scroll:SetScrollChild(editBox)

        f.editBox = editBox
        tinsert(UISpecialFrames, "CreatureCodexExportFrame")
    end

    -- Update tab highlights
    for _, tab in ipairs(CreatureCodexExportFrame.tabs) do
        if tab.mode == currentExportMode then
            tab:SetBackdropColor(0, 0.5, 0.8, 0.9)
            tab:SetBackdropBorderColor(0, 0.7, 1, 1)
            tab.label:SetTextColor(1, 1, 1)
        else
            tab:SetBackdropColor(0.2, 0.2, 0.2, 0.6)
            tab:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
            tab.label:SetTextColor(0.7, 0.7, 0.7)
        end
    end

    -- Show stale indicator if a previously saved export exists and data changed since
    local staleNote = ""
    if CreatureCodex_GetSavedExport and CreatureCodex_GetDataRevision then
        local saved = CreatureCodex_GetSavedExport(currentExportMode)
        if saved and saved.sourceRevision and saved.sourceRevision < CreatureCodex_GetDataRevision() then
            staleNote = " |cffffff00(data changed since last export — regenerated)|r"
        end
    end

    CreatureCodexExportFrame.editBox:SetText(text)
    CreatureCodexExportFrame:Show()
    CreatureCodexExportFrame.editBox:HighlightText()
    CreatureCodexExportFrame.editBox:SetFocus()

    print("|cff00ccff[CreatureCodex]|r " .. summary .. staleNote)
end

function CreatureCodex_Export()
    if not CreatureCodexDB or not CreatureCodexDB.creatures then
        print("|cff00ccff[CreatureCodex]|r No data to export.")
        return
    end

    local text, summary
    if currentExportMode == "sql" then
        local t, creatures, spells = GenerateSQL()
        text = t
        summary = "SQL export: " .. creatures .. " creatures, " .. spells .. " spells."
    elseif currentExportMode == "smartai" then
        local t, creatures = GenerateSmartAI()
        text = t
        summary = "SmartAI stubs: " .. creatures .. " creatures with 2+ casts."
    elseif currentExportMode == "new" then
        local t, count = GenerateNewDiscoveriesSQL()
        text = t
        summary = "New discoveries: " .. count .. " spells not yet in DB."
    else
        local t, creatures = GenerateRawExport()
        text = t
        summary = "Raw export: " .. creatures .. " creatures. Ctrl+A, Ctrl+C to copy."
    end

    ShowExportWindow(text, summary)

    -- Persist export to SavedVariables
    if CreatureCodex_SaveExport then
        CreatureCodex_SaveExport(currentExportMode, text)
    end
end
