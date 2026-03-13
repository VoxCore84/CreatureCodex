local VERSION = 4
local ADDON_VERSION = "1.0.0"

local CCDX_PREFIX = "CCDX"

-- ============================================================
-- Blacklists
-- ============================================================

local SPELL_BLACKLIST = {
    [1604]  = true,   -- Dazed
    [6603]  = true,   -- Auto Attack
    [75]    = true,   -- Auto Shot
    [3018]  = true,   -- Shoot
    [1784]  = true,   -- Stealth
    [2983]  = true,   -- Sprint
    [20577] = true,   -- Cannibalize
    [7744]  = true,   -- Will of the Forsaken
    [20549] = true,   -- War Stomp
    [26297] = true,   -- Berserking
}

local CREATURE_BLACKLIST = {
    [0]     = true,
    [1]     = true,
    [19871] = true,   -- WorldTrigger
    [21252] = true,   -- World Trigger (Large AOI)
    [22515] = true,   -- World Trigger (Large AOI, Not Immune)
}

-- ============================================================
-- Pre-built unit token list (zero hot-path string allocation)
-- ============================================================

local SCAN_UNITS = {"target", "focus", "mouseover"}
for i = 1, 40 do SCAN_UNITS[#SCAN_UNITS + 1] = "nameplate" .. i end
for i = 1, 4 do
    SCAN_UNITS[#SCAN_UNITS + 1] = "party" .. i .. "target"
    SCAN_UNITS[#SCAN_UNITS + 1] = "boss" .. i
end

-- ============================================================
-- State
-- ============================================================

local frame = CreateFrame("Frame", "CreatureCodexFrame")
local sessionCreatures, sessionSpells, sessionAuras = 0, 0, 0
local sessionServerCasts = 0  -- casts received from server sniffer
local currentZone = "Unknown"
local currentDifficulty = 0
local debugMode = false
local serverSnifferActive = false  -- true once we get first server message

-- Deduplication tables with timestamps for eviction
local activeCasts = {}   -- [castKey] = GetTime()
local activeAuras = {}   -- [auraKey] = GetTime()

-- Active nameplate tracking (event-driven)
local activeNameplates = {}
local nameplateScanList = {}
local nameplateScanDirty = true
local auraScanIndex = 0

-- Throttles
local updateThrottle = 0
local sweepTimer = 0
local auraScanTimer = 0

local CAST_TICK_RATE   = 0.1   -- 10 Hz for visual cast scraping
local AURA_TICK_RATE   = 0.2   -- 5 Hz for aura scanning (staggered)
local SWEEP_INTERVAL   = 30    -- Evict stale dedup entries every 30s
local EVICT_AGE        = 15    -- Entries older than 15s are stale

-- ============================================================
-- DB Initialization
-- ============================================================

local dataRevision = 0  -- monotonic counter for stale export detection

local function InitDB()
    if not CreatureCodexDB then
        CreatureCodexDB = {
            version = VERSION,
            collector = UnitName("player") .. "-" .. GetRealmName(),
            lastExport = 0,
            creatures = {},
            spellBlacklist = {},
            creatureBlacklist = {},
            ignored = {},
            ignoredSpells = {},
            players = {},
            exports = {},
            spellMetadata = {},
            settings = { trackPlayers = false },
            dataRevision = 0,
        }
    end

    -- Additive migration: v3 → v4
    if (CreatureCodexDB.version or 0) < VERSION then
        CreatureCodexDB.version = VERSION
        -- Migrate creatureBlacklist: true → {name, ignoredAt}
        if not CreatureCodexDB.ignored then
            CreatureCodexDB.ignored = {}
        end
        for entry, val in pairs(CreatureCodexDB.creatureBlacklist or {}) do
            if val == true then
                local name = "Creature " .. entry
                CreatureCodexDB.ignored[entry] = { name = name, ignoredAt = time() }
            end
        end
        -- Ensure new tables exist
        if not CreatureCodexDB.players then CreatureCodexDB.players = {} end
        if not CreatureCodexDB.exports then CreatureCodexDB.exports = {} end
        if not CreatureCodexDB.spellMetadata then CreatureCodexDB.spellMetadata = {} end
        if not CreatureCodexDB.settings then CreatureCodexDB.settings = { trackPlayers = false } end
        if not CreatureCodexDB.ignoredSpells then CreatureCodexDB.ignoredSpells = {} end
        if not CreatureCodexDB.dataRevision then CreatureCodexDB.dataRevision = 0 end
    end

    dataRevision = CreatureCodexDB.dataRevision or 0

    for id in pairs(CreatureCodexDB.spellBlacklist or {}) do
        SPELL_BLACKLIST[id] = true
    end
    for id in pairs(CreatureCodexDB.creatureBlacklist or {}) do
        CREATURE_BLACKLIST[id] = true
    end
end

local function BumpRevision()
    dataRevision = dataRevision + 1
    CreatureCodexDB.dataRevision = dataRevision
end

function CreatureCodex_GetDataRevision()
    return dataRevision
end

-- ============================================================
-- WPP sniff data merge (auto-import on login/reload)
-- ============================================================

local function MergeWPPData()
    if not CreatureCodexWPP or not CreatureCodexWPP.creatures then return 0, 0 end
    if not CreatureCodexDB then return 0, 0 end

    local newCreatures, newSpells = 0, 0
    local db = CreatureCodexDB.creatures

    for entry, wppCreature in pairs(CreatureCodexWPP.creatures) do
        if not CREATURE_BLACKLIST[entry] then
            if not db[entry] then
                db[entry] = {
                    name = wppCreature.name or ("Creature " .. entry),
                    spells = {},
                    firstSeen = wppCreature.firstSeen or time(),
                    lastSeen = wppCreature.lastSeen or time(),
                }
                newCreatures = newCreatures + 1
            end

            local creature = db[entry]
            if wppCreature.name and wppCreature.name ~= "Unknown" and wppCreature.name ~= ("Creature " .. entry) then
                creature.name = wppCreature.name
            end

            for spellId, wppSpell in pairs(wppCreature.spells or {}) do
                if not SPELL_BLACKLIST[spellId] then
                    if not creature.spells[spellId] then
                        creature.spells[spellId] = {
                            name = wppSpell.name or ("Spell " .. spellId),
                            school = wppSpell.school or 0,
                            castCount = wppSpell.castCount or 0,
                            auraCount = wppSpell.auraCount or 0,
                            firstSeen = wppSpell.firstSeen or time(),
                            lastSeen = wppSpell.lastSeen or time(),
                            zones = wppSpell.zones or {},
                            difficulties = wppSpell.difficulties or {},
                            serverConfirmed = false,
                            lastCastTime = 0,
                            cooldownMin = wppSpell.cooldownMin or 0,
                            cooldownMax = wppSpell.cooldownMax or 0,
                            cooldownAvg = wppSpell.cooldownAvg or 0,
                            cooldownSamples = wppSpell.cooldownSamples or 0,
                        }
                        newSpells = newSpells + 1
                    else
                        -- Merge: keep higher counts, better cooldown data
                        local existing = creature.spells[spellId]
                        if (wppSpell.castCount or 0) > (existing.castCount or 0) then
                            existing.castCount = wppSpell.castCount
                        end
                        if (wppSpell.auraCount or 0) > (existing.auraCount or 0) then
                            existing.auraCount = wppSpell.auraCount
                        end
                        if (wppSpell.cooldownSamples or 0) > (existing.cooldownSamples or 0) then
                            existing.cooldownMin = wppSpell.cooldownMin or existing.cooldownMin
                            existing.cooldownMax = wppSpell.cooldownMax or existing.cooldownMax
                            existing.cooldownAvg = wppSpell.cooldownAvg or existing.cooldownAvg
                            existing.cooldownSamples = wppSpell.cooldownSamples or existing.cooldownSamples
                        end
                        if existing.school == 0 and (wppSpell.school or 0) ~= 0 then
                            existing.school = wppSpell.school
                        end
                    end
                end
            end
        end
    end

    -- Clear the import table so it doesn't re-merge next reload
    CreatureCodexWPP = nil

    return newCreatures, newSpells
end

-- ============================================================
-- Taint protection helpers
-- ============================================================

local function IsSecret(val)
    if issecretvalue and issecretvalue(val) then return true end
    if type(val) == "userdata" then return true end
    return false
end

local function SafeNumber(val)
    if not val or IsSecret(val) then return nil end
    return tonumber(tostring(val))
end

local function SafeString(val)
    if not val or IsSecret(val) then return nil end
    return tostring(val)
end

local function ExtractCreatureEntry(guid)
    if not guid then return nil end
    local unitType, _, _, _, _, npcID = strsplit("-", guid)
    if unitType == "Creature" or unitType == "Vehicle" then
        return tonumber(npcID)
    end
end

local function GetSafeSpellSchool(spellID)
    if not C_Spell or not C_Spell.GetSpellInfo then return 0 end
    local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
    if ok and info and info.spellSchool and not IsSecret(info.spellSchool) then
        return info.spellSchool
    end
    return 0
end

local function GetSafeSpellName(spellID)
    local name = "Unknown"
    local ok, result
    if C_Spell and C_Spell.GetSpellName then
        ok, result = pcall(C_Spell.GetSpellName, spellID)
        if ok and result and not IsSecret(result) then name = result end
    elseif C_Spell and C_Spell.GetSpellInfo then
        ok, result = pcall(C_Spell.GetSpellInfo, spellID)
        if ok and result and result.name and not IsSecret(result.name) then name = result.name end
    elseif GetSpellInfo then
        ok, result = pcall(GetSpellInfo, spellID)
        if ok and result and not IsSecret(result) then name = result end
    end
    return name
end

-- ============================================================
-- Core recording logic
-- ============================================================

local function RecordSpell(creatureEntry, spellID, spellSchool, creatureName, recordType, dedupKey, hpPct)
    if not CreatureCodexDB then return end
    if not creatureEntry or not spellID then return end
    if SPELL_BLACKLIST[spellID] then return end
    if CREATURE_BLACKLIST[creatureEntry] then return end

    -- Optional dedup (visual scraper uses it, server messages don't need it)
    if dedupKey then
        local dedupTable = (recordType == "aura") and activeAuras or activeCasts
        if dedupTable[dedupKey] then return end
        dedupTable[dedupKey] = GetTime()
    end

    local db = CreatureCodexDB.creatures
    local now = time()
    local name = creatureName or "Unknown"

    if not db[creatureEntry] then
        db[creatureEntry] = {
            name = name,
            spells = {},
            firstSeen = now,
            lastSeen = now,
        }
        sessionCreatures = sessionCreatures + 1
    end

    local creature = db[creatureEntry]
    creature.lastSeen = now
    if name ~= "Unknown" then creature.name = name end

    if not creature.spells[spellID] then
        creature.spells[spellID] = {
            name = GetSafeSpellName(spellID),
            school = spellSchool or GetSafeSpellSchool(spellID),
            castCount = 0,
            auraCount = 0,
            firstSeen = now,
            lastSeen = now,
            zones = {},
            difficulties = {},
            serverConfirmed = false,
            -- Timing intelligence
            lastCastTime = 0,
            cooldownMin = 0,
            cooldownMax = 0,
            cooldownAvg = 0,
            cooldownSamples = 0,
            -- HP phase tracking
            hpMin = nil,
            hpMax = nil,
        }
        sessionSpells = sessionSpells + 1
    end

    local spell = creature.spells[spellID]
    spell.lastSeen = now
    spell.zones[currentZone] = true
    spell.difficulties[currentDifficulty] = true

    if recordType == "aura" then
        spell.auraCount = (spell.auraCount or 0) + 1
        sessionAuras = sessionAuras + 1
    else
        spell.castCount = (spell.castCount or 0) + 1

        -- Cast timing intelligence
        local nowPrecise = GetTime()
        if spell.lastCastTime and spell.lastCastTime > 0 then
            local interval = nowPrecise - spell.lastCastTime
            if interval > 1 and interval < 300 then  -- Ignore <1s (dedup noise) and >5min (different pulls)
                local samples = (spell.cooldownSamples or 0)
                if samples == 0 or interval < (spell.cooldownMin or 999) then
                    spell.cooldownMin = interval
                end
                if samples == 0 or interval > (spell.cooldownMax or 0) then
                    spell.cooldownMax = interval
                end
                -- Running average
                local oldAvg = spell.cooldownAvg or 0
                spell.cooldownSamples = samples + 1
                spell.cooldownAvg = oldAvg + (interval - oldAvg) / spell.cooldownSamples
            end
        end
        spell.lastCastTime = nowPrecise
    end

    -- HP% phase tracking (from server messages)
    if hpPct and hpPct > 0 then
        if not spell.hpMin or hpPct < spell.hpMin then
            spell.hpMin = hpPct
        end
        if not spell.hpMax or hpPct > spell.hpMax then
            spell.hpMax = hpPct
        end
    end

    -- Update school if we got a real value and stored is 0
    if spell.school == 0 and spellSchool and spellSchool ~= 0 then
        spell.school = spellSchool
    end

    if debugMode then
        local src = dedupKey and "VIS" or "SRV"
        local label = recordType == "aura" and "AURA" or (recordType == "channel" and "CHAN" or "CAST")
        local hpStr = hpPct and format(" hp=%d%%", hpPct) or ""
        local cdStr = (spell.cooldownAvg or 0) > 0 and format(" cd=%.1fs", spell.cooldownAvg) or ""
        print(format("|cff00ccff[CC %s]|r %s entry=%d spell=%s[%d] school=%d%s%s",
            src, label, creatureEntry, tostring(spell.name), spellID, spell.school, hpStr, cdStr))
    end

    BumpRevision()
end

-- ============================================================
-- SERVER SNIFFER: Addon message handler (CCDX protocol)
-- ============================================================

local function HandleServerSpellMessage(msgType, entry, spellID, school, name, hpPct)
    entry = tonumber(entry)
    spellID = tonumber(spellID)
    school = tonumber(school) or 0
    hpPct = tonumber(hpPct)
    if not entry or not spellID then return end

    if not serverSnifferActive then
        serverSnifferActive = true
        print("|cff00ccff[CreatureCodex]|r |cff00ff00Server sniffer connected!|r Receiving all creature spell casts.")
    end

    sessionServerCasts = sessionServerCasts + 1

    local recordType = "cast"
    if msgType == "CF" then recordType = "channel" end
    if msgType == "AA" then recordType = "aura" end

    -- Server messages are already deduplicated (one per cast), no dedupKey needed
    RecordSpell(entry, spellID, school, name, recordType, nil, hpPct)
end

local function HandleSpellListMessage(entry, count, spellCSV)
    entry = tonumber(entry)
    if not entry or not spellCSV then return end

    -- Parse comma-separated spell IDs
    for sid in spellCSV:gmatch("(%d+)") do
        local spellID = tonumber(sid)
        if spellID and spellID > 0 then
            -- Mark as DB-known but don't increment castCount
            local db = CreatureCodexDB.creatures
            if db[entry] then
                if not db[entry].spells[spellID] then
                    db[entry].spells[spellID] = {
                        name = GetSafeSpellName(spellID),
                        school = GetSafeSpellSchool(spellID),
                        castCount = 0,
                        auraCount = 0,
                        firstSeen = time(),
                        lastSeen = time(),
                        zones = {},
                        difficulties = {},
                        serverConfirmed = true,
                        dbKnown = true,
                    }
                    sessionSpells = sessionSpells + 1
                else
                    db[entry].spells[spellID].dbKnown = true
                end
            end
        end
    end

    if debugMode then
        print(format("|cff00ccff[CC SRV]|r SPELL_LIST entry=%d count=%s", entry, tostring(count)))
    end
end

local function HandleCreatureInfoMessage(entry, name, faction, minLevel, maxLevel, classification)
    entry = tonumber(entry)
    if not entry then return end

    local db = CreatureCodexDB.creatures
    if db[entry] then
        if name and name ~= "" then db[entry].name = name end
        db[entry].faction = tonumber(faction)
        db[entry].minLevel = tonumber(minLevel)
        db[entry].maxLevel = tonumber(maxLevel)
        db[entry].classification = tonumber(classification)
    end
end

-- ============================================================
-- Zone completeness tracking
-- ============================================================

local zoneCreatureData = {}  -- [mapId] = { {entry, name, dbSpellCount}, ... }

local function HandleZoneCreaturesMessage(mapId, totalCount, creatureCSV)
    mapId = tonumber(mapId)
    if not mapId then return end

    if not zoneCreatureData[mapId] then
        zoneCreatureData[mapId] = {}
    end

    if not creatureCSV or creatureCSV == "" then return end

    for chunk in creatureCSV:gmatch("[^,]+") do
        local entry, name, spellCount = chunk:match("(%d+):([^:]*):(%d+)")
        if entry then
            zoneCreatureData[mapId][#zoneCreatureData[mapId] + 1] = {
                entry = tonumber(entry),
                name = name,
                dbSpellCount = tonumber(spellCount) or 0,
            }
        end
    end

    -- Print zone scan results to chat
    local db = CreatureCodexDB and CreatureCodexDB.creatures or {}
    local observed, withSpells, total = 0, 0, #zoneCreatureData[mapId]
    for _, creature in ipairs(zoneCreatureData[mapId]) do
        if db[creature.entry] then
            observed = observed + 1
            local spellCount = 0
            for _ in pairs(db[creature.entry].spells or {}) do spellCount = spellCount + 1 end
            if spellCount > 0 then withSpells = withSpells + 1 end
        end
    end
    local pct = total > 0 and (withSpells / total * 100) or 0
    print(format("|cff00ccff[CreatureCodex]|r |cff00ff00Zone scan complete:|r %d creatures in zone.", total))
    print(format("|cff00ccff[CreatureCodex]|r  |cff00ff00With spells:|r %d/%d (%.0f%%)  |  |cffffff00Seen:|r %d  |  |cffff4444Missing:|r %d",
        withSpells, total, pct, observed, total - observed))

    -- Notify UI to refresh if open
    if CreatureCodex_OnZoneScanComplete then
        CreatureCodex_OnZoneScanComplete(mapId)
    end

    if debugMode then
        print(format("|cff00ccff[CC SRV]|r ZONE_CREATURES map=%d total=%s", mapId, tostring(totalCount)))
    end
end

function CreatureCodex_RequestZoneCreatures(mapId)
    if not mapId then
        -- GetInstanceInfo() returns the actual instance map ID the server uses
        local instanceMapId = select(8, GetInstanceInfo())
        if not instanceMapId or instanceMapId < 0 then return end
        mapId = instanceMapId
    end
    zoneCreatureData[mapId] = {}
    C_ChatInfo.SendAddonMessage(CCDX_PREFIX, "ZC|" .. mapId, "WHISPER", UnitName("player"))
end

function CreatureCodex_GetZoneData(mapId)
    return zoneCreatureData[mapId]
end

function CreatureCodex_GetZoneCompleteness(mapId)
    local zoneData = zoneCreatureData[mapId]
    if not zoneData or #zoneData == 0 then return 0, 0, 0 end

    local total = #zoneData
    local observed = 0
    local db = CreatureCodexDB and CreatureCodexDB.creatures or {}

    for _, creature in ipairs(zoneData) do
        if db[creature.entry] then
            local spellCount = 0
            for _ in pairs(db[creature.entry].spells or {}) do
                spellCount = spellCount + 1
            end
            if spellCount > 0 then
                observed = observed + 1
            end
        end
    end

    return observed, total, (total > 0) and (observed / total * 100) or 0
end

-- ============================================================
-- Multi-player aggregation: submit local data to server
-- ============================================================

function CreatureCodex_SubmitAggregation()
    if not CreatureCodexDB or not CreatureCodexDB.creatures then return 0 end

    local submitted = 0
    for entry, creature in pairs(CreatureCodexDB.creatures) do
        local spellParts = {}
        for spellId, spell in pairs(creature.spells or {}) do
            local count = (spell.castCount or 0) + (spell.auraCount or 0)
            if count > 0 then
                spellParts[#spellParts + 1] = spellId .. ":" .. count
            end
        end

        if #spellParts > 0 then
            -- Split into chunks that fit in 255 bytes
            local header = "AG|" .. entry .. "|"
            local batch = {}
            local batchLen = 0

            for _, sp in ipairs(spellParts) do
                local addition = (batchLen > 0) and ("," .. sp) or sp
                if #header + batchLen + #addition > 250 then
                    C_ChatInfo.SendAddonMessage(CCDX_PREFIX, header .. table.concat(batch, ","), "WHISPER", UnitName("player"))
                    batch = { sp }
                    batchLen = #sp
                    submitted = submitted + 1
                else
                    batch[#batch + 1] = sp
                    batchLen = batchLen + #addition
                end
            end
            if #batch > 0 then
                C_ChatInfo.SendAddonMessage(CCDX_PREFIX, header .. table.concat(batch, ","), "WHISPER", UnitName("player"))
                submitted = submitted + 1
            end
        end
    end

    print(format("|cff00ccff[CreatureCodex]|r Submitted aggregation data (%d messages).", submitted))
    return submitted
end

local function OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= CCDX_PREFIX then return end
    if not message or message == "" then return end

    -- Parse pipe-delimited message
    local parts = {}
    for part in message:gmatch("[^|]+") do
        parts[#parts + 1] = part
    end

    local msgType = parts[1]
    if not msgType then return end

    if msgType == "SC" or msgType == "SS" or msgType == "CF" or msgType == "AA" then
        -- SC|entry|spellID|school|name|hp%
        HandleServerSpellMessage(msgType, parts[2], parts[3], parts[4], parts[5], parts[6])

    elseif msgType == "SL" then
        -- SL|entry|count|spellID1,spellID2,...
        HandleSpellListMessage(parts[2], parts[3], parts[4])

    elseif msgType == "CI" then
        -- CI|entry|name|faction|minLevel|maxLevel|classification
        HandleCreatureInfoMessage(parts[2], parts[3], parts[4], parts[5], parts[6], parts[7])

    elseif msgType == "ZC" then
        -- ZC|mapId|totalCreatures|entry1:name1:spellCount1,...
        HandleZoneCreaturesMessage(parts[2], parts[3], parts[4])

    elseif msgType == "AR" then
        -- AR|entry|OK — aggregation acknowledgement
        if debugMode then
            print(format("|cff00ccff[CC SRV]|r AGGREGATE confirmed for entry=%s", tostring(parts[2])))
        end
    end
end

-- Request spell list from server for a given creature entry
local lastTargetEntry = nil
local lastTargetTime = 0
local function RequestSpellList(entry)
    local now = GetTime()
    if not entry or (entry == lastTargetEntry and now - lastTargetTime < 5) then return end
    lastTargetEntry = entry
    lastTargetTime = now
    C_ChatInfo.SendAddonMessage(CCDX_PREFIX, "SL|" .. entry, "WHISPER", UnitName("player"))
    C_ChatInfo.SendAddonMessage(CCDX_PREFIX, "CI|" .. entry, "WHISPER", UnitName("player"))
end

-- ============================================================
-- VISUAL SCRAPER: Cast/Channel per-unit (fallback + confirmation)
-- ============================================================

local function ScrapeUnitCasts(unit)
    if not UnitExists(unit) then return end

    -- Cast check
    local castName, _, _, _, _, _, castID, _, castSpellID = UnitCastingInfo(unit)
    if castSpellID and castID and not IsSecret(castSpellID) and not IsSecret(castID) then
        local safeID = SafeNumber(castSpellID)
        if safeID then
            local guid = UnitGUID(unit)
            if guid and not IsSecret(guid) and not UnitIsPlayer(unit) then
                local entry = ExtractCreatureEntry(guid)
                if entry then
                    local key = unit .. "_c_" .. tostring(castID)
                    local name = SafeString(UnitName(unit)) or "Unknown"
                    RecordSpell(entry, safeID, nil, name, "cast", key)
                end
            end
        end
    end

    -- Channel check (separate — don't early-return)
    local chanName, _, _, startTimeMS, _, _, _, chanSpellID = UnitChannelInfo(unit)
    if chanSpellID and not IsSecret(chanSpellID) then
        local safeID = SafeNumber(chanSpellID)
        if safeID then
            local guid = UnitGUID(unit)
            if guid and not IsSecret(guid) and not UnitIsPlayer(unit) then
                local entry = ExtractCreatureEntry(guid)
                if entry then
                    local key = unit .. "_h_" .. tostring(chanSpellID) .. "_" .. tostring(startTimeMS or 0)
                    local name = SafeString(UnitName(unit)) or "Unknown"
                    RecordSpell(entry, safeID, nil, name, "channel", key)
                end
            end
        end
    end
end

-- ============================================================
-- VISUAL SCRAPER: Aura per-unit (round-robin)
-- ============================================================

local function RebuildNameplateScanList()
    wipe(nameplateScanList)
    for unit in pairs(activeNameplates) do
        nameplateScanList[#nameplateScanList + 1] = unit
    end
    nameplateScanList[#nameplateScanList + 1] = "target"
    nameplateScanList[#nameplateScanList + 1] = "focus"
    nameplateScanDirty = false
end

local function ScrapeUnitAuras(unit)
    if not UnitExists(unit) then return end
    if UnitIsPlayer(unit) then return end

    local guid = UnitGUID(unit)
    if not guid or IsSecret(guid) then return end
    local entry = ExtractCreatureEntry(guid)
    if not entry then return end

    local name = SafeString(UnitName(unit)) or "Unknown"

    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for _, filter in ipairs({"HARMFUL", "HELPFUL"}) do
            for i = 1, 40 do
                local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
                if not ok or not aura then break end
                if aura.spellId and not IsSecret(aura.spellId) then
                    local auraInstance = aura.auraInstanceID or aura.spellId
                    local key = unit .. "_a_" .. tostring(aura.spellId) .. "_" .. tostring(auraInstance)
                    RecordSpell(entry, aura.spellId, nil, name, "aura", key)
                end
            end
        end
    elseif UnitAura then
        for i = 1, 40 do
            local auraName, _, _, _, _, _, _, _, _, spellId = UnitAura(unit, i, "HARMFUL")
            if not auraName then break end
            if spellId and not IsSecret(spellId) then
                local key = unit .. "_a_" .. tostring(spellId)
                RecordSpell(entry, spellId, nil, name, "aura", key)
            end
        end
    end
end

-- ============================================================
-- Main OnUpdate loop
-- ============================================================

local function ScrapeAllCasts()
    for _, unit in ipairs(SCAN_UNITS) do
        ScrapeUnitCasts(unit)
    end
end

local function ScrapeOneAuraTarget()
    if nameplateScanDirty then RebuildNameplateScanList() end
    if #nameplateScanList == 0 then return end

    auraScanIndex = auraScanIndex + 1
    if auraScanIndex > #nameplateScanList then auraScanIndex = 1 end

    local unit = nameplateScanList[auraScanIndex]
    if unit then
        pcall(ScrapeUnitAuras, unit)
    end
end

local function EvictStaleDedups()
    local cutoff = GetTime() - EVICT_AGE
    for k, t in pairs(activeCasts) do
        if t < cutoff then activeCasts[k] = nil end
    end
    for k, t in pairs(activeAuras) do
        if t < cutoff then activeAuras[k] = nil end
    end
end

local function OnUpdate(self, elapsed)
    updateThrottle = updateThrottle + elapsed
    auraScanTimer = auraScanTimer + elapsed
    sweepTimer = sweepTimer + elapsed

    -- Evict stale dedup entries
    if sweepTimer >= SWEEP_INTERVAL then
        sweepTimer = 0
        EvictStaleDedups()
    end

    -- Visual cast scrape at 10 Hz
    if updateThrottle >= CAST_TICK_RATE then
        updateThrottle = 0
        pcall(ScrapeAllCasts)
    end

    -- Visual aura scrape at 5 Hz (one unit per tick)
    if auraScanTimer >= AURA_TICK_RATE then
        auraScanTimer = 0
        ScrapeOneAuraTarget()
    end
end

-- ============================================================
-- Zone tracking
-- ============================================================

local function UpdateZoneCache()
    local z = GetRealZoneText()
    currentZone = (z and z ~= "") and z or "Unknown"
    currentDifficulty = select(3, GetInstanceInfo()) or 0
end

-- ============================================================
-- Public API
-- ============================================================

local function CountDB()
    if not CreatureCodexDB then return 0, 0 end
    local creatures, spells = 0, 0
    for _, c in pairs(CreatureCodexDB.creatures or {}) do
        creatures = creatures + 1
        for _ in pairs(c.spells or {}) do
            spells = spells + 1
        end
    end
    return creatures, spells
end

function CreatureCodex_CountDB() return CountDB() end
function CreatureCodex_GetSessionStats() return sessionCreatures, sessionSpells, sessionAuras end
function CreatureCodex_GetServerStats() return sessionServerCasts, serverSnifferActive end
function CreatureCodex_ToggleDebug() debugMode = not debugMode end
function CreatureCodex_IsDebug() return debugMode end

function CreatureCodex_IgnoreSpell(spellId, spellName)
    SPELL_BLACKLIST[spellId] = true
    if CreatureCodexDB then
        CreatureCodexDB.spellBlacklist[spellId] = true
        if not CreatureCodexDB.ignoredSpells then CreatureCodexDB.ignoredSpells = {} end
        CreatureCodexDB.ignoredSpells[spellId] = { name = spellName or ("Spell " .. spellId), ignoredAt = time() }
    end
end

function CreatureCodex_UnignoreSpell(spellId)
    if not CreatureCodexDB then return end
    SPELL_BLACKLIST[spellId] = nil
    CreatureCodexDB.spellBlacklist[spellId] = nil
    if CreatureCodexDB.ignoredSpells then
        CreatureCodexDB.ignoredSpells[spellId] = nil
    end
end

function CreatureCodex_GetIgnoredCreatures()
    return CreatureCodexDB and CreatureCodexDB.ignored or {}
end

function CreatureCodex_GetIgnoredSpells()
    return CreatureCodexDB and CreatureCodexDB.ignoredSpells or {}
end

-- Legacy alias
function CreatureCodex_GetIgnoredList()
    return CreatureCodex_GetIgnoredCreatures()
end

function CreatureCodex_UnignoreCreature(entry)
    if not CreatureCodexDB then return end
    CreatureCodexDB.creatureBlacklist[entry] = nil
    CREATURE_BLACKLIST[entry] = nil
    if CreatureCodexDB.ignored then
        CreatureCodexDB.ignored[entry] = nil
    end
end

function CreatureCodex_SaveExport(exportType, text)
    if not CreatureCodexDB then return end
    if not CreatureCodexDB.exports then CreatureCodexDB.exports = {} end
    CreatureCodexDB.exports[exportType] = {
        text = text,
        generatedAt = time(),
        sourceRevision = dataRevision,
    }
end

function CreatureCodex_GetSavedExport(exportType)
    if not CreatureCodexDB or not CreatureCodexDB.exports then return nil end
    return CreatureCodexDB.exports[exportType]
end

-- Addon Compartment
function CreatureCodex_OnCompartmentClick(_, buttonName)
    if buttonName == "RightButton" then
        CreatureCodex_Export()
    else
        CreatureCodex_ToggleUI()
    end
end

function CreatureCodex_OnCompartmentEnter(_, menuButtonFrame)
    GameTooltip:SetOwner(menuButtonFrame, "ANCHOR_LEFT")
    GameTooltip:SetText("CreatureCodex", 0, 0.8, 1)
    local totalC, totalS = CountDB()
    GameTooltip:AddLine(totalC .. " creatures, " .. totalS .. " spells tracked", 1, 1, 1)
    local sc, ss, sa = sessionCreatures, sessionSpells, sessionAuras
    if sc > 0 or ss > 0 then
        GameTooltip:AddLine("Session: +" .. sc .. " creatures, +" .. ss .. " spells, +" .. (sa or 0) .. " auras", 0.5, 1, 0.5)
    end
    if serverSnifferActive then
        GameTooltip:AddLine("Server sniffer: ACTIVE (" .. sessionServerCasts .. " casts)", 0, 1, 0)
    else
        GameTooltip:AddLine("Server sniffer: waiting for data...", 0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cff00ff00Left-click|r Browser  |cff00ff00Right-click|r Export", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

function CreatureCodex_OnCompartmentLeave()
    GameTooltip:Hide()
end

-- ============================================================
-- Reset dialog
-- ============================================================

StaticPopupDialogs["CREATURECODEX_RESET"] = {
    text = "Reset all CreatureCodex data? This cannot be undone.",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function()
        if not CreatureCodexDB then return end
        local totalC, totalS = CountDB()
        CreatureCodexDB.creatures = {}
        sessionCreatures, sessionSpells, sessionAuras, sessionServerCasts = 0, 0, 0, 0
        wipe(activeCasts)
        wipe(activeAuras)
        if CreatureCodexBrowserFrame and CreatureCodexBrowserFrame:IsShown() then
            CreatureCodexBrowserFrame:Hide()
            CreatureCodex_ToggleUI()
        end
        print("|cff00ccff[CreatureCodex]|r Reset. Cleared " .. totalC .. " creatures, " .. totalS .. " spell pairs.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

-- ============================================================
-- Event handler + bootstrap
-- ============================================================

frame:SetScript("OnUpdate", OnUpdate)

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        InitDB()

        -- Auto-merge WPP sniff data if present
        local wppC, wppS = MergeWPPData()
        if wppC > 0 or wppS > 0 then
            print(format("|cff00ccff[CreatureCodex]|r |cff00ff00Imported sniff data:|r +%d creatures, +%d spells from WPP.", wppC, wppS))
        end

        UpdateZoneCache()
        CreatureCodex_InitMinimap()

        -- Register addon message prefix for server sniffer
        C_ChatInfo.RegisterAddonMessagePrefix(CCDX_PREFIX)

        frame:RegisterEvent("CHAT_MSG_ADDON")
        frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        frame:RegisterEvent("PLAYER_DIFFICULTY_CHANGED")
        frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
        frame:RegisterEvent("PLAYER_TARGET_CHANGED")

        local totalC, totalS = CountDB()
        print("|cff00ccff[CreatureCodex]|r v" .. ADDON_VERSION .. " loaded. " .. totalC .. " creatures, " .. totalS .. " spells tracked.")
        print("|cff00ccff[CreatureCodex]|r  Visual scraper: 10Hz casts + 5Hz aura round-robin.")
        print("|cff00ccff[CreatureCodex]|r  Server sniffer: listening on CCDX channel...")

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = ...
        OnAddonMessage(prefix, message, channel, sender)

    elseif event == "PLAYER_TARGET_CHANGED" then
        -- When targeting a creature, request its spell list from the server
        if UnitExists("target") and not UnitIsPlayer("target") then
            local guid = UnitGUID("target")
            if guid and not IsSecret(guid) then
                local entry = ExtractCreatureEntry(guid)
                if entry and not CREATURE_BLACKLIST[entry] then
                    -- Ensure creature exists in DB before requesting
                    local db = CreatureCodexDB.creatures
                    if not db[entry] then
                        local name = SafeString(UnitName("target")) or "Unknown"
                        db[entry] = {
                            name = name,
                            spells = {},
                            firstSeen = time(),
                            lastSeen = time(),
                        }
                        sessionCreatures = sessionCreatures + 1
                    end
                    RequestSpellList(entry)
                end
            end
        end

    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_DIFFICULTY_CHANGED" then
        UpdateZoneCache()

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        local unit = ...
        if unit then
            activeNameplates[unit] = true
            nameplateScanDirty = true
        end

    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        local unit = ...
        if unit then
            activeNameplates[unit] = nil
            nameplateScanDirty = true
        end
    end
end)

frame:RegisterEvent("PLAYER_LOGIN")

-- ============================================================
-- Slash commands
-- ============================================================

SLASH_CREATURECODEX1 = "/codex"
SLASH_CREATURECODEX2 = "/cc"
SlashCmdList["CREATURECODEX"] = function(msg)
    msg = strtrim((msg or ""):lower())

    if msg == "" or msg == "browser" or msg == "ui" then
        CreatureCodex_ToggleUI()
    elseif msg == "export" then
        CreatureCodex_Export()
    elseif msg == "debug" then
        CreatureCodex_ToggleDebug()
        print("|cff00ccff[CreatureCodex]|r Debug " .. (CreatureCodex_IsDebug() and "ON" or "OFF"))
    elseif msg == "reset" then
        StaticPopup_Show("CREATURECODEX_RESET")
    elseif msg == "zone" then
        CreatureCodex_RequestZoneCreatures()
        print("|cff00ccff[CreatureCodex]|r Requesting zone data from server... (requires Eluna server script)")
    elseif msg == "submit" or msg == "aggregate" then
        print("|cff00ccff[CreatureCodex]|r Submitting aggregation data... (requires Eluna server script)")
        CreatureCodex_SubmitAggregation()
    elseif msg == "stats" then
        local totalC, totalS = CreatureCodex_CountDB()
        local sc, ss, sa = CreatureCodex_GetSessionStats()
        local srvCasts, srvActive = CreatureCodex_GetServerStats()
        print("|cff00ccff[CreatureCodex]|r Stats:")
        print(format("  Total: %d creatures, %d spells", totalC, totalS))
        print(format("  Session: +%d creatures, +%d spells, +%d auras", sc, ss, sa))
        print(format("  Server sniffer: %s (%d casts received)", srvActive and "ACTIVE" or "inactive", srvCasts))
    elseif msg == "sync" then
        print("|cff00ccff[CreatureCodex]|r Reloading to import WPP sniff data...")
        print("|cff00ccff[CreatureCodex]|r  (WPP data auto-merges on login. Use /cc sync only after running wpp_import.py --addon)")
        ReloadUI()
    else
        print("|cff00ccff[CreatureCodex]|r Commands:")
        print("  /cc — Toggle browser")
        print("  /cc export — Export window")
        print("  /cc debug — Toggle debug output")
        print("  /cc stats — Show statistics")
        print("  /cc sync — Reload UI to import WPP sniff data (run wpp_import.py --addon first)")
        print("  /cc zone — Query zone creatures from server (requires Eluna)")
        print("  /cc submit — Submit data to server aggregation (requires Eluna)")
        print("  /cc reset — Reset all data")
    end
end
