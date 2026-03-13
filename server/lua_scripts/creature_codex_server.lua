--[[
    CreatureCodex Server-Side Eluna Script

    Handles addon message requests from the CreatureCodex client addon:
    - "SL|entry" => Sends back the creature's full spell list from creature_template_spell
    - "CI|entry" => Sends back creature info (faction, level, classification)
    - "ZC|mapId" => Sends back all creatures in a zone with spell counts
    - "AG|entry|spellData" => Stores aggregated spell discoveries server-side

    Works alongside the C++ UnitScript hooks that broadcast real-time spell casts.
]]

local PREFIX = "CCDX"
local WHISPER = 7  -- ChatMsg::CHAT_MSG_WHISPER

-- Cache creature spell lists to avoid repeated DB queries (cleared on reload)
local spellListCache = {}

local function SendAddonMsg(player, msg)
    -- Truncate to addon message size limit
    if #msg > 255 then msg = msg:sub(1, 255) end
    player:SendAddonMessage(PREFIX, msg, WHISPER, player)
end

local function HandleSpellListRequest(player, entry)
    entry = tonumber(entry)
    if not entry or entry <= 0 then return end

    -- Check cache first
    if spellListCache[entry] then
        for _, msg in ipairs(spellListCache[entry]) do
            SendAddonMsg(player, msg)
        end
        return
    end

    -- Query creature_template_spell for all known spells
    local query = WorldDBQuery(string.format(
        "SELECT Spell FROM creature_template_spell WHERE CreatureID = %d ORDER BY `Index`", entry))

    if not query then
        -- No spells in DB — send empty response so client knows we checked
        local msg = "SL|" .. entry .. "|0"
        spellListCache[entry] = { msg }
        SendAddonMsg(player, msg)
        return
    end

    -- Collect all spell IDs
    local spells = {}
    repeat
        local spellId = query:GetUInt32(0)
        if spellId and spellId > 0 then
            spells[#spells + 1] = tostring(spellId)
        end
    until not query:NextRow()

    -- Build messages (split across multiple if needed due to 255 byte limit)
    -- Format: SL|entry|count|spellID1,spellID2,...
    local msgs = {}
    local batch = {}
    local batchLen = 0
    local header = "SL|" .. entry .. "|" .. #spells .. "|"

    for i, sid in ipairs(spells) do
        local addition = (batchLen > 0) and ("," .. sid) or sid
        if #header + batchLen + #addition > 250 then
            -- Flush current batch
            msgs[#msgs + 1] = header .. table.concat(batch, ",")
            batch = { sid }
            batchLen = #sid
        else
            batch[#batch + 1] = sid
            batchLen = batchLen + #addition
        end
    end

    if #batch > 0 then
        msgs[#msgs + 1] = header .. table.concat(batch, ",")
    end

    -- Cache and send
    spellListCache[entry] = msgs
    for _, msg in ipairs(msgs) do
        SendAddonMsg(player, msg)
    end
end

local function HandleCreatureInfoRequest(player, entry)
    entry = tonumber(entry)
    if not entry or entry <= 0 then return end

    local query = WorldDBQuery(string.format(
        "SELECT Name, faction, minlevel, maxlevel, Classification FROM creature_template WHERE entry = %d", entry))

    if not query then return end

    local name = query:GetString(0)
    local faction = query:GetUInt32(1)
    local minLevel = query:GetUInt32(2)
    local maxLevel = query:GetUInt32(3)
    local classification = query:GetUInt32(4)

    -- CI|entry|name|faction|minLevel|maxLevel|classification
    local msg = string.format("CI|%d|%s|%d|%d|%d|%d", entry, name, faction, minLevel, maxLevel, classification)
    SendAddonMsg(player, msg)
end

-- ============================================================
-- Zone Completeness: query all creatures in a zone/map
-- ============================================================

local function HandleZoneCreaturesRequest(player, mapId)
    mapId = tonumber(mapId)
    if not mapId or mapId <= 0 then return end

    -- Query creature_template entries that spawn in this map
    local query = WorldDBQuery(string.format(
        "SELECT DISTINCT ct.entry, ct.Name, " ..
        "(SELECT COUNT(*) FROM creature_template_spell WHERE CreatureID = ct.entry) AS spellCount " ..
        "FROM creature c " ..
        "JOIN creature_template ct ON c.id = ct.entry " ..
        "WHERE c.map = %d AND ct.npcflag = 0 " ..
        "ORDER BY ct.Name LIMIT 200", mapId))

    if not query then
        SendAddonMsg(player, "ZC|" .. mapId .. "|0")
        return
    end

    -- Build response: ZC|mapId|totalCreatures|entry1:name1:spellCount1,entry2:name2:spellCount2,...
    local entries = {}
    local total = 0
    repeat
        local entry = query:GetUInt32(0)
        local name = query:GetString(1)
        local spellCount = query:GetUInt32(2)
        entries[#entries + 1] = entry .. ":" .. name .. ":" .. spellCount
        total = total + 1
    until not query:NextRow()

    -- Split across multiple messages if needed
    local header = "ZC|" .. mapId .. "|" .. total .. "|"
    local batch = {}
    local batchLen = 0
    for _, e in ipairs(entries) do
        local addition = (batchLen > 0) and ("," .. e) or e
        if #header + batchLen + #addition > 250 then
            SendAddonMsg(player, header .. table.concat(batch, ","))
            batch = { e }
            batchLen = #e
        else
            batch[#batch + 1] = e
            batchLen = batchLen + #addition
        end
    end
    if #batch > 0 then
        SendAddonMsg(player, header .. table.concat(batch, ","))
    end
end

-- ============================================================
-- Multi-player Aggregation: store discoveries server-side
-- ============================================================

local function HandleAggregateSubmit(player, payload)
    -- Format: AG|entry|spellId1:count1,spellId2:count2,...
    local entryStr, spellData = payload:match("^(%d+)|(.+)$")
    local entry = tonumber(entryStr)
    if not entry or not spellData then return end

    local playerName = player:GetName()
    local now = os.time()

    for chunk in spellData:gmatch("[^,]+") do
        local spellId, count = chunk:match("(%d+):(%d+)")
        spellId = tonumber(spellId)
        count = tonumber(count)
        if spellId and count and count > 0 then
            -- Insert or update in codex_aggregated (must exist in the characters DB)
            CharDBExecute(string.format(
                "INSERT INTO codex_aggregated (creature_entry, spell_id, cast_count, last_reporter, last_seen) " ..
                "VALUES (%d, %d, %d, '%s', %d) " ..
                "ON DUPLICATE KEY UPDATE cast_count = GREATEST(cast_count, VALUES(cast_count)), " ..
                "last_reporter = VALUES(last_reporter), last_seen = VALUES(last_seen)",
                entry, spellId, count, playerName:gsub("\\", ""):gsub("'", ""), now))
        end
    end

    SendAddonMsg(player, "AR|" .. entry .. "|OK")
end

-- Listen for addon messages from CreatureCodex clients
RegisterServerEvent(30, function(event, sender, msgType, prefix, msg, target) -- 30 = ADDON_EVENT_ON_MESSAGE
    if prefix ~= PREFIX then return end
    if not sender then return end

    local cmd, payload = msg:match("^(%u+)|(.+)$")
    if not cmd then return end

    if cmd == "SL" then
        HandleSpellListRequest(sender, payload)
    elseif cmd == "CI" then
        HandleCreatureInfoRequest(sender, payload)
    elseif cmd == "ZC" then
        HandleZoneCreaturesRequest(sender, payload)
    elseif cmd == "AG" then
        HandleAggregateSubmit(sender, payload)
    end
end)

print("[CreatureCodex] Server-side Eluna sniffer loaded (v2: zone completeness + aggregation).")
