# Retail Sniffing — CreatureCodex v1.0.0

Capture what Blizzard's creatures actually cast on retail, then use that data to fix your repack.

## What You Need

1. **CreatureCodex addon** installed (see `01_Quick_Start.md`)
2. **Python 3.10+** installed ([python.org](https://www.python.org) — check "Add Python to PATH" during install)
3. **GitHub CLI** (`gh`) authenticated — install from [cli.github.com](https://cli.github.com) and run `gh auth login`
4. **Npcap** installed ([nmap.org/npcap](https://nmap.org/npcap/) — check "WinPcap compatibility mode" during install)
5. **curl** available on PATH (included by default on Windows 10+)

## First-Time Setup

1. Double-click **`Update Tools.bat`** — downloads Ymir (packet sniffer) and WowPacketParser into the `tools/` folder
2. **Set your WoW path** (only needed once): `python session.py --wow-dir "C:\WoW\_retail_"`
   - The script tries to auto-detect common install locations. If yours is non-standard, set it manually
   - The path is saved to `session_config.json` so you don't need to set it again
3. That's it. You're ready

## Each Play Session

1. Double-click **`Start Ymir.bat`**
2. The script starts Ymir and says "Launch WoW from Battle.net"
3. Launch WoW normally through Battle.net
4. **Play the game** — walk near creatures, let them fight. The addon captures what you see. Ymir captures everything at the network level
5. **Close WoW** when you're done
6. The script automatically:
   - Waits for Ymir to finish flushing (5 seconds)
   - Runs WowPacketParser on your captures
   - Archives the raw `.pkt` files to `tools/Ymir/dumps/archived/`
   - Backs up your creature data to `data/` with a timestamp
   - Opens the parsed output folder

## Where Everything Goes

| Folder | What's in it |
|--------|-------------|
| `tools/Ymir/dumps/` | Raw packet captures (moved to `archived/` after parsing) |
| `tools/Ymir/dumps/archived/` | Previously processed captures |
| `tools/parsed/` | WowPacketParser output (text + SQL) |
| `data/` | Timestamped SavedVariables backups (your creature database) |

## Parse Existing Captures

If you already have `.pkt` files (from a friend, the TC forum, etc.):

1. Drop them into `tools/Ymir/dumps/`
2. Double-click **`Parse Captures.bat`**

## The Big Picture

```
Retail WoW ──→ Ymir captures packets ──→ .pkt files
                                              │
                    WowPacketParser ◄──────────┘
                         │
                         ▼
                  Parsed output (text + SQL)
                         │
            ┌────────────┴────────────┐
            ▼                         ▼
   Browse in CreatureCodex    Apply SQL to your repack
```

The addon's client-side visual scraper runs in parallel — capturing spell names, schools, and cast patterns while Ymir captures the raw packets. Together you get the complete picture.

## Tips

- **Walk, don't fly.** Walking through areas gives much denser creature spell coverage
- **Dungeons and raids are gold.** Queue for random dungeons — boss creatures cast the most interesting spells
- **Multiple sessions merge.** Your SavedVariables accumulate data across sessions. Each new session adds to your existing database
- **Share .pkt files.** The TrinityCore community shares packet captures. Your `Parse Captures.bat` can process anyone's captures
