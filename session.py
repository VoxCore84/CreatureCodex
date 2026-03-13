#!/usr/bin/env python3
"""
CreatureCodex Session Manager — automated Ymir + WPP pipeline.

Starts Ymir packet capture, waits for WoW to close, then auto-parses
the captures with WowPacketParser and archives the raw .pkt files.

Ymir auto-closes ~5s after WoW exits (built-in behavior).

Requirements: Python 3.10+, Npcap installed (WinPcap compatibility mode)

Usage:
    python session.py              # Full session: start Ymir → wait for WoW → parse
    python session.py --parse      # Parse existing .pkt dumps only (no Ymir)
    python session.py --no-archive # Don't move .pkt files after parsing
    python session.py --wow-dir "C:\WoW\_retail_"  # Explicit WoW root
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
TOOLS_DIR = SCRIPT_DIR / "tools"

YMIR_EXE = TOOLS_DIR / "Ymir" / "ymir_retail.exe"
YMIR_DUMPS = TOOLS_DIR / "Ymir" / "dumps"
YMIR_ARCHIVE = YMIR_DUMPS / "archived"

WPP_EXE = TOOLS_DIR / "WowPacketParser" / "WowPacketParser.exe"
PARSED_DIR = TOOLS_DIR / "parsed"

WOW_PROCESS = "Wow.exe"
YMIR_PROCESS = "ymir_retail.exe"

DATA_DIR = SCRIPT_DIR / "data"
CONFIG_FILE = SCRIPT_DIR / "session_config.json"

# Common WoW install locations to auto-detect
WOW_SEARCH_PATHS = [
    Path(r"C:\WoW\_retail_"),
    Path(r"C:\World of Warcraft\_retail_"),
    Path(r"C:\Program Files (x86)\World of Warcraft\_retail_"),
    Path(r"C:\Program Files\World of Warcraft\_retail_"),
    Path(r"D:\WoW\_retail_"),
    Path(r"D:\World of Warcraft\_retail_"),
    Path(r"D:\Games\World of Warcraft\_retail_"),
]


def load_wow_root(cli_override=None):
    """Resolve WoW root directory: CLI flag > config cache > auto-detect > prompt."""
    # 1. Explicit CLI override
    if cli_override:
        root = Path(cli_override).resolve()
        if _validate_wow_root(root):
            _save_config(root)
            return root
        print(f"[Config] Warning: --wow-dir '{root}' doesn't look like a WoW root (no WTF/ folder).")
        print(f"         Continuing anyway — SavedVariables backup may fail.")
        _save_config(root)
        return root

    # 2. Saved config
    if CONFIG_FILE.exists():
        try:
            cfg = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
            cached = Path(cfg.get("wow_root", ""))
            if cached.exists():
                return cached
            print(f"[Config] Cached WoW path no longer exists: {cached}")
        except (json.JSONDecodeError, KeyError):
            pass

    # 3. Auto-detect from common paths
    for candidate in WOW_SEARCH_PATHS:
        if _validate_wow_root(candidate):
            print(f"[Config] Auto-detected WoW root: {candidate}")
            _save_config(candidate)
            return candidate

    # 4. Prompt user
    print()
    print("[Config] Could not auto-detect your WoW install location.")
    print("         Provide it with: python session.py --wow-dir \"C:\\path\\to\\_retail_\"")
    print("         (This only needs to be set once — it's saved to session_config.json)")
    print()
    return None


def _validate_wow_root(path):
    """Check if a path looks like a WoW root (has WTF/ or Interface/)."""
    return path.exists() and (
        (path / "WTF").exists() or
        (path / "Interface").exists() or
        (path / "WTF" / "Account").exists()
    )


def _save_config(wow_root):
    """Cache the WoW root path for future runs."""
    try:
        CONFIG_FILE.write_text(
            json.dumps({"wow_root": str(wow_root)}, indent=2),
            encoding="utf-8"
        )
    except OSError:
        pass  # Non-fatal — user can always pass --wow-dir


def is_running(name):
    """Check if a process is running by name."""
    result = subprocess.run(
        ["tasklist", "/FI", f"IMAGENAME eq {name}", "/NH"],
        capture_output=True, text=True
    )
    return name.lower() in result.stdout.lower()


def wait_for_start(name, timeout=600, poll=3):
    """Wait until a process appears."""
    elapsed = 0
    while elapsed < timeout:
        if is_running(name):
            return True
        time.sleep(poll)
        elapsed += poll
    return False


def wait_for_exit(name, timeout=None, poll=3):
    """Wait until a process disappears."""
    elapsed = 0
    while True:
        if not is_running(name):
            return True
        if timeout and elapsed >= timeout:
            return False
        time.sleep(poll)
        elapsed += poll


def find_pkt_files():
    """Find all .pkt files in the Ymir dumps directory."""
    if not YMIR_DUMPS.exists():
        return []
    return sorted(YMIR_DUMPS.glob("*.pkt"))


def snapshot_dir(path):
    """Return set of file paths in a directory (non-recursive)."""
    if not path.exists():
        return set()
    return {f for f in path.iterdir() if f.is_file()}


def parse_with_wpp(pkt_files):
    """Run WowPacketParser on each .pkt file."""
    if not WPP_EXE.exists():
        print("[WPP] Not found. Run 'Update Tools.bat' first.")
        return False

    PARSED_DIR.mkdir(parents=True, exist_ok=True)
    wpp_dir = WPP_EXE.parent

    for pkt in pkt_files:
        print(f"[WPP] Parsing {pkt.name}...")
        size_mb = pkt.stat().st_size / (1024 * 1024)
        print(f"  Size: {size_mb:.1f} MB")

        # Snapshot WPP directory before parsing (to find new output files)
        before_wpp = snapshot_dir(wpp_dir)
        before_dumps = snapshot_dir(YMIR_DUMPS)

        try:
            result = subprocess.run(
                [str(WPP_EXE), str(pkt)],
                cwd=str(wpp_dir),
                timeout=1800  # 30 min max per file
            )
            if result.returncode != 0:
                print(f"  Warning: WPP returned code {result.returncode}")
        except subprocess.TimeoutExpired:
            print(f"  Warning: WPP timed out on {pkt.name}")
            continue

        # Find new files created by WPP (check both directories)
        moved = 0
        for check_dir, before_set in [(wpp_dir, before_wpp), (YMIR_DUMPS, before_dumps)]:
            after = snapshot_dir(check_dir)
            new_files = after - before_set
            for nf in new_files:
                if nf.suffix == ".pkt":
                    continue  # Don't move pkt files
                dest = PARSED_DIR / nf.name
                if dest.exists():
                    dest = PARSED_DIR / f"{nf.stem}_{int(time.time())}{nf.suffix}"
                shutil.move(str(nf), str(dest))
                print(f"  Output: {dest.name}")
                moved += 1

        # Also check for WPP subdirectories (some versions create output folders)
        after_wpp = snapshot_dir(wpp_dir)
        for item in wpp_dir.iterdir():
            if item.is_dir() and item.name.startswith("dump_"):
                dest_dir = PARSED_DIR / item.name
                if dest_dir.exists():
                    shutil.rmtree(dest_dir)
                shutil.move(str(item), str(dest_dir))
                print(f"  Output folder: {item.name}/")
                moved += 1

        if moved == 0:
            print("  No output files detected (WPP may output in-place)")

    return True


def backup_savedvariables(wow_root):
    """Copy CreatureCodex SavedVariables into data/ with timestamp."""
    if not wow_root:
        print("[Data] WoW root not configured — skipping SavedVariables backup.")
        print("       Set it with: python session.py --wow-dir \"C:\\path\\to\\_retail_\"")
        return

    wtf = wow_root / "WTF" / "Account"
    if not wtf.exists():
        print(f"[Data] WTF folder not found at {wow_root} — skipping SavedVariables backup.")
        return

    # Find all account copies, pick the most recently modified
    candidates = sorted(wtf.glob("*/SavedVariables/CreatureCodex.lua"),
                        key=lambda p: p.stat().st_mtime, reverse=True)
    if not candidates:
        print("[Data] No CreatureCodex SavedVariables found yet (first session?).")
        return

    source = candidates[0]
    account = source.parent.parent.name
    size_kb = source.stat().st_size / 1024
    stamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")

    DATA_DIR.mkdir(parents=True, exist_ok=True)

    # Timestamped archive copy
    archive_name = f"CreatureCodex_{stamp}.lua"
    shutil.copy2(str(source), str(DATA_DIR / archive_name))

    # Latest copy (always overwritten)
    shutil.copy2(str(source), str(DATA_DIR / "CreatureCodex_latest.lua"))

    print(f"[Data] Backed up SavedVariables ({size_kb:.0f} KB, account: {account})")
    print(f"  Archive: data/{archive_name}")
    print(f"  Latest:  data/CreatureCodex_latest.lua")


def archive_pkts(pkt_files):
    """Move processed .pkt files to archived folder."""
    YMIR_ARCHIVE.mkdir(parents=True, exist_ok=True)
    for pkt in pkt_files:
        dest = YMIR_ARCHIVE / pkt.name
        if dest.exists():
            dest = YMIR_ARCHIVE / f"{pkt.stem}_{int(time.time())}{pkt.suffix}"
        shutil.move(str(pkt), str(dest))
        print(f"  Archived: {pkt.name}")


def main():
    parser = argparse.ArgumentParser(description="CreatureCodex Session Manager")
    parser.add_argument("--parse", action="store_true",
                        help="Parse existing .pkt dumps without running Ymir")
    parser.add_argument("--no-archive", action="store_true",
                        help="Don't archive .pkt files after parsing")
    parser.add_argument("--wow-dir", type=str, default=None,
                        help="Path to WoW _retail_ folder (saved for future runs)")
    args = parser.parse_args()

    print()
    print("  CreatureCodex Session Manager")
    print("  ==============================")
    print()

    wow_root = load_wow_root(args.wow_dir)

    # --- Parse-only mode ---
    if args.parse:
        pkts = find_pkt_files()
        if not pkts:
            print("No .pkt files found in dumps/")
            return
        print(f"Found {len(pkts)} packet capture(s)")
        print()
        parse_with_wpp(pkts)
        if not args.no_archive:
            print()
            archive_pkts(pkts)
        print()
        backup_savedvariables(wow_root)
        print("\nDone.")
        return

    # --- Full session mode ---

    # Check prerequisites
    if not YMIR_EXE.exists():
        print("[Ymir] Not found. Run 'Update Tools.bat' first.")
        return
    if not WPP_EXE.exists():
        print("[WPP] Not found. Run 'Update Tools.bat' first.")
        return

    # Start Ymir
    if is_running(YMIR_PROCESS):
        print("[Ymir] Already running.")
    else:
        print("[Ymir] Starting packet capture...")
        subprocess.Popen(
            [str(YMIR_EXE)],
            cwd=str(YMIR_EXE.parent),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        time.sleep(2)
        if is_running(YMIR_PROCESS):
            print("[Ymir] Capturing.")
        else:
            print("[Ymir] Failed to start. Is Npcap installed? (https://nmap.org/npcap/)")
            print("  Install with WinPcap compatibility mode enabled.")
            return

    # Wait for WoW
    print()
    if is_running(WOW_PROCESS):
        print(f"[WoW] Already running.")
    else:
        print(f"[WoW] Launch WoW from Battle.net whenever you're ready.")
        print(f"  Waiting for {WOW_PROCESS}...", end="", flush=True)
        if not wait_for_start(WOW_PROCESS, timeout=600):
            print("\n[WoW] Timed out after 10 minutes. Exiting.")
            return
        print(" detected!")

    print()
    print("[Session] Capturing packets. Play the game!")
    print("          This window will auto-parse when you close WoW.")
    print()

    # Wait for WoW to close
    wait_for_exit(WOW_PROCESS)
    print("[WoW] Closed.")

    # Ymir auto-closes ~5s after WoW — wait for it
    print("[Ymir] Waiting for capture to flush...")
    wait_for_exit(YMIR_PROCESS, timeout=30)
    time.sleep(2)  # Extra buffer for file writes

    # Parse
    print()
    pkts = find_pkt_files()
    if not pkts:
        print("No packet captures found. (Did Ymir have time to write?)")
        return

    print(f"Found {len(pkts)} packet capture(s)")
    print()
    parse_with_wpp(pkts)

    if not args.no_archive:
        print()
        archive_pkts(pkts)

    # Back up creature data from SavedVariables
    print()
    backup_savedvariables(wow_root)

    print()
    print(f"Done!")
    print(f"  Parsed output: {PARSED_DIR}")
    print(f"  Archived:      {YMIR_ARCHIVE}")

    # Open parsed folder in Explorer
    if PARSED_DIR.exists():
        os.startfile(str(PARSED_DIR))


if __name__ == "__main__":
    main()
