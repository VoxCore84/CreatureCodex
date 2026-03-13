#!/bin/bash
# CreatureCodex — Update WPP + Ymir (Linux/macOS wrapper)
# NOTE: update_tools.py downloads Windows executables (WPP.exe, Ymir).
# On Linux/macOS you'll need to source WPP/Ymir yourself; this wrapper
# handles the download + version check but the binaries are Windows-only.
cd "$(dirname "$0")"
python3 update_tools.py --no-shortcut "$@"
