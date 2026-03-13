# Understanding Exports — CreatureCodex v1.0.0

## Export Modes

Click **Export Data** in the browser to open the export panel. Four tabs:

### Raw Data
Plain text dump of everything captured. Format:
```
CreatureEntry:CreatureName|SpellID:TotalCount:SchoolMask:SpellName|...
```
Useful for sharing data, importing into spreadsheets, or feeding into custom scripts.

### SQL (Spells)
Ready-to-run SQL for `creature_template_spell` — the TrinityCore table that assigns spells to creatures.

```sql
-- Blackrock Warlock (entry 4065) — 3 spells
DELETE FROM `creature_template_spell` WHERE `CreatureID` = 4065;
INSERT INTO `creature_template_spell` (`CreatureID`, `Index`, `Spell`) VALUES (4065, 0, 20825); -- NEW
INSERT INTO `creature_template_spell` (`CreatureID`, `Index`, `Spell`) VALUES (4065, 1, 20826); -- DB-confirmed
INSERT INTO `creature_template_spell` (`CreatureID`, `Index`, `Spell`) VALUES (4065, 2, 13340); -- NEW
```

- Uses **DELETE + INSERT** pattern (safe to re-run, won't create duplicates)
- **Backtick column names** (TrinityCore convention)
- Comments show whether each spell is NEW (not in your DB) or DB-confirmed (already there)

> **WARNING — Destructive Operation:** The SQL export uses `DELETE FROM creature_template_spell WHERE CreatureID = <entry>` before inserting. This **removes all existing spells** for that creature and replaces them with what CreatureCodex observed. If you have hand-tuned spell lists, back them up first or use the **New Only** export tab instead, which uses `INSERT IGNORE` and never deletes existing data.

### SQL (SmartAI)
AI behavior stubs for `smart_scripts` — tells creatures WHEN and HOW to cast.

```sql
-- Blackrock Warlock (entry 4065)
DELETE FROM `smart_scripts` WHERE `entryorguid` = 4065 AND `source_type` = 0;
INSERT INTO `smart_scripts` (...) VALUES (4065,0,0,0,0,0,100,0,8000,15000,8000,15000,11,20825,0,0,2,'...');
```

- **Cooldowns are estimated** from observed cast intervals (not guaranteed accurate)
- **HP-phase spells** (seen below 40% HP at least once) get `event_type=2` (health-based triggers)
- **Target types** are inferred from cast-vs-aura ratios (self-buff vs enemy target)
- **Always review before applying** — these are first drafts, not finished AI

### New Only
Same as SQL (Spells) but filtered to only spells NOT already in your `creature_template_spell` table. Use this to fill gaps without touching existing data.

Uses `INSERT IGNORE` so it won't overwrite existing entries.

## How to Apply SQL

### HeidiSQL (Windows, beginner-friendly)
1. Connect to your MySQL server
2. Select the `world` database in the left panel
3. Click the **Query** tab
4. Paste the exported SQL
5. Press **F9** or click **Execute**

### phpMyAdmin (web-based)
1. Select the `world` database
2. Go to the **SQL** tab
3. Paste the SQL
4. Click **Go**

### MySQL Command Line
```bash
# From a file:
mysql -u root -p world < exported_spells.sql

# Or paste interactively:
mysql -u root -p
USE world;
-- paste SQL here --
```

## What the Columns Mean

### creature_template_spell
| Column | Meaning |
|--------|---------|
| `CreatureID` | The creature's template entry ID |
| `Index` | Spell slot (0-7, determines priority) |
| `Spell` | The spell ID to cast |

### smart_scripts (abbreviated)
| Column | Meaning |
|--------|---------|
| `entryorguid` | Creature entry ID |
| `event_type` | 0 = timed repeat in combat, 2 = HP% threshold |
| `event_param1/2` | Min/max initial delay (ms) |
| `event_param3/4` | Min/max repeat interval (ms) |
| `action_type` | 11 = Cast Spell |
| `action_param1` | Spell ID to cast |
| `target_type` | 1 = self, 2 = current target |

## After Applying SQL

Restart your worldserver (or use `.reload creature_template` if supported) for `creature_template_spell` changes to take effect. SmartAI changes require `.reload smart_scripts` or a server restart.
