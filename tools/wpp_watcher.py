#!/usr/bin/env python3
"""
wpp_watcher.py — Background companion for CreatureCodex + Ymir

Watches a directory for WowPacketParser .txt output and automatically writes
CreatureCodexWPP.lua to your WoW SavedVariables folder. Type "/cc sync"
in the addon (or /reload) to import the data — never leave the game.

Usage:
    python wpp_watcher.py                                # auto-detect everything
    python wpp_watcher.py --watch-dir C:/sniffs           # specify WPP output dir
    python wpp_watcher.py --wow-dir "C:/WoW/_retail_"     # specify WoW install
    python wpp_watcher.py --once                          # process once and exit
"""

import os
import sys
import time
import glob
import argparse
from pathlib import Path
from datetime import datetime

# Import the parser from wpp_import.py (same directory)
sys.path.insert(0, str(Path(__file__).parent))
from wpp_import import parse_wpp_files, write_lua

POLL_INTERVAL = 5  # seconds between checks


def find_wow_dir() -> Path | None:
    """Try to auto-detect WoW retail installation."""
    candidates = [
        Path("C:/WoW/_retail_"),
        Path("C:/World of Warcraft/_retail_"),
        Path("C:/Program Files/World of Warcraft/_retail_"),
        Path("C:/Program Files (x86)/World of Warcraft/_retail_"),
        Path.home() / "Games" / "World of Warcraft" / "_retail_",
    ]
    for p in candidates:
        if p.exists() and (p / "WTF").exists():
            return p
    return None


def find_savedvariables_dir(wow_dir: Path) -> Path | None:
    """Find the SavedVariables directory, preferring the one with CreatureCodex data."""
    wtf = wow_dir / "WTF" / "Account"
    if not wtf.exists():
        return None

    best = None
    best_mtime = 0

    for account_dir in wtf.iterdir():
        if not account_dir.is_dir() or account_dir.name.startswith('.'):
            continue
        sv_dir = account_dir / "SavedVariables"
        if not sv_dir.exists():
            continue

        codex_db = sv_dir / "CreatureCodexDB.lua"
        if codex_db.exists():
            mtime = codex_db.stat().st_mtime
            if mtime > best_mtime:
                best = sv_dir
                best_mtime = mtime
        elif best is None:
            best = sv_dir

    return best


def find_wpp_dir() -> Path | None:
    """Try to find a directory containing WPP .txt output."""
    candidates = [
        Path.cwd(),
        Path.home() / "Desktop",
        Path.home() / "Documents",
    ]
    for p in candidates:
        if p.exists() and list(p.glob("*.txt"))[:1]:
            return p
    return None


def is_wpp_file(filepath: Path) -> bool:
    """Quick check if a .txt file looks like WPP output."""
    try:
        with open(filepath, 'r', encoding='utf-8', errors='replace') as f:
            # Read up to 4KB to check for WPP opcode markers
            head = f.read(4096)
            return 'SMSG_' in head or 'CMSG_' in head or 'ServerToClient:' in head
    except (OSError, PermissionError):
        pass
    return False


def timestamp() -> str:
    return datetime.now().strftime('%H:%M:%S')


def main():
    parser = argparse.ArgumentParser(
        description='Background companion for CreatureCodex + Ymir',
        epilog='Start this alongside Ymir. Type "/cc sync" in CreatureCodex to import data.'
    )
    parser.add_argument('--watch-dir', type=Path, default=None,
                        help='Directory to watch for WPP .txt files (auto-detected if omitted)')
    parser.add_argument('--wow-dir', type=Path, default=None,
                        help='WoW retail install path (auto-detected if omitted)')
    parser.add_argument('--poll', type=int, default=POLL_INTERVAL,
                        help=f'Seconds between checks (default: {POLL_INTERVAL})')
    parser.add_argument('--once', action='store_true',
                        help='Process all current files once and exit (no watching)')
    args = parser.parse_args()

    # Resolve WoW directory
    wow_dir = args.wow_dir or find_wow_dir()
    if not wow_dir:
        print("Could not auto-detect WoW installation.")
        print("Use --wow-dir to specify it, e.g.:")
        print('  python wpp_watcher.py --wow-dir "C:/WoW/_retail_"')
        sys.exit(1)
    print(f"WoW directory: {wow_dir}")

    # Resolve SavedVariables directory
    sv_dir = find_savedvariables_dir(wow_dir)
    if not sv_dir:
        print(f"Could not find SavedVariables directory under {wow_dir}/WTF/Account/")
        print("Make sure you've logged in at least once with CreatureCodex installed.")
        sys.exit(1)
    print(f"SavedVariables: {sv_dir}")

    # Resolve watch directory
    watch_dir = args.watch_dir or find_wpp_dir()
    if not watch_dir:
        print("Could not find a directory with WPP .txt files.")
        print("Use --watch-dir to specify it, e.g.:")
        print('  python wpp_watcher.py --watch-dir "C:/sniffs"')
        sys.exit(1)
    print(f"Watching: {watch_dir}")

    output_path = sv_dir / "CreatureCodexWPP.lua"
    print(f"Output: {output_path}")
    print()

    if args.once:
        process_all(watch_dir, output_path)
        return

    # Watch loop
    print(f"[{timestamp()}] Watching for WPP output (checking every {args.poll}s)...")
    print(f"[{timestamp()}] Type '/cc sync' in CreatureCodex or /reload to import data.")
    print()

    seen_files: dict[Path, float] = {}

    try:
        while True:
            new_files = scan_for_new_files(watch_dir, seen_files)

            if new_files:
                print(f"[{timestamp()}] Found {len(new_files)} new/modified file(s)")
                for nf in new_files:
                    print(f"  + {nf.name}")

                all_wpp_files = [str(f) for f in seen_files.keys() if is_wpp_file(f)]
                if all_wpp_files:
                    creatures = parse_wpp_files(all_wpp_files)
                    write_lua(creatures, str(output_path), var_name='CreatureCodexWPP')
                    print(f"[{timestamp()}] Ready! Type '/cc sync' in-game to import.")
                    print()

            time.sleep(args.poll)

    except KeyboardInterrupt:
        print(f"\n[{timestamp()}] Stopped.")


def scan_for_new_files(watch_dir: Path, seen_files: dict) -> list[Path]:
    """Check for new or modified .txt files in the watch directory."""
    new_files = []
    for txt_file in watch_dir.glob("*.txt"):
        try:
            mtime = txt_file.stat().st_mtime
        except OSError:
            continue
        if txt_file not in seen_files or seen_files[txt_file] < mtime:
            if is_wpp_file(txt_file):
                new_files.append(txt_file)
            seen_files[txt_file] = mtime
    return new_files


def process_all(watch_dir: Path, output_path: Path):
    """Process all WPP .txt files in the directory once."""
    txt_files = [f for f in watch_dir.glob("*.txt") if is_wpp_file(f)]
    if not txt_files:
        print(f"No WPP .txt files found in {watch_dir}")
        return

    print(f"Processing {len(txt_files)} file(s)...")
    creatures = parse_wpp_files([str(f) for f in txt_files])
    write_lua(creatures, str(output_path), var_name='CreatureCodexWPP')
    print(f"\nReady! Type '/cc sync' in-game or /reload to import.")


if __name__ == '__main__':
    main()
