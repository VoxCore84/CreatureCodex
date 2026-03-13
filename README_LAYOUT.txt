CreatureCodex — Project Layout
==============================

client/            WoW addon files. Copy to Interface/AddOns/CreatureCodex/
server/            TrinityCore C++ server scripts + Eluna handlers
sql/               Database setup (RBAC permissions, aggregation table)
tools/             Ymir sniff session manager, WPP import, capture parsers
installer/         GUI installer source code
installer/dist/    CreatureCodex_Setup.exe (run this to install everything)
_GUIDE/            Step-by-step setup and usage guides
screenshots/       UI screenshots for documentation

Batch shortcuts:
  Start Ymir.bat     Launch a sniffing session
  Parse Captures.bat Process raw packet captures into usable data
  Update Tools.bat   Pull latest tool updates

The installer handles placement automatically — it copies the addon
to your WoW AddOns folder and sniff tools wherever you choose.
