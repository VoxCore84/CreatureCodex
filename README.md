# CreatureCodex

Server-assisted creature spell & aura sniffer for TrinityCore-based WoW emulators.

CreatureCodex captures every spell cast, channel, and aura application from creatures — including instant/hidden casts the client API can't see — and stores them in a browsable database you can export as SQL for `creature_template_spell` or SmartAI.

## How It Works

CreatureCodex has two layers:

1. **Client-side visual scraper** (works everywhere, no server patches needed)
   - Polls `UnitCastingInfo`/`UnitChannelInfo` at 10 Hz for spell casts
   - Round-robin scans nameplates for auras at 5 Hz
   - Records spell name, school, creature entry, health %, and timestamps

2. **Server-side sniffer** (requires TrinityCore C++ hooks)
   - Four `UnitScript` hooks broadcast every creature spell event as addon messages
   - Catches 100% of casts including instant/hidden ones the client never sees
   - Broadcasts only to nearby players (100 yd) who have CreatureCodex installed

When both layers run together, the addon deduplicates automatically — you get complete coverage with zero gaps.

## Client-Only Install (No Server Patches)

If you just want the visual scraper without modifying your server:

1. Copy the `client/` folder contents into:
   ```
   Interface\AddOns\CreatureCodex\
   ```
2. The folder should contain: `CreatureCodex.toc`, `CreatureCodex.lua`, `Export.lua`, `UI.lua`, `Minimap.lua`, and the `Libs/` folder.
3. Log in. The addon registers automatically via Addon Compartment and minimap button.
4. Walk near creatures and observe them fighting — spells are captured in real time.

**What you get**: Visible casts and channels (anything the WoW API can detect).
**What you miss**: Instant casts, hidden spells, and auras applied without visible cast bars.

## Full Install (Server + Client)

### Prerequisites

- TrinityCore `master` branch (12.x / The War Within)
- C++20 compiler (MSVC 2022+, GCC 13+, Clang 16+)
- Eluna Lua Engine (optional, for spell list queries and aggregation)

### Step 1: Add Core Hooks to ScriptMgr

These four virtual methods must be added to `UnitScript` in your ScriptMgr. If you already have custom hooks, just add these to the existing class.

**`src/server/game/Scripting/ScriptMgr.h`** — Add to `class UnitScript`:
```cpp
// CreatureCodex hooks
virtual void OnCreatureSpellCast(Creature* /*creature*/, SpellInfo const* /*spell*/) {}
virtual void OnCreatureSpellStart(Creature* /*creature*/, SpellInfo const* /*spell*/) {}
virtual void OnCreatureChannelFinished(Creature* /*creature*/, SpellInfo const* /*spell*/) {}
virtual void OnAuraApply(Unit* /*target*/, AuraApplication* /*aurApp*/) {}
```

**`src/server/game/Scripting/ScriptMgr.cpp`** — Add the FOREACH_SCRIPT dispatchers:
```cpp
void ScriptMgr::OnCreatureSpellCast(Creature* creature, SpellInfo const* spell)
{
    FOREACH_SCRIPT(UnitScript, [&](UnitScript* script) { script->OnCreatureSpellCast(creature, spell); });
}

void ScriptMgr::OnCreatureSpellStart(Creature* creature, SpellInfo const* spell)
{
    FOREACH_SCRIPT(UnitScript, [&](UnitScript* script) { script->OnCreatureSpellStart(creature, spell); });
}

void ScriptMgr::OnCreatureChannelFinished(Creature* creature, SpellInfo const* spell)
{
    FOREACH_SCRIPT(UnitScript, [&](UnitScript* script) { script->OnCreatureChannelFinished(creature, spell); });
}

void ScriptMgr::OnAuraApply(Unit* target, AuraApplication* aurApp)
{
    FOREACH_SCRIPT(UnitScript, [&](UnitScript* script) { script->OnAuraApply(target, aurApp); });
}
```

Also add the declarations to the `ScriptMgr` class in the header:
```cpp
void OnCreatureSpellCast(Creature* creature, SpellInfo const* spell);
void OnCreatureSpellStart(Creature* creature, SpellInfo const* spell);
void OnCreatureChannelFinished(Creature* creature, SpellInfo const* spell);
void OnAuraApply(Unit* target, AuraApplication* aurApp);
```

### Step 2: Wire the Hooks into Spell.cpp and Unit.cpp

**`src/server/game/Spells/Spell.cpp`** — In `Spell::SendSpellGo()` (after the packet is sent):
```cpp
if (Creature* creature = m_caster->ToCreature())
    sScriptMgr->OnCreatureSpellCast(creature, m_spellInfo);
```

**`src/server/game/Spells/Spell.cpp`** — At the start of `Spell::cast()` (after the initial checks):
```cpp
if (Creature* creature = m_caster->ToCreature())
    sScriptMgr->OnCreatureSpellStart(creature, m_spellInfo);
```

**`src/server/game/Spells/Spell.cpp`** — In `Spell::SendChannelUpdate()` when `time == 0`:
```cpp
if (Creature* creature = m_caster->ToCreature())
    sScriptMgr->OnCreatureChannelFinished(creature, m_spellInfo);
```

**`src/server/game/Entities/Unit/Unit.cpp`** — In `Unit::_ApplyAura()` (after the aura application succeeds):
```cpp
sScriptMgr->OnAuraApply(this, aurApp);
```

### Step 3: Add IsAddonRegistered Helper

The sniffer checks if a player has the `CCDX` addon prefix registered before sending them data. Add this to `WorldSession`:

**`src/server/game/Server/WorldSession.h`**:
```cpp
bool IsAddonRegistered(std::string_view prefix) const;
```

**`src/server/game/Server/WorldSession.cpp`**:
```cpp
bool WorldSession::IsAddonRegistered(std::string_view prefix) const
{
    for (auto const& p : _registeredAddonPrefixes)
        if (p == prefix)
            return true;
    return false;
}
```

### Step 4: Add RBAC Permission

**`src/server/game/Accounts/RBAC.h`** — Add to the permission enum:
```cpp
RBAC_PERM_COMMAND_CREATURE_CODEX = 3012,
```

Then apply the SQL:
```
mysql -u root -p auth < sql/auth_rbac_creature_codex.sql
```

### Step 5: Copy the Sniffer Scripts

1. Copy `server/Custom/creature_codex_sniffer.cpp` and `server/Custom/cs_creature_codex.cpp` to your `src/server/scripts/Custom/` directory.

2. Register them in `custom_script_loader.cpp`:
   ```cpp
   void AddSC_creature_codex_sniffer();
   void AddSC_creature_codex_commands();

   void AddCustomScripts()
   {
       // ... your existing scripts ...
       AddSC_creature_codex_sniffer();
       AddSC_creature_codex_commands();
   }
   ```

### Step 6: (Optional) Eluna Server Scripts

If you use Eluna, copy `server/lua_scripts/creature_codex_server.lua` to your Eluna scripts directory. This adds:
- **Spell list queries**: Addon can request the full spell list for any creature from `creature_template_spell`
- **Creature info**: Name, faction, level range, classification
- **Zone completeness**: Query all creatures in a map with their known spell counts
- **Multi-player aggregation**: Players can submit discoveries to a shared server-side table

For aggregation, apply the SQL:
```
mysql -u root -p roleplay < sql/roleplay_codex_aggregated.sql
```

(Or whichever database you use for custom tables.)

### Step 7: Install the Client Addon

Copy `client/` contents to `Interface\AddOns\CreatureCodex\` and rebuild your server.

## Usage

### Slash Commands

| Command | Description |
|---------|-------------|
| `/cc` or `/codex` | Toggle the browser panel |
| `/cc export` | Open the export panel |
| `/cc wipe` | Clear all stored data |
| `/cc search <name>` | Search creatures by name |
| `/cc zone` | Show only creatures from your current zone |
| `/cc stats` | Print capture statistics |

### GM Commands (requires RBAC 3012)

| Command | Description |
|---------|-------------|
| `.codex query <entry>` | Show all spells for a creature entry |
| `.codex stats` | Show sniffer statistics (online players, addon users, blacklist size) |
| `.codex blacklist add <spellId>` | Add a spell to the runtime broadcast blacklist |
| `.codex blacklist remove <spellId>` | Remove a spell from the blacklist |
| `.codex blacklist list` | Show all runtime-blacklisted spells |

### Export Formats

The export panel offers four tabs:

1. **Raw** — Plain text: `CreatureName (entry) - SpellName [spellId] x castCount`
2. **SQL** — `INSERT INTO creature_template_spell` statements ready to apply
3. **SmartAI** — `INSERT INTO smart_scripts` for AI-driven casting
4. **New Only** — Same as SQL but filters to spells not already in `creature_template_spell`

### Minimap Button

Left-click opens the browser. Right-click opens export. The minimap button can be dragged to reposition.

## Protocol Reference

The addon and server communicate over the `CCDX` addon message prefix using pipe-delimited messages:

| Direction | Code | Format | Purpose |
|-----------|------|--------|---------|
| S->C | `SC` | `SC\|entry\|spellID\|school\|name\|hp%` | Spell cast complete |
| S->C | `SS` | `SS\|entry\|spellID\|school\|name\|hp%` | Spell cast started |
| S->C | `CF` | `CF\|entry\|spellID\|school\|name\|hp%` | Channel finished |
| S->C | `AA` | `AA\|entry\|spellID\|school\|name\|hp%` | Aura applied |
| C->S | `SL` | `SL\|entry` | Request spell list |
| C->S | `CI` | `CI\|entry` | Request creature info |
| C->S | `ZC` | `ZC\|mapId` | Request zone creatures |
| C->S | `AG` | `AG\|entry\|spellId:count,...` | Submit aggregated data |

## File Structure

```
CreatureCodex/
  client/
    CreatureCodex.toc        -- Addon TOC
    CreatureCodex.lua         -- Core engine (capture + DB)
    Export.lua                -- 4-tab export panel
    UI.lua                   -- Browser panel
    Minimap.lua              -- LibDBIcon minimap button
    Libs/                    -- LibStub, CallbackHandler, LibDataBroker, LibDBIcon
  server/
    Custom/
      creature_codex_sniffer.cpp   -- C++ UnitScript hooks (broadcast layer)
      cs_creature_codex.cpp        -- .codex GM command tree
    lua_scripts/
      creature_codex_server.lua    -- Eluna handlers (spell lists, aggregation)
  sql/
    auth_rbac_creature_codex.sql   -- RBAC permission for .codex command
    roleplay_codex_aggregated.sql  -- Multi-player aggregation table
  README.md                  -- This file
  README_RU.md               -- Russian translation
  README_DE.md               -- German translation
```

## License

MIT. Libraries in `Libs/` retain their original licenses.
