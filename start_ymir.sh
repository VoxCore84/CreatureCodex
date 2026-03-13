#!/bin/bash
# CreatureCodex — Start Ymir session (Linux/macOS wrapper)
# NOTE: session.py uses Windows-specific APIs (tasklist, os.startfile).
# This wrapper runs the Python script but some features (process detection,
# auto-open) will not work on Linux/macOS. The core capture logic is portable.
cd "$(dirname "$0")"
python3 session.py "$@"
