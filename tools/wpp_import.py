#!/usr/bin/env python3
"""
wpp_import.py — Parse WowPacketParser output and generate ready-to-apply SQL

Parses SMSG_SPELL_GO, SMSG_SPELL_START, and SMSG_AURA_UPDATE from WPP text
output and generates creature_template_spell / smart_scripts SQL directly.

Usage:
    python wpp_import.py sniff1.txt sniff2.txt           # SQL output (default)
    python wpp_import.py --smartai sniff1.txt             # SmartAI stubs
    python wpp_import.py --sql --smartai sniff1.txt       # Both SQL files
    python wpp_import.py --lua sniff1.txt                 # Addon SavedVariables
    python wpp_import.py --merge existing.lua sniff1.txt  # Merge with addon data

Output:
    creature_template_spell.sql  (--sql, default)
    smart_scripts.sql            (--smartai)
    CreatureCodexDB.lua          (--lua)
"""

import re
import sys
import os
import time
import argparse
from collections import defaultdict
from datetime import datetime

# ---------------------------------------------------------------------------
# Blacklists (mirrors the addon's built-in lists)
# ---------------------------------------------------------------------------

SPELL_BLACKLIST = {1604, 6603, 75, 3018, 1784, 2983, 20577, 7744, 20549, 26297}
CREATURE_BLACKLIST = {0, 1, 19871, 21252, 22515}

# ---------------------------------------------------------------------------
# WPP text-output regex patterns
# ---------------------------------------------------------------------------

# Packet header:  ServerToClient: SMSG_SPELL_GO (0x0131) Length: 164 ... Time: 03/05/2026 14:23:15.123 ...
RE_PACKET = re.compile(
    r'^(?:ServerToClient|ClientToServer): (\S+) \(0x[0-9A-Fa-f]+\).*Time: (\S+ \S+)'
)
# Creature GUID with entry:  ...Creature/0 R3412/S12345 Map: 0 Entry: 12345 Low: ...
RE_CREATURE_ENTRY = re.compile(r'Creature/\d+.*?Entry:\s*(\d+)')
# SpellID field
RE_SPELL_ID = re.compile(r'^\s*(?:\[\d+\]\s*)?SpellID:\s*(\d+)')
# CasterGUID / CasterUnit lines
RE_CASTER = re.compile(r'^\s*(?:\[\d+\]\s*)?Caster(?:GUID|Unit):\s*Full:')
# UnitGUID line (SMSG_AURA_UPDATE target)
RE_UNIT_GUID = re.compile(r'^\s*UnitGUID:\s*Full:')
# Aura slot header:  [0] HasAura: True  or  [0] Slot: 0
RE_AURA_SLOT = re.compile(r'^\s*\[(\d+)\]\s*(?:HasAura|Slot):')
# SchoolMask
RE_SCHOOL = re.compile(r'SchoolMask:\s*(\d+)')

OPCODES_OF_INTEREST = {'SMSG_SPELL_GO', 'SMSG_SPELL_START', 'SMSG_AURA_UPDATE'}


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

class SpellRecord:
    __slots__ = ('spell_id', 'school', 'cast_count', 'aura_count',
                 'first_seen', 'last_seen', 'cast_times',
                 'cooldown_min', 'cooldown_max', 'cooldown_avg', 'cooldown_samples')

    def __init__(self, spell_id: int):
        self.spell_id = spell_id
        self.school = 0
        self.cast_count = 0
        self.aura_count = 0
        self.first_seen = 0
        self.last_seen = 0
        self.cast_times: list[float] = []
        self.cooldown_min = 0.0
        self.cooldown_max = 0.0
        self.cooldown_avg = 0.0
        self.cooldown_samples = 0

    def compute_cooldowns(self):
        """Derive cooldown estimates from observed cast timestamps."""
        if len(self.cast_times) < 2:
            return
        intervals = []
        for i in range(1, len(self.cast_times)):
            dt = self.cast_times[i] - self.cast_times[i - 1]
            if 1.0 < dt < 300.0:  # ignore <1s dedup noise and >5min different pulls
                intervals.append(dt)
        if not intervals:
            return
        self.cooldown_min = min(intervals)
        self.cooldown_max = max(intervals)
        self.cooldown_avg = sum(intervals) / len(intervals)
        self.cooldown_samples = len(intervals)


class CreatureRecord:
    __slots__ = ('entry', 'name', 'spells', 'first_seen', 'last_seen')

    def __init__(self, entry: int):
        self.entry = entry
        self.name = f"Creature {entry}"
        self.spells: dict[int, SpellRecord] = {}
        self.first_seen = 0
        self.last_seen = 0

    def get_spell(self, spell_id: int) -> SpellRecord:
        if spell_id not in self.spells:
            self.spells[spell_id] = SpellRecord(spell_id)
        return self.spells[spell_id]


# ---------------------------------------------------------------------------
# Timestamp parsing
# ---------------------------------------------------------------------------

def parse_timestamp(ts_str: str) -> float:
    """Parse WPP timestamp string to Unix epoch seconds."""
    for fmt in ('%m/%d/%Y %H:%M:%S.%f', '%Y-%m-%d %H:%M:%S.%f',
                '%m/%d/%Y %H:%M:%S', '%Y-%m-%d %H:%M:%S'):
        try:
            dt = datetime.strptime(ts_str, fmt)
            return dt.timestamp()
        except ValueError:
            continue
    return time.time()


# ---------------------------------------------------------------------------
# WPP parser
# ---------------------------------------------------------------------------

def parse_wpp_files(filepaths: list[str]) -> dict[int, CreatureRecord]:
    """Parse one or more WPP text files and return creature spell data."""
    creatures: dict[int, CreatureRecord] = {}
    total_casts = 0
    total_auras = 0

    for filepath in filepaths:
        print(f"Parsing: {filepath}")
        line_count = 0

        # State machine
        current_opcode = None
        current_ts = 0.0
        caster_entry = None
        spell_id = None
        school = 0
        # For SMSG_AURA_UPDATE: track per-slot caster
        aura_caster = None
        in_aura_update = False

        with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                line_count += 1

                # Check for new packet header
                m = RE_PACKET.match(line)
                if m:
                    # -- Flush previous SPELL_GO / SPELL_START --
                    if current_opcode in ('SMSG_SPELL_GO', 'SMSG_SPELL_START'):
                        if caster_entry and spell_id:
                            _record_cast(creatures, caster_entry, spell_id, school, current_ts)
                            total_casts += 1

                    # Start new packet
                    opcode = m.group(1)
                    if opcode in OPCODES_OF_INTEREST:
                        current_opcode = opcode
                        current_ts = parse_timestamp(m.group(2))
                        caster_entry = None
                        spell_id = None
                        school = 0
                        in_aura_update = (opcode == 'SMSG_AURA_UPDATE')
                        aura_caster = None
                    else:
                        # Flush any pending aura state
                        current_opcode = None
                        in_aura_update = False
                    continue

                if not current_opcode:
                    continue

                # --- SMSG_SPELL_GO / SMSG_SPELL_START ---
                if current_opcode in ('SMSG_SPELL_GO', 'SMSG_SPELL_START'):
                    # Look for CasterGUID with creature entry
                    if RE_CASTER.match(line):
                        cm = RE_CREATURE_ENTRY.search(line)
                        if cm and caster_entry is None:
                            caster_entry = int(cm.group(1))

                    # Look for SpellID
                    sm = RE_SPELL_ID.match(line)
                    if sm and spell_id is None:
                        spell_id = int(sm.group(1))

                    # Look for SchoolMask
                    scm = RE_SCHOOL.search(line)
                    if scm:
                        school = int(scm.group(1))

                # --- SMSG_AURA_UPDATE ---
                elif in_aura_update:
                    # Each [N] block can have its own SpellID + CasterGUID
                    if RE_AURA_SLOT.match(line):
                        # Flush previous aura slot
                        if aura_caster and spell_id:
                            _record_aura(creatures, aura_caster, spell_id, school, current_ts)
                            total_auras += 1
                        aura_caster = None
                        spell_id = None
                        school = 0

                    # CasterGUID inside aura slot
                    if RE_CASTER.match(line):
                        cm = RE_CREATURE_ENTRY.search(line)
                        if cm:
                            aura_caster = int(cm.group(1))

                    # SpellID inside aura slot
                    sm = RE_SPELL_ID.match(line)
                    if sm:
                        spell_id = int(sm.group(1))

                    scm = RE_SCHOOL.search(line)
                    if scm:
                        school = int(scm.group(1))

        # Flush last packet
        if current_opcode in ('SMSG_SPELL_GO', 'SMSG_SPELL_START'):
            if caster_entry and spell_id:
                _record_cast(creatures, caster_entry, spell_id, school, current_ts)
                total_casts += 1
        elif in_aura_update and aura_caster and spell_id:
            _record_aura(creatures, aura_caster, spell_id, school, current_ts)
            total_auras += 1

        print(f"  {line_count:,} lines processed")

    # Compute cooldowns
    for creature in creatures.values():
        for spell in creature.spells.values():
            spell.compute_cooldowns()

    print(f"\nTotal: {len(creatures)} creatures, {total_casts} casts, {total_auras} auras")
    return creatures


def _record_cast(creatures, entry, spell_id, school, ts):
    if entry in CREATURE_BLACKLIST or spell_id in SPELL_BLACKLIST:
        return
    if entry not in creatures:
        creatures[entry] = CreatureRecord(entry)
    c = creatures[entry]
    if c.first_seen == 0:
        c.first_seen = ts
    c.last_seen = ts

    s = c.get_spell(spell_id)
    s.cast_count += 1
    if s.school == 0 and school:
        s.school = school
    if s.first_seen == 0:
        s.first_seen = ts
    s.last_seen = ts
    s.cast_times.append(ts)


def _record_aura(creatures, entry, spell_id, school, ts):
    if entry in CREATURE_BLACKLIST or spell_id in SPELL_BLACKLIST:
        return
    if entry not in creatures:
        creatures[entry] = CreatureRecord(entry)
    c = creatures[entry]
    if c.first_seen == 0:
        c.first_seen = ts
    c.last_seen = ts

    s = c.get_spell(spell_id)
    s.aura_count += 1
    if s.school == 0 and school:
        s.school = school
    if s.first_seen == 0:
        s.first_seen = ts
    s.last_seen = ts


# ---------------------------------------------------------------------------
# Merge with existing CreatureCodexDB.lua
# ---------------------------------------------------------------------------

def merge_existing(filepath: str, creatures: dict[int, CreatureRecord]):
    """Very simple merge: parse existing Lua file for creature/spell counts."""
    if not os.path.exists(filepath):
        print(f"Merge file not found: {filepath}")
        return

    print(f"Merging with: {filepath}")
    # Simple regex extraction from Lua SavedVariables
    content = open(filepath, 'r', encoding='utf-8', errors='replace').read()

    # Find creature entry blocks: [12345] = {
    for m in re.finditer(r'\[(\d+)\]\s*=\s*\{', content):
        entry = int(m.group(1))
        if entry > 100000000:  # Probably a spell ID inside a creature block
            continue
        # We don't parse deep — just ensure the creature exists
        if entry not in creatures and entry not in CREATURE_BLACKLIST:
            creatures[entry] = CreatureRecord(entry)

    print(f"  After merge: {len(creatures)} creatures")


# ---------------------------------------------------------------------------
# Lua output
# ---------------------------------------------------------------------------

def write_lua(creatures: dict[int, CreatureRecord], output_path: str,
              var_name: str = 'CreatureCodexDB'):
    """Write Lua SavedVariables file. var_name controls the global variable name."""
    now = int(time.time())
    lines = []
    lines.append('')
    lines.append(f'{var_name} = {{')
    lines.append(f'\t["version"] = 4,')
    lines.append(f'\t["collector"] = "WPP Import — {datetime.now().strftime("%Y-%m-%d %H:%M")}",')
    lines.append(f'\t["lastExport"] = 0,')
    lines.append(f'\t["creatures"] = {{')

    for entry in sorted(creatures.keys()):
        c = creatures[entry]
        if not c.spells:
            continue
        fs = int(c.first_seen) if c.first_seen else now
        ls = int(c.last_seen) if c.last_seen else now

        lines.append(f'\t\t[{entry}] = {{')
        lines.append(f'\t\t\t["name"] = "{_lua_escape(c.name)}",')
        lines.append(f'\t\t\t["firstSeen"] = {fs},')
        lines.append(f'\t\t\t["lastSeen"] = {ls},')
        lines.append(f'\t\t\t["spells"] = {{')

        for sid in sorted(c.spells.keys()):
            s = c.spells[sid]
            sfs = int(s.first_seen) if s.first_seen else fs
            sls = int(s.last_seen) if s.last_seen else ls

            lines.append(f'\t\t\t\t[{sid}] = {{')
            lines.append(f'\t\t\t\t\t["name"] = "Spell {sid}",')
            lines.append(f'\t\t\t\t\t["school"] = {s.school},')
            lines.append(f'\t\t\t\t\t["castCount"] = {s.cast_count},')
            lines.append(f'\t\t\t\t\t["auraCount"] = {s.aura_count},')
            lines.append(f'\t\t\t\t\t["firstSeen"] = {sfs},')
            lines.append(f'\t\t\t\t\t["lastSeen"] = {sls},')
            lines.append(f'\t\t\t\t\t["zones"] = {{}},')
            lines.append(f'\t\t\t\t\t["difficulties"] = {{}},')
            lines.append(f'\t\t\t\t\t["serverConfirmed"] = false,')
            lines.append(f'\t\t\t\t\t["lastCastTime"] = 0,')
            lines.append(f'\t\t\t\t\t["cooldownMin"] = {s.cooldown_min:.2f},')
            lines.append(f'\t\t\t\t\t["cooldownMax"] = {s.cooldown_max:.2f},')
            lines.append(f'\t\t\t\t\t["cooldownAvg"] = {s.cooldown_avg:.2f},')
            lines.append(f'\t\t\t\t\t["cooldownSamples"] = {s.cooldown_samples},')
            lines.append(f'\t\t\t\t}},')

        lines.append(f'\t\t\t}},')
        lines.append(f'\t\t}},')

    lines.append(f'\t}},')
    lines.append(f'\t["spellBlacklist"] = {{}},')
    lines.append(f'\t["creatureBlacklist"] = {{}},')
    lines.append(f'}}')
    lines.append('')

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))

    # Stats
    total_creatures = sum(1 for c in creatures.values() if c.spells)
    total_spells = sum(len(c.spells) for c in creatures.values())
    print(f"\nWrote {output_path}")
    print(f"  {total_creatures} creatures, {total_spells} spells")
    print(f"\nCopy to:  WTF/Account/<ACCOUNT>/SavedVariables/CreatureCodexDB.lua")
    print(f"Then log in and /reload to browse the data in-game with /cc.")


def _lua_escape(s: str) -> str:
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '').replace('\r', '')


def _sql_escape(s: str) -> str:
    return s.replace('\\', '\\\\').replace("'", "\\'").replace('\n', '').replace('\r', '')


# ---------------------------------------------------------------------------
# SQL output — creature_template_spell
# ---------------------------------------------------------------------------

def write_sql(creatures: dict[int, CreatureRecord], output_path: str):
    """Write creature_template_spell INSERT statements."""
    now_str = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    lines = [
        '-- CreatureCodex SQL Export — creature_template_spell',
        f'-- Generated: {now_str}',
        '-- Source: WowPacketParser import (wpp_import.py)',
        '',
    ]
    creature_count = 0
    spell_count = 0

    for entry in sorted(creatures.keys()):
        c = creatures[entry]
        # Only export spells with observed casts (not aura-only)
        spell_list = sorted(
            [(sid, s) for sid, s in c.spells.items() if s.cast_count > 0],
            key=lambda x: (-x[1].cast_count, x[0])
        )
        if not spell_list:
            continue

        lines.append(f'-- {c.name} (entry {entry}) — {len(spell_list)} spells')
        lines.append(f'DELETE FROM `creature_template_spell` WHERE `CreatureID` = {entry};')

        for idx, (sid, s) in enumerate(spell_list):
            lines.append(
                f"INSERT INTO `creature_template_spell` (`CreatureID`, `Index`, `Spell`) "
                f"VALUES ({entry}, {idx}, {sid});"
            )
            spell_count += 1

        lines.append('')
        creature_count += 1

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))

    print(f"\nWrote {output_path}")
    print(f"  {creature_count} creatures, {spell_count} spells")
    print(f"\nApply:  mysql -u root -p world < {output_path}")


# ---------------------------------------------------------------------------
# SQL output — smart_scripts
# ---------------------------------------------------------------------------

def write_smartai(creatures: dict[int, CreatureRecord], output_path: str):
    """Write smart_scripts INSERT statements with estimated cooldowns."""
    now_str = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    lines = [
        '-- CreatureCodex SmartAI Stubs — auto-generated from observed cast patterns',
        f'-- Generated: {now_str}',
        '-- Source: WowPacketParser import (wpp_import.py)',
        '-- WARNING: These are estimates based on observed cast frequency.',
        '-- Review and adjust cooldowns before using in production.',
        '',
    ]
    creature_count = 0

    for entry in sorted(creatures.keys()):
        c = creatures[entry]
        # Only include spells with 2+ observed casts
        spell_list = sorted(
            [(sid, s) for sid, s in c.spells.items() if s.cast_count >= 2],
            key=lambda x: -x[1].cast_count
        )
        if not spell_list:
            continue

        lines.append(f'-- {c.name} (entry {entry})')
        lines.append(f'DELETE FROM `smart_scripts` WHERE `entryorguid` = {entry} AND `source_type` = 0;')

        for idx, (sid, s) in enumerate(spell_list):
            # Estimate cooldown
            if s.cooldown_min > 0:
                cd_min = int(s.cooldown_min * 1000)
                cd_max = int((s.cooldown_max if s.cooldown_max > 0 else s.cooldown_min * 1.5) * 1000)
            else:
                # Fallback: estimate from observation window
                duration = s.last_seen - s.first_seen
                if duration > 0 and s.cast_count > 1:
                    avg_interval = duration / (s.cast_count - 1)
                    cd_min = int(max(avg_interval * 0.7, 3.0) * 1000)
                    cd_max = int(max(avg_interval * 1.3, 6.0) * 1000)
                else:
                    cd_min = 8000
                    cd_max = 15000

            # Infer target type: self-buff if auras dominate casts
            target_type = 1 if s.aura_count > s.cast_count else 2

            # event_type 0 = UpdateIC (in combat, repeat), action_type 11 = Cast
            name_esc = _sql_escape(c.name)
            lines.append(
                f"INSERT INTO `smart_scripts` "
                f"(`entryorguid`,`source_type`,`id`,`link`,"
                f"`event_type`,`event_phase_mask`,`event_chance`,`event_flags`,"
                f"`event_param1`,`event_param2`,`event_param3`,`event_param4`,"
                f"`action_type`,`action_param1`,`action_param2`,`action_param3`,"
                f"`target_type`,`comment`) VALUES "
                f"({entry},0,{idx},0,"
                f"0,0,100,0,"
                f"{cd_min},{cd_max},{cd_min},{cd_max},"
                f"11,{sid},0,0,"
                f"{target_type},'{name_esc} - Spell {sid}');"
            )

        lines.append('')
        creature_count += 1

    with open(output_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines))

    print(f"\nWrote {output_path}")
    print(f"  {creature_count} creatures with SmartAI stubs")
    print(f"\nApply:  mysql -u root -p world < {output_path}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='Parse WowPacketParser output into ready-to-apply SQL or addon data',
        epilog='Example: python wpp_import.py sniff1.txt sniff2.txt'
    )
    parser.add_argument('files', nargs='+', help='WPP .txt output files to parse')
    parser.add_argument('-o', '--output', default=None,
                        help='Output path (default: auto-named per format)')
    parser.add_argument('-m', '--merge', metavar='LUA_FILE',
                        help='Merge with an existing CreatureCodexDB.lua before writing')

    fmt = parser.add_argument_group('output format (default: --sql)')
    fmt.add_argument('--sql', action='store_true',
                     help='Output creature_template_spell SQL (default if no format specified)')
    fmt.add_argument('--smartai', action='store_true',
                     help='Output smart_scripts SQL with estimated cooldowns')
    fmt.add_argument('--lua', action='store_true',
                     help='Output CreatureCodexDB.lua SavedVariables (replaces addon DB)')
    fmt.add_argument('--addon', action='store_true',
                     help='Output CreatureCodexWPP.lua for live addon import (/reload to merge)')
    args = parser.parse_args()

    # Default to --sql if no format specified
    if not args.sql and not args.smartai and not args.lua and not args.addon:
        args.sql = True

    # Validate input files
    for fp in args.files:
        if not os.path.exists(fp):
            print(f"Error: File not found: {fp}", file=sys.stderr)
            sys.exit(1)

    # Can only use --output with a single format
    formats_selected = sum([args.sql, args.smartai, args.lua, args.addon])
    if args.output and formats_selected > 1:
        print("Error: --output can only be used with a single format flag.", file=sys.stderr)
        sys.exit(1)

    # Parse
    creatures = parse_wpp_files(args.files)

    # Merge if requested
    if args.merge:
        merge_existing(args.merge, creatures)

    # Write requested formats
    if args.sql:
        path = args.output or 'creature_template_spell.sql'
        write_sql(creatures, path)

    if args.smartai:
        path = args.output or 'smart_scripts.sql'
        write_smartai(creatures, path)

    if args.lua:
        path = args.output or 'CreatureCodexDB.lua'
        write_lua(creatures, path)

    if args.addon:
        path = args.output or 'CreatureCodexWPP.lua'
        write_lua(creatures, path, var_name='CreatureCodexWPP')
        print(f"\nCopy to:  WTF/Account/<ACCOUNT>/SavedVariables/CreatureCodexWPP.lua")
        print(f"Then /reload in-game — the addon auto-merges and reports what it imported.")


if __name__ == '__main__':
    main()
