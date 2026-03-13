-- CreatureCodex Minimap Button via LibDBIcon
-- Left-click opens browser, right-click exports, drag to reposition

local ldb = LibStub:GetLibrary("LibDataBroker-1.1", true)
if not ldb then return end

local plugin = ldb:NewDataObject("CreatureCodex", {
    type = "data source",
    text = "CreatureCodex",
    icon = "Interface\\Icons\\INV_Misc_Book_09",

    OnClick = function(_, button)
        if button == "RightButton" then
            CreatureCodex_Export()
        else
            CreatureCodex_ToggleUI()
        end
    end,

    OnTooltipShow = function(tt)
        tt:AddLine("CreatureCodex", 0, 0.8, 1)

        local totalC, totalS = CreatureCodex_CountDB()
        tt:AddLine(totalC .. " creatures, " .. totalS .. " spells tracked", 1, 1, 1)

        local sc, ss, sa = CreatureCodex_GetSessionStats()
        if sc > 0 or ss > 0 then
            local text = "Session: +" .. sc .. " creatures, +" .. ss .. " spells"
            if sa and sa > 0 then text = text .. ", +" .. sa .. " auras" end
            tt:AddLine(text, 0.5, 1, 0.5)
        end

        tt:AddLine(" ")
        tt:AddLine("|cff00ff00Left-click|r to open browser", 0.8, 0.8, 0.8)
        tt:AddLine("|cff00ff00Right-click|r to export", 0.8, 0.8, 0.8)
        tt:AddLine("|cff00ff00Drag|r to reposition", 0.8, 0.8, 0.8)
    end,
})

-- Register on PLAYER_LOGIN (after DB is ready)
function CreatureCodex_InitMinimap()
    local icon = LibStub("LibDBIcon-1.0", true)
    if not icon then return end
    if not CreatureCodexDB.minimapIcon then
        CreatureCodexDB.minimapIcon = {}
    end
    icon:Register("CreatureCodex", plugin, CreatureCodexDB.minimapIcon)
end
