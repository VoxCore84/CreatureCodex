#!/bin/bash
# CreatureCodex — Parse existing captures (Linux/macOS wrapper)
# NOTE: session.py uses Windows-specific APIs (tasklist, os.startfile).
# Parsing itself is portable but process detection features won't work.
cd "$(dirname "$0")"
python3 session.py --parse "$@"
