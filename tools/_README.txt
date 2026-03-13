CreatureCodex Tools
===================

This folder contains the bundled tools that power the capture pipeline.

  WowPacketParser/   — Parses Ymir .pkt captures into readable text and SQL
  Ymir/              — Packet sniffer (captures retail WoW network traffic)
    dumps/           — Raw .pkt captures land here while Ymir runs
    dumps/archived/  — Processed .pkt files move here after parsing
  parsed/            — WowPacketParser output files (text + SQL)

Run "Update Tools.bat" (one level up) to download or update these tools.
