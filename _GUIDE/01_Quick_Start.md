# Quick Start — CreatureCodex v1.0.0

## Install the Addon (2 minutes)

1. **Find your WoW addon folder:**
   - Retail: `C:\World of Warcraft\_retail_\Interface\AddOns\`
   - Private server: wherever your WoW is installed, go to `Interface\AddOns\`
   - If `AddOns` doesn't exist, create it

2. **Copy the `CreatureCodex` folder** (the one with the .lua files) into `AddOns/`
   - You should end up with: `AddOns\CreatureCodex\CreatureCodex.toc`
   - NOT: `AddOns\CreatureCodex\CreatureCodex\CreatureCodex.toc` (one level too deep)

3. **Launch WoW**
   - A gold book icon appears on your minimap — that's CreatureCodex
   - If you don't see it: Game Menu → AddOns → enable "Load out of date AddOns"

## How This Helps Your Server

Most repacks and fresh TrinityCore builds have empty `creature_template_spell` and `smart_scripts` tables. Your mobs auto-attack and do nothing else. But many of those creatures still have cast-bar abilities baked into their client-side data — they just aren't wired up in the database.

CreatureCodex watches what creatures visually do in-game and turns that into working SQL. Walk near mobs, let them fight, export the SmartAI tab, apply the SQL, and those mobs now cast their spells with estimated cooldowns and target logic. No manual data entry, no guessing spell IDs.

**What it catches without server patches:** Any spell that produces a visible cast bar or nameplate aura — typically 60-80% of a creature's abilities.

**What it misses:** Instant casts, hidden triggers, and server-side-only spells with no visual component. Adding the C++ server hooks (see `02_Server_Setup.md`) catches 100%.

## Use It

- **Click the minimap icon** to open the browser (or type `/cc`)
- **Walk near creatures** that are fighting — the addon captures spell casts and auras automatically
- **Click a creature** in the left panel to see its spell list on the right
- **Right-click a spell** to ignore it (junk spells, auto-attack, etc.)
- **Click Export Data** to generate SQL you can apply to your server's database

## Status Bar (top-right of browser)

| Status | Meaning |
|--------|---------|
| `CreatureCodex: Active` | Server hooks installed and broadcasting (best coverage) |
| `CreatureCodex: Scanning` | Client visual scraper running (works everywhere) |
| `CreatureCodex: Ready` | Addon loaded, waiting for you to encounter creatures |

## Tips

- **Ctrl-click** a creature or spell to get a Wowhead link (copy/paste into browser)
- **Shift-click** a creature to insert a chat link
- **Right-click** a spell to ignore it — go to the Ignored tab to undo mistakes
- The addon saves data between sessions — close WoW and come back, your data is still there

## Next Steps

- **Running a TrinityCore server?** See `02_Server_Setup.md` for server hooks (catches 100% of casts)
- **Want to sniff retail data?** See `03_Retail_Sniffing.md` for the Ymir + WPP pipeline
- **Got SQL exported?** See `04_Understanding_Exports.md` for how to apply it
