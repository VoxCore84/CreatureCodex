# CreatureCodex v1.0.0

[![GitHub](https://img.shields.io/github/v/release/VoxCore84/CreatureCodex?label=v1.0.0)](https://github.com/VoxCore84/CreatureCodex/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Your NPCs don't fight. They stand there and auto-attack because `creature_template_spell` (the database table that assigns spells to creatures) is empty and there's no SmartAI (TrinityCore's scripted behavior system) telling them what to cast. CreatureCodex fixes that.

**Repository:** [github.com/VoxCore84/CreatureCodex](https://github.com/VoxCore84/CreatureCodex)

## What It Does

1. **Install the addon** on any TrinityCore server — repacks included, no server patches needed
2. **Walk around and let creatures fight** — the addon captures visible spell casts, channels, and auras in real time (server hooks add instant/hidden spells for 100% coverage)
3. **Open the export panel** and hit the **SmartAI** tab — ready-to-apply SQL with estimated cooldowns, HP phase triggers, and target types
4. **Apply the SQL** — your NPCs now cast spells with proper timing and behavior

CreatureCodex turns observation into working SmartAI. You watch mobs fight, it writes the `smart_scripts` and `creature_template_spell` inserts for you.

### The Full Pipeline

```
                            +-- Visual Scraper (client addon, works everywhere)
Walk near mobs -------------+-- Server Hooks (C++ UnitScript, 100% coverage)
                            +-- Ymir Integration (auto-merge from packet captures)
                                          |
                                          v
                              Browse in-game -> Export as SQL
                                                +-- creature_template_spell (spell lists)
                                                +-- smart_scripts (AI with cooldowns)
                                                +-- new-only (just the gaps)
```

The SmartAI export isn't just a list of spell IDs — it uses the addon's timing intelligence to estimate cooldowns from observed cast intervals, detects HP-phase abilities (spells seen below 40% HP at least once get `event_type=2` health triggers instead of timed repeats), and infers target types from cast-vs-aura ratios. It's a first draft you can tune, not a blank slate you have to build from scratch.

## Why This Is Hard Without It

This data doesn't ship in DB2 files. It has to be observed from a live server. In 12.x, that got dramatically harder:

- **`COMBAT_LOG_EVENT_UNFILTERED` is effectively dead.** The combat log was the gold standard for capturing creature casts. In 12.x, cross-addon GUID tracking is severely locked down. Passive CLEU listening no longer gives reliable creature spell data.

- **Taint and secret values.** The 12.x engine injects opaque C++ `userdata` taints into spell IDs, GUIDs, and aura data. Standard Lua `tonumber()`/`tostring()` silently fail on tainted values. Any addon touching spell data must wrap every access in `pcall` with `issecretvalue()` checks or it breaks without warning.

- **Instant casts are invisible.** `UnitCastingInfo`/`UnitChannelInfo` only see spells with visible cast bars. Instant casts, triggered spells, and many boss mechanics never appear in these APIs — a significant portion of any creature's spell list is unobservable from the client.

- **Traditional sniffing requires post-processing.** The Ymir -> WowPacketParser pipeline produces the best data, but turning raw packet captures into usable spell lists has always meant offline parsing, manual review, and hand-written SQL.

**CreatureCodex works around all of this.** The client-side visual scraper polls cast bars at 10 Hz and scans nameplate auras at 5 Hz, wrapping every access in taint-safe helpers. This works on any server — repacks, custom builds, anything running a 12.x client.

For servers that can add C++ hooks, four `UnitScript` callbacks catch 100% of casts including instant and hidden ones, broadcast as lightweight addon messages. Both layers deduplicate automatically — zero gaps, zero noise.

And if you sniff with Ymir, CreatureCodex integrates directly — run the included tool on your WPP output, `/reload`, and the addon merges sniff data with scraper data automatically. Or skip the addon and generate SQL straight from your packet captures.

## How It Works

CreatureCodex has three data sources:

1. **Client-side visual scraper** (works everywhere, no server patches needed)
   - Polls `UnitCastingInfo`/`UnitChannelInfo` at 10 Hz for spell casts
   - Round-robin scans nameplates for auras at 5 Hz
   - Records spell name, school, creature entry, and timestamps (HP% is available from server hooks only)

2. **Server-side sniffer** (requires TrinityCore C++ hooks)
   - Four `UnitScript` hooks broadcast every creature spell event as addon messages
   - Catches 100% of casts including instant/hidden ones the client never sees
   - Broadcasts only to nearby players (100 yd) who have CreatureCodex installed

3. **Ymir integration** (live merge from packet captures)
   - Run Ymir alongside the game as usual — CreatureCodex works in parallel
   - After WowPacketParser processes your `.pkt` files, run the included Python tool to convert the output
   - The addon auto-merges sniff data on `/reload` — no need to exit the game
   - Catches instant casts, hidden spells, and triggered abilities the visual scraper can't see
   - Also generates SQL directly from sniff data if you prefer to skip the addon entirely

When multiple sources run together, the addon deduplicates automatically — you get complete coverage with zero gaps.

## Download

Grab the latest release from the [Releases page](https://github.com/VoxCore84/CreatureCodex/releases). Download `CreatureCodex.zip` and extract it — it contains the client addon, server scripts, tools, and these docs.

## Installation

<details>
<summary><strong>Client-Only Install (No Server Patches)</strong> — click to expand</summary>

If you just want the visual scraper without modifying your server:

1. Copy the `CreatureCodex/` addon folder into your WoW installation's addon directory:
   ```
   <WoW Install>/Interface/AddOns/CreatureCodex/
   ```
   For example: `C:\WoW\_retail_\Interface\AddOns\CreatureCodex\`. Create the `AddOns` folder if it doesn't exist.
2. The folder should contain: `CreatureCodex.toc`, `CreatureCodex.lua`, `Export.lua`, `UI.lua`, `Minimap.lua`, and the `Libs/` folder.
3. Log in. The addon registers automatically via the minimap button (gold book icon).
4. Walk near creatures and observe them fighting — spells are captured in real time.
5. Type `/cc` in chat to open the browser panel and confirm the addon is working.

**What you get**: Visible casts and channels (anything the WoW API can detect).
**What you miss**: Instant casts, hidden spells, and auras applied without visible cast bars.

> **Tip:** If the addon doesn't appear in your addon list, check Game Menu -> AddOns -> enable **"Load out of date AddOns"** at the top. This is needed when the client version is newer than the addon's TOC Interface version.

</details>

<details>
<summary><strong>Full Install (Server + Client)</strong> — click to expand</summary>

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
    FOREACH_SCRIPT(UnitScript)->OnCreatureSpellCast(creature, spell);
}

void ScriptMgr::OnCreatureSpellStart(Creature* creature, SpellInfo const* spell)
{
    FOREACH_SCRIPT(UnitScript)->OnCreatureSpellStart(creature, spell);
}

void ScriptMgr::OnCreatureChannelFinished(Creature* creature, SpellInfo const* spell)
{
    FOREACH_SCRIPT(UnitScript)->OnCreatureChannelFinished(creature, spell);
}

void ScriptMgr::OnAuraApply(Unit* target, AuraApplication* aurApp)
{
    FOREACH_SCRIPT(UnitScript)->OnAuraApply(target, aurApp);
}
```

**`src/server/game/Scripting/ScriptMgr.h`** — Also add these declarations to `class ScriptMgr` (a different class in the same file — search for `class TC_GAME_API ScriptMgr`):
```cpp
void OnCreatureSpellCast(Creature* creature, SpellInfo const* spell);
void OnCreatureSpellStart(Creature* creature, SpellInfo const* spell);
void OnCreatureChannelFinished(Creature* creature, SpellInfo const* spell);
void OnAuraApply(Unit* target, AuraApplication* aurApp);
```

### Step 2: Wire the Hooks into Spell.cpp and Unit.cpp

Four one-liner hooks are added inside existing `if (Creature* caster = ...)` blocks in `Spell.cpp` and at the end of `Unit::_ApplyAura()` in `Unit.cpp`.

See **`server/HOOKS.md`** for the exact code, variable names, and insertion points. The auto-patcher (`install_hooks.py`) applies these automatically — use `HOOKS.md` only if you prefer to patch by hand.

### Step 3: Add IsAddonRegistered Helper

The sniffer checks if a player has the `CCDX` addon prefix registered before sending them data. Add this small helper to `WorldSession` (it reads the `_registeredAddonPrefixes` member that already exists in the class):

**`src/server/game/Server/WorldSession.h`** — Add to the `public:` section of `class WorldSession`:
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

Then apply `sql/auth_rbac_creature_codex.sql` to your `auth` database, or run manually:
```sql
INSERT IGNORE INTO `rbac_permissions` (`id`, `name`) VALUES (3012, 'Command: codex');
-- Link to GM role (role 193 = GM commands)
INSERT IGNORE INTO `rbac_linked_permissions` (`id`, `linkedId`) VALUES (193, 3012);
```

### Step 5: Copy the Sniffer Scripts

1. Copy `server/creature_codex_sniffer.cpp` and `server/cs_creature_codex.cpp` to your `src/server/scripts/Custom/` directory.

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

If you use Eluna, copy `server/lua_scripts/creature_codex_server.lua` to your Eluna scripts directory (default: `lua_scripts/` next to your worldserver binary). This adds:
- **Spell list queries**: Addon can request the full spell list for any creature from `creature_template_spell`
- **Creature info**: Name, faction, level range, classification
- **Zone completeness**: Query all creatures in a map with their known spell counts
- **Multi-player aggregation**: Players can submit discoveries to a shared server-side table

For aggregation, create the shared table by running the following SQL against whichever database you want it in (default: `characters`):
```sql
CREATE TABLE IF NOT EXISTS `codex_aggregated` (
    `creature_entry` INT UNSIGNED NOT NULL,
    `spell_id` INT UNSIGNED NOT NULL,
    `cast_count` INT UNSIGNED NOT NULL DEFAULT 1,
    `last_reporter` VARCHAR(64) NOT NULL DEFAULT '',
    `last_seen` INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (`creature_entry`, `spell_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

This table must exist in your `characters` database (the same one that `CharDBExecute` targets).

### Step 7: Build and Install

1. Copy the `CreatureCodex/` addon folder contents to `Interface\AddOns\CreatureCodex\`.
2. Rebuild your server. From your build directory:
   ```bash
   # CMake + Make (Linux)
   cmake --build . --config RelWithDebInfo -j $(nproc)

   # CMake + Ninja
   ninja -j$(nproc)

   # Visual Studio (Windows)
   # Open the .sln and build in Release or RelWithDebInfo
   ```

</details>

<details>
<summary><strong>Ymir Integration (Sniff Users)</strong> — click to expand</summary>

If you sniff with Ymir, CreatureCodex works alongside it. The addon captures what the client can see in real time (~80% of spells), and a background companion automatically feeds WowPacketParser data into the addon to fill in the rest — instant casts, hidden spells, triggered abilities. Everything merges inside the game. You never exit.

### Setup (One Time)

1. Install the addon normally (see Client-Only Install above)
2. Start the background watcher alongside Ymir:
   ```bash
   python tools/wpp_watcher.py
   ```
   It auto-detects your WoW install and SavedVariables folder. If auto-detection fails, point it manually:
   ```bash
   python tools/wpp_watcher.py --wow-dir "C:/WoW/_retail_" --watch-dir "C:/sniffs"
   ```

### Playing

1. **Play normally** with Ymir + watcher running in the background
2. **The addon captures visible casts and auras** in real time via the visual scraper
3. **The watcher processes your WPP output** automatically as files appear — no manual steps
4. **Type `/cc sync`** to reload the UI and import the new data
5. The addon reports what it imported:
   ```
   [CreatureCodex] Imported sniff data: +142 creatures, +891 spells from WPP.
   ```
6. **Browse and export** with `/cc` — your data now includes both scraper observations and packet-confirmed spells

That's it. The visual scraper gives you spell names and real-time browsing. The sniff data fills in instant casts, server-side triggers, and hidden auras the client can't see. The addon deduplicates everything — together they're better than either alone.

### Requirements

- Python 3.10+
- GitHub CLI (`gh`) authenticated — install from [cli.github.com](https://cli.github.com)
- curl (included by default on Windows 10+)
- WowPacketParser (produces `.txt` output from Ymir `.pkt` captures)

### Direct SQL (Skip the Addon)

If you don't need to browse in-game and just want SQL from your sniff data:

```bash
# creature_template_spell SQL (default)
python tools/wpp_import.py sniff1.txt sniff2.txt
# -> creature_template_spell.sql

# SmartAI stubs with estimated cooldowns
python tools/wpp_import.py --smartai sniff1.txt
# -> smart_scripts.sql

# Both at once
python tools/wpp_import.py --sql --smartai sniff1.txt

# Apply directly
mysql -u root -p world < creature_template_spell.sql
```

The script parses `SMSG_SPELL_GO`, `SMSG_SPELL_START`, and `SMSG_AURA_UPDATE` opcodes. It estimates cooldowns from observed cast intervals and infers target types from cast-vs-aura ratios — the same intelligence the addon uses.

### Output Formats

| Flag | Output File | Contents |
|------|-------------|----------|
| `--sql` (default) | `creature_template_spell.sql` | DELETE + INSERT pairs for spell lists |
| `--smartai` | `smart_scripts.sql` | SmartAI stubs with cooldown estimates |
| `--addon` | `CreatureCodexWPP.lua` | Auto-merge into addon on `/reload` |
| `--lua` | `CreatureCodexDB.lua` | Full SavedVariables replacement |

Use `-o` to override the output filename (single format only). Flags combine: `--sql --smartai` generates both SQL files in one pass.

### Tips

- **Walking produces denser data than flying.** When sniffing, walk through areas on foot for better creature spell coverage.
- **Multiple sniffs merge cleanly.** Pass multiple `.txt` files to combine data from different sessions.
- **Scraper + sniff = complete picture.** The visual scraper gives you spell names and real-time browsing; the sniff data gives you spell IDs and full coverage. Together they're better than either alone.

</details>

## Usage

### Slash Commands

| Command | Description |
|---------|-------------|
| `/cc` or `/codex` | Toggle the browser panel |
| `/cc export` | Open the export panel |
| `/cc debug` | Toggle debug output in chat |
| `/cc stats` | Print capture statistics |
| `/cc zone` | Request zone creature data from server (requires Eluna) |
| `/cc submit` | Submit aggregated data to server (requires Eluna) |
| `/cc sync` | Reload UI to import WPP sniff data (run `wpp_import.py --addon` first) |
| `/cc reset` | Clear all stored data (with confirmation) |

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

1. **Raw** — Machine-readable format: `entry:name|spellId:totalCount:school:spellName|...` (one creature per line, prefixed with `CCEXPORT:v3`)
2. **SQL** — `INSERT INTO creature_template_spell` statements ready to apply
3. **SmartAI** — `INSERT INTO smart_scripts` for AI-driven casting
4. **New Only** — Same as SQL but filters to spells not already in `creature_template_spell`

> **WARNING — Destructive Operation:** The SQL export uses `DELETE FROM creature_template_spell WHERE CreatureID = <entry>` and the SmartAI export uses `DELETE FROM smart_scripts WHERE entryorguid = <entry> AND source_type = 0` before inserting. This removes all existing spells/scripts for that creature and replaces them with what CreatureCodex observed. If you have hand-tuned data, back it up first or use the **New Only** tab, which uses `INSERT IGNORE` and never deletes.

### Applying the Exported SQL

After exporting from the addon, you have SQL text ready to run against your `world` database. Here are three common ways to apply it:

- **HeidiSQL** (Windows): Connect to your DB, select the `world` database, open a new Query tab, paste the SQL, and hit Execute (F9).
- **phpMyAdmin** (web): Select the `world` database, go to the SQL tab, paste, and click Go.
- **MySQL CLI**:
  ```bash
  mysql -u root -p world < exported_spells.sql
  ```
  Or paste directly into an interactive `mysql` session after running `USE world;`.

The SQL and SmartAI exports include `DELETE` + `INSERT` pairs so they're safe to re-run — they won't create duplicates.

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
| S->C | `AR` | `AR\|entry\|OK` | Aggregation acknowledgement |

## File Structure

```
CreatureCodex/
  CreatureCodex/                          -- ADDON FOLDER (copy to Interface/AddOns/CreatureCodex/)
    CreatureCodex.toc                     -- Addon TOC
    CreatureCodex.lua                     -- Core engine (capture + DB)
    Export.lua                            -- 4-tab export panel
    UI.lua                                -- Browser panel
    Minimap.lua                           -- LibDBIcon minimap button
    Libs/                                 -- LibStub, CallbackHandler, LibDataBroker, LibDBIcon
  server/
    creature_codex_sniffer.cpp            -- C++ UnitScript hooks (broadcast layer)
    cs_creature_codex.cpp                 -- .codex GM command tree
    install_hooks.py                      -- Auto-patcher for TC source hooks
    HOOKS.md                              -- Manual patching reference
    lua_scripts/
      creature_codex_server.lua           -- Eluna handlers (spell lists, aggregation)
  tools/
    wpp_import.py                         -- WPP -> SQL / addon import tool
    wpp_watcher.py                        -- Background companion for auto-import
    _README.txt                           -- Tools folder overview
    parsed/
      _What_To_Do_With_These_Files.txt    -- Guide for parsed output
  _GUIDE/
    01_Quick_Start.md                     -- Get running in 2 minutes
    02_Server_Setup.md                    -- Server hooks + C++ setup
    03_Retail_Sniffing.md                 -- Ymir + WPP pipeline
    04_Understanding_Exports.md           -- Export formats explained
  session.py                              -- Session manager (Ymir lifecycle + SV backup)
  update_tools.py                         -- Tool downloader (requires gh CLI)
  Start Ymir.bat                          -- Launch Ymir + session manager (Windows)
  Update Tools.bat                        -- Download/update WPP and Ymir (Windows)
  Parse Captures.bat                      -- Run WPP on existing .pkt files (Windows)
  start_ymir.sh                           -- Launch Ymir + session manager (Linux/macOS)
  update_tools.sh                         -- Download/update WPP and Ymir (Linux/macOS)
  parse_captures.sh                       -- Run WPP on existing .pkt files (Linux/macOS)
  README.md                               -- This file
  README_RU.md                            -- Russian translation
  README_DE.md                            -- German translation
  LICENSE                                 -- MIT
```

## License

MIT. Libraries in `Libs/` retain their original licenses.
