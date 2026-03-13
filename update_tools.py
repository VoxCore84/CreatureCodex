#!/usr/bin/env python3
"""
CreatureCodex Tool Updater — downloads and keeps WPP & Ymir up to date.

Downloads into a 'tools/' subfolder next to this script (inside the addon
package). On first run, offers to create a desktop shortcut to the tools
folder for easy access.

Requirements: Python 3.10+, gh CLI (authenticated with GitHub)

Usage:
    python update_tools.py              # Check and update both
    python update_tools.py --check      # Check only, don't download
    python update_tools.py --wpp        # Update WPP only
    python update_tools.py --ymir       # Update Ymir only
    python update_tools.py --force      # Force re-download even if current
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

# --- Configuration ---
# Everything lives relative to THIS script's location (inside the addon package)
SCRIPT_DIR = Path(__file__).resolve().parent
TOOLS_DIR = SCRIPT_DIR / "tools"

WPP_DIR = TOOLS_DIR / "WowPacketParser"
WPP_REPO = "TrinityCore/WowPacketParser"
WPP_VERSION_FILE = WPP_DIR / ".version.json"

YMIR_DIR = TOOLS_DIR / "Ymir"
YMIR_REPO = "TrinityCore/ymir"
YMIR_VERSION_FILE = YMIR_DIR / ".version.json"


def run_gh(args: list[str]) -> str:
    """Run a gh CLI command and return stdout."""
    result = subprocess.run(
        ["gh"] + args,
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        raise RuntimeError(f"gh command failed: {result.stderr.strip()}")
    return result.stdout.strip()


def load_version(path: Path) -> dict:
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return {}


def save_version(path: Path, data: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")


# --- WPP (CI artifacts from master branch) ---

def check_wpp() -> dict | None:
    print("[WPP] Checking latest master build...")
    raw = run_gh([
        "api",
        f"repos/{WPP_REPO}/actions/runs?branch=master&status=success&per_page=1",
        "--jq", ".workflow_runs[0] | {id, created_at, head_sha}"
    ])
    if not raw:
        print("[WPP] No successful builds found.")
        return None
    run_info = json.loads(raw)

    artifacts_raw = run_gh([
        "api",
        f"repos/{WPP_REPO}/actions/runs/{run_info['id']}/artifacts",
        "--jq", '[.artifacts[] | select(.name == "WPP-windows-latest-Release") | {name, id, size_in_bytes, expired}][0]'
    ])
    if not artifacts_raw:
        print("[WPP] No Windows Release artifact found.")
        return None
    artifact = json.loads(artifacts_raw)

    if artifact.get("expired"):
        print("[WPP] Latest artifact has expired. Try again after next CI run.")
        return None

    return {
        "run_id": run_info["id"],
        "sha": run_info["head_sha"],
        "created_at": run_info["created_at"],
        "artifact_id": artifact["id"],
        "artifact_name": artifact["name"],
        "size_bytes": artifact["size_in_bytes"],
    }


def update_wpp(force: bool = False):
    latest = check_wpp()
    if not latest:
        return

    current = load_version(WPP_VERSION_FILE)
    if not force and current.get("sha") == latest["sha"]:
        print(f"[WPP] Already up to date (sha: {latest['sha'][:8]}, built: {latest['created_at']})")
        return

    print(f"[WPP] New build available!")
    print(f"  Current: {current.get('sha', 'unknown')[:8]}")
    print(f"  Latest:  {latest['sha'][:8]} ({latest['created_at']})")
    print(f"  Size:    {latest['size_bytes'] // 1024 // 1024}MB")

    with tempfile.TemporaryDirectory() as tmpdir:
        zip_path = Path(tmpdir) / "wpp.zip"
        print(f"[WPP] Downloading...")
        subprocess.run([
            "gh", "api",
            f"repos/{WPP_REPO}/actions/artifacts/{latest['artifact_id']}/zip",
            "--method", "GET",
        ], stdout=open(zip_path, "wb"), check=True, timeout=120)

        extract_dir = Path(tmpdir) / "extracted"
        print("[WPP] Extracting...")
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(extract_dir)

        contents = list(extract_dir.iterdir())
        source = extract_dir
        if len(contents) == 1 and contents[0].is_dir():
            source = contents[0]

        # Backup user config files
        config_backup = {}
        for cfg_name in ["WowPacketParser.exe.config", "Settings.ini"]:
            cfg_path = WPP_DIR / cfg_name
            if cfg_path.exists():
                config_backup[cfg_name] = cfg_path.read_bytes()

        # Replace
        if WPP_DIR.exists():
            shutil.rmtree(WPP_DIR)
        shutil.copytree(source, WPP_DIR)

        for cfg_name, cfg_data in config_backup.items():
            (WPP_DIR / cfg_name).write_bytes(cfg_data)
            print(f"  Restored {cfg_name}")

    save_version(WPP_VERSION_FILE, latest)
    print(f"[WPP] Updated to {latest['sha'][:8]} ({latest['created_at']})")
    print(f"  Location: {WPP_DIR}")


# --- Ymir (GitHub Releases) ---

def check_ymir() -> dict | None:
    print("[Ymir] Checking latest release...")
    raw = run_gh([
        "api", f"repos/{YMIR_REPO}/releases",
        "--jq", '.[0] | {tag_name, name, published_at, assets: [.assets[] | {name, size, browser_download_url}]}'
    ])
    if not raw:
        print("[Ymir] No releases found.")
        return None
    release = json.loads(raw)

    retail_asset = None
    for asset in release.get("assets", []):
        if "retail" in asset["name"].lower() and asset["name"].endswith(".zip"):
            retail_asset = asset
            break

    if not retail_asset:
        print("[Ymir] No retail asset found in latest release.")
        return None

    filename = retail_asset["name"]
    build = filename.replace("ymir_retail_", "").replace(".zip", "")

    return {
        "tag": release["tag_name"],
        "name": release["name"],
        "published_at": release["published_at"],
        "build": build,
        "filename": filename,
        "download_url": retail_asset["browser_download_url"],
        "size_bytes": retail_asset["size"],
    }


def update_ymir(force: bool = False):
    latest = check_ymir()
    if not latest:
        return

    current = load_version(YMIR_VERSION_FILE)
    if not force and current.get("build") == latest["build"]:
        print(f"[Ymir] Already up to date (build: {latest['build']}, released: {latest['published_at']})")
        return

    print(f"[Ymir] New version available!")
    print(f"  Current: {current.get('build', 'unknown')}")
    print(f"  Latest:  {latest['build']} ({latest['published_at']})")
    print(f"  Size:    {latest['size_bytes'] // 1024}KB")

    with tempfile.TemporaryDirectory() as tmpdir:
        zip_path = Path(tmpdir) / latest["filename"]
        print(f"[Ymir] Downloading {latest['filename']}...")

        subprocess.run([
            "curl", "-L", "-o", str(zip_path),
            latest["download_url"]
        ], check=True, timeout=120)

        extract_dir = Path(tmpdir) / "extracted"
        print("[Ymir] Extracting...")
        with zipfile.ZipFile(zip_path) as zf:
            zf.extractall(extract_dir)

        contents = list(extract_dir.iterdir())
        source = extract_dir
        if len(contents) == 1 and contents[0].is_dir():
            source = contents[0]

        # Preserve existing dumps
        dump_backup = []
        if YMIR_DIR.exists():
            dumps_dir = YMIR_DIR / "dumps"
            if dumps_dir.exists():
                for f in dumps_dir.iterdir():
                    dump_backup.append((f.name, f.read_bytes()))

        # Replace
        if YMIR_DIR.exists():
            shutil.rmtree(YMIR_DIR)
        YMIR_DIR.mkdir(parents=True, exist_ok=True)
        for item in source.iterdir():
            dest = YMIR_DIR / item.name
            if item.is_dir():
                shutil.copytree(item, dest, dirs_exist_ok=True)
            else:
                shutil.copy2(item, dest)

        # Restore dumps
        if dump_backup:
            dumps_dir = YMIR_DIR / "dumps"
            dumps_dir.mkdir(exist_ok=True)
            for name, data in dump_backup:
                (dumps_dir / name).write_bytes(data)
            print(f"  Restored {len(dump_backup)} dump file(s)")

    # Ensure dumps dir exists
    (YMIR_DIR / "dumps").mkdir(exist_ok=True)

    save_version(YMIR_VERSION_FILE, latest)
    print(f"[Ymir] Updated to {latest['build']}")
    print(f"  Location: {YMIR_DIR}")


# --- Desktop shortcut ---

def create_desktop_shortcut():
    """Create a Windows shortcut on the Desktop pointing to the tools folder."""
    desktop = Path.home() / "Desktop"
    if not desktop.exists():
        print("  Desktop folder not found, skipping shortcut.")
        return

    shortcut_path = desktop / "CreatureCodex Tools.lnk"
    if shortcut_path.exists():
        print(f"  Shortcut already exists: {shortcut_path}")
        return

    try:
        # Use PowerShell to create .lnk shortcut
        ps_script = f'''
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut("{shortcut_path}")
$sc.TargetPath = "{TOOLS_DIR}"
$sc.Description = "CreatureCodex Tools (WPP + Ymir)"
$sc.Save()
'''
        subprocess.run(
            ["powershell", "-NoProfile", "-Command", ps_script],
            capture_output=True, text=True, check=True, timeout=10
        )
        print(f"  Desktop shortcut created: {shortcut_path}")
    except Exception as e:
        print(f"  Could not create shortcut: {e}")


# --- Main ---

def main():
    parser = argparse.ArgumentParser(
        description="CreatureCodex Tool Updater — downloads WPP & Ymir into the addon's tools/ folder"
    )
    parser.add_argument("--check", action="store_true", help="Check for updates without downloading")
    parser.add_argument("--wpp", action="store_true", help="Update WPP only")
    parser.add_argument("--ymir", action="store_true", help="Update Ymir only")
    parser.add_argument("--force", action="store_true", help="Force re-download even if current")
    parser.add_argument("--no-shortcut", action="store_true", help="Skip desktop shortcut prompt")
    args = parser.parse_args()

    do_both = not args.wpp and not args.ymir

    # Ensure tools directory exists
    TOOLS_DIR.mkdir(parents=True, exist_ok=True)

    if args.check:
        if do_both or args.wpp:
            try:
                info = check_wpp()
                if info:
                    cur = load_version(WPP_VERSION_FILE)
                    if cur.get("sha") == info["sha"]:
                        print(f"[WPP] Up to date ({info['sha'][:8]})")
                    else:
                        print(f"[WPP] UPDATE AVAILABLE: {info['sha'][:8]} ({info['created_at']})")
            except Exception as e:
                print(f"[WPP] Check failed: {e}")
        if do_both or args.ymir:
            try:
                info = check_ymir()
                if info:
                    cur = load_version(YMIR_VERSION_FILE)
                    if cur.get("build") == info["build"]:
                        print(f"[Ymir] Up to date ({info['build']})")
                    else:
                        print(f"[Ymir] UPDATE AVAILABLE: {info['build']} ({info['published_at']})")
            except Exception as e:
                print(f"[Ymir] Check failed: {e}")
        return

    if do_both or args.wpp:
        try:
            update_wpp(force=args.force)
        except Exception as e:
            print(f"[WPP] Error: {e}")

    if do_both or args.ymir:
        try:
            update_ymir(force=args.force)
        except Exception as e:
            print(f"[Ymir] Error: {e}")

    # Offer desktop shortcut on first run (only when --shortcut is passed)
    if not args.no_shortcut and not (TOOLS_DIR / ".shortcut_offered").exists():
        try:
            answer = input("Create a desktop shortcut to the tools folder? [Y/n] ").strip().lower()
            if answer in ("", "y", "yes"):
                create_desktop_shortcut()
        except (EOFError, KeyboardInterrupt):
            pass  # Non-interactive environment
        (TOOLS_DIR / ".shortcut_offered").write_text("done")

    print("\nDone.")
    print(f"Tools location: {TOOLS_DIR}")


if __name__ == "__main__":
    main()
