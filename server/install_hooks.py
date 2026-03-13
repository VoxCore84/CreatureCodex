#!/usr/bin/env python3
"""
CreatureCodex Hook Installer — patches TrinityCore source with the 4 UnitScript hooks
needed for server-side creature spell broadcasting.

This script searches for anchor patterns in your TC source and inserts the hook code
at the correct locations. Works across TC versions as long as the anchor patterns exist.

Usage:
    python install_hooks.py C:\path\to\TrinityCore
    python install_hooks.py C:\path\to\TrinityCore --dry-run   # Preview changes only
    python install_hooks.py C:\path\to\TrinityCore --revert    # Remove installed hooks

Requirements: Python 3.10+, TrinityCore source (master branch, tested 2026-03-13)
"""

import argparse
import re
import sys
from pathlib import Path

# =============================================================================
# Hook definitions — what gets added and where
# =============================================================================

HOOKS = [
    # --- ScriptMgr.h: Virtual methods in UnitScript class ---
    {
        "file": "src/server/game/Scripting/ScriptMgr.h",
        "description": "UnitScript virtual hook declarations",
        "anchor": "virtual void ModifySpellDamageTaken(Unit* target, Unit* attacker, int32& damage, SpellInfo const* spellInfo);",
        "position": "after",
        "code": """
        // CreatureCodex hooks — creature spell/aura broadcasting
        virtual void OnCreatureSpellCast(Creature* /*creature*/, SpellInfo const* /*spell*/) { }
        virtual void OnCreatureSpellStart(Creature* /*creature*/, SpellInfo const* /*spell*/) { }
        virtual void OnCreatureChannelFinished(Creature* /*creature*/, SpellInfo const* /*spell*/) { }
        virtual void OnAuraApply(Unit* /*target*/, AuraApplication* /*aurApp*/) { }""",
        "marker": "CreatureCodex hooks — creature spell/aura broadcasting",
    },
    # --- ScriptMgr.h: Public dispatch declarations in ScriptMgr class ---
    {
        "file": "src/server/game/Scripting/ScriptMgr.h",
        "description": "ScriptMgr dispatch declarations",
        "anchor": "void ModifySpellDamageTaken(Unit* target, Unit* attacker, int32& damage, SpellInfo const* spellInfo);",
        "position": "after",
        "code": """
        // CreatureCodex dispatch declarations
        void OnCreatureSpellCast(Creature* creature, SpellInfo const* spell);
        void OnCreatureSpellStart(Creature* creature, SpellInfo const* spell);
        void OnCreatureChannelFinished(Creature* creature, SpellInfo const* spell);
        void OnAuraApply(Unit* target, AuraApplication* aurApp);""",
        "marker": "CreatureCodex dispatch declarations",
        "anchor_context": "public: /* UnitScript */",
    },
    # --- ScriptMgr.cpp: Dispatch implementations ---
    {
        "file": "src/server/game/Scripting/ScriptMgr.cpp",
        "description": "ScriptMgr dispatch implementations",
        "anchor": "void ScriptMgr::ModifySpellDamageTaken(Unit* target, Unit* attacker, int32& damage, SpellInfo const* spellInfo)\n{\n    FOREACH_SCRIPT(UnitScript)->ModifySpellDamageTaken(target, attacker, damage, spellInfo);\n}",
        "position": "after",
        "code": """

// CreatureCodex hooks
void ScriptMgr::OnCreatureSpellCast(Creature* creature, SpellInfo const* spell)
{
    FOREACH_SCRIPT(UnitScript)->OnCreatureSpellCast(creature, spell);
}

void ScriptMgr::OnCreatureSpellStart(Creature* creature, SpellInfo const* spell)
{
    FOREACH_SCRIPT(UnitScript)->OnCreatureSpellStart(creature, spell);
}

void ScriptMgr::OnCreatureChannelFinished(Creature* creature, SpellInfo const* spell)
{
    FOREACH_SCRIPT(UnitScript)->OnCreatureChannelFinished(creature, spell);
}

void ScriptMgr::OnAuraApply(Unit* target, AuraApplication* aurApp)
{
    FOREACH_SCRIPT(UnitScript)->OnAuraApply(target, aurApp);
}""",
        "marker": "OnCreatureSpellCast",
    },
    # --- Spell.cpp: OnCreatureSpellStart call site ---
    {
        "file": "src/server/game/Spells/Spell.cpp",
        "description": "OnCreatureSpellStart call site (Spell::prepare)",
        "anchor_regex": r"(if \(caster->IsAIEnabled\(\)\)\s*\n\s*caster->AI\(\)->OnSpellStart\(GetSpellInfo\(\)\);)",
        "position": "after_match",
        "code": "\n            sScriptMgr->OnCreatureSpellStart(caster, GetSpellInfo());",
        "marker": "OnCreatureSpellStart",
    },
    # --- Spell.cpp: OnCreatureSpellCast call site ---
    {
        "file": "src/server/game/Spells/Spell.cpp",
        "description": "OnCreatureSpellCast call site (Spell::SendSpellGo)",
        "anchor_regex": r"(if \(caster->IsAIEnabled\(\)\)\s*\n\s*caster->AI\(\)->OnSpellCast\(GetSpellInfo\(\)\);)",
        "position": "after_match",
        "code": "\n            sScriptMgr->OnCreatureSpellCast(caster, GetSpellInfo());",
        "marker": "OnCreatureSpellCast",
    },
    # --- Spell.cpp: OnCreatureChannelFinished call site ---
    {
        "file": "src/server/game/Spells/Spell.cpp",
        "description": "OnCreatureChannelFinished call site (Spell::update channel)",
        "anchor_regex": r"(if \(creatureCaster->IsAIEnabled\(\)\)\s*\n\s*creatureCaster->AI\(\)->OnChannelFinished\(m_spellInfo\);)",
        "position": "after_match",
        "code": "\n                    sScriptMgr->OnCreatureChannelFinished(creatureCaster, m_spellInfo);",
        "marker": "OnCreatureChannelFinished",
    },
    # --- Unit.cpp: OnAuraApply call site ---
    {
        "file": "src/server/game/Entities/Unit/Unit.cpp",
        "description": "OnAuraApply call site (Unit::_ApplyAura)",
        "anchor_regex": r"(player->UpdateCriteria\(CriteriaType::GainAura, aura->GetId\(\), 0, 0, caster\);\s*\n\s*\})",
        "position": "after_match",
        "code": "\n\n    sScriptMgr->OnAuraApply(this, aurApp);",
        "marker": "OnAuraApply",
    },
]


def find_tc_root(path: Path) -> Path | None:
    """Verify this is a TrinityCore source directory."""
    if (path / "src" / "server" / "game" / "Scripting" / "ScriptMgr.h").exists():
        return path
    # Maybe they pointed at src/
    if (path / "server" / "game" / "Scripting" / "ScriptMgr.h").exists():
        return path.parent
    return None


def check_already_installed(tc_root: Path) -> bool:
    """Check if hooks are already installed."""
    smh = tc_root / "src/server/game/Scripting/ScriptMgr.h"
    content = smh.read_text(encoding="utf-8", errors="replace")
    return "OnCreatureSpellCast" in content


def revert_hooks(tc_root: Path) -> bool:
    """Remove CreatureCodex hooks from source files."""
    files_to_clean = set(h["file"] for h in HOOKS)
    reverted = 0

    for rel_path in files_to_clean:
        filepath = tc_root / rel_path
        if not filepath.exists():
            continue

        content = filepath.read_text(encoding="utf-8", errors="replace")
        original = content

        # Remove comment blocks + code blocks for our hooks
        # Pattern: remove lines containing our markers and surrounding CreatureCodex comments
        lines = content.split("\n")
        new_lines = []
        skip_block = False
        i = 0
        while i < len(lines):
            line = lines[i]
            # Start of our comment block
            if "CreatureCodex hook" in line or "CreatureCodex dispatch" in line:
                skip_block = True
                i += 1
                continue
            # Our specific function signatures
            if any(m in line for m in ["OnCreatureSpellCast", "OnCreatureSpellStart",
                                        "OnCreatureChannelFinished",
                                        "sScriptMgr->OnAuraApply"]):
                # Also skip surrounding empty lines and closing brace if it's a function block
                if i + 1 < len(lines) and lines[i + 1].strip() == "{":
                    # Skip the whole function block
                    while i < len(lines) and not (lines[i].strip() == "}" and
                                                   i > 0 and "FOREACH_SCRIPT" in lines[i - 1]):
                        i += 1
                    i += 1  # skip the closing brace
                    continue
                i += 1
                continue
            # OnAuraApply in UnitScript virtual declaration
            if "OnAuraApply" in line and ("virtual" in line or "sScriptMgr" in line or
                                          "void ScriptMgr::" in line or "void On" in line):
                i += 1
                continue

            skip_block = False
            new_lines.append(line)
            i += 1

        new_content = "\n".join(new_lines)
        if new_content != original:
            filepath.write_text(new_content, encoding="utf-8")
            reverted += 1
            print(f"  REVERTED: {rel_path}")
        else:
            print(f"  CLEAN: {rel_path} (no hooks found)")

    return reverted > 0


def validate_hook_against_content(content: str, hook: dict) -> tuple[bool, str | None]:
    """Validate a hook against file content already in memory.
    Returns (ok, new_content_or_None). new_content is the full file after this hook is applied."""
    if hook["marker"] in content:
        print(f"  SKIP (already present): {hook['description']}")
        return True, None  # None means no write needed

    if "anchor_regex" in hook:
        match = re.search(hook["anchor_regex"], content)
        if not match:
            print(f"  FAIL: Anchor pattern not found for {hook['description']}")
            print(f"         Pattern: {hook['anchor_regex'][:80]}...")
            return False, None
        insert_pos = match.end()
        new_content = content[:insert_pos] + hook["code"] + content[insert_pos:]
    elif "anchor" in hook:
        anchor = hook["anchor"]
        positions = []
        start = 0
        while True:
            idx = content.find(anchor, start)
            if idx == -1:
                break
            positions.append(idx)
            start = idx + 1

        if not positions:
            print(f"  FAIL: Anchor not found for {hook['description']}")
            print(f"         Anchor: {anchor[:80]}...")
            return False, None

        target_pos = positions[0]
        if len(positions) > 1 and "anchor_context" in hook:
            ctx = hook["anchor_context"]
            for pos in positions:
                preceding = content[max(0, pos - 500):pos]
                if ctx in preceding:
                    target_pos = pos
                    break

        insert_pos = target_pos + len(anchor)
        new_content = content[:insert_pos] + hook["code"] + content[insert_pos:]
    else:
        print(f"  FAIL: No anchor defined for {hook['description']}")
        return False, None

    print(f"  OK: {hook['description']}")
    return True, new_content


def main():
    parser = argparse.ArgumentParser(
        description="CreatureCodex Hook Installer — patches TrinityCore with UnitScript hooks"
    )
    parser.add_argument("tc_path", help="Path to TrinityCore source root")
    parser.add_argument("--dry-run", action="store_true",
                        help="Preview changes without modifying files")
    parser.add_argument("--revert", action="store_true",
                        help="Remove CreatureCodex hooks from source")
    args = parser.parse_args()

    tc_path = Path(args.tc_path).resolve()
    tc_root = find_tc_root(tc_path)

    if not tc_root:
        print(f"ERROR: {tc_path} doesn't look like a TrinityCore source tree.")
        print("  Expected to find: src/server/game/Scripting/ScriptMgr.h")
        sys.exit(1)

    print(f"TrinityCore source: {tc_root}")
    print()

    if args.revert:
        print("Reverting CreatureCodex hooks...")
        if revert_hooks(tc_root):
            print("\nHooks removed. Rebuild your server to apply.")
        else:
            print("\nNo hooks found to revert.")
        return

    if check_already_installed(tc_root):
        print("CreatureCodex hooks are already installed!")
        print("  Use --revert to remove them, or --dry-run to preview.")
        return

    # Group hooks by file so we accumulate edits per file
    from collections import OrderedDict
    hooks_by_file: dict[str, list[dict]] = OrderedDict()
    for hook in HOOKS:
        hooks_by_file.setdefault(hook["file"], []).append(hook)

    num_files = len(hooks_by_file)
    mode = "DRY RUN" if args.dry_run else "INSTALLING"
    print(f"[{mode}] Patching {len(HOOKS)} hooks into {num_files} files...")
    print()

    # Phase 1: Validate ALL hooks, accumulating edits per file
    print("Phase 1: Validating anchors...")
    file_contents: dict[str, str] = {}  # rel_path -> final accumulated content
    failed = 0
    total_applied = 0
    total_skipped = 0

    for rel_path, file_hooks in hooks_by_file.items():
        filepath = tc_root / rel_path
        if not filepath.exists():
            print(f"  FAIL: {rel_path} not found!")
            failed += len(file_hooks)
            continue

        # Read the file ONCE, then apply all hooks sequentially to the buffer
        content = filepath.read_text(encoding="utf-8", errors="replace")
        for hook in file_hooks:
            ok, new_content = validate_hook_against_content(content, hook)
            if not ok:
                failed += 1
            elif new_content is not None:
                content = new_content  # accumulate: next hook sees previous hook's edits
                total_applied += 1
            else:
                total_skipped += 1  # already present

        file_contents[rel_path] = content

    if failed:
        print(f"\nERROR: {failed} hook(s) failed validation. No files were modified.")
        print("Fix the issues above or apply manually — see HOOKS.md")
        sys.exit(1)

    if args.dry_run:
        print(f"\nDry run complete. {total_applied} hooks would be applied, "
              f"{total_skipped} already present.")
        print("Run without --dry-run to apply.")
        return

    # Phase 2: Write each file ONCE with all its hooks accumulated
    if total_applied > 0:
        print(f"\nPhase 2: Writing {total_applied} hooks across {num_files} files...")
        for rel_path, content in file_contents.items():
            filepath = tc_root / rel_path
            original = filepath.read_text(encoding="utf-8", errors="replace")
            if content != original:
                filepath.write_text(content, encoding="utf-8")
                print(f"  PATCHED: {rel_path}")

    print(f"\nAll {total_applied + total_skipped} hooks installed successfully!")
    print()
    print("Next steps:")
    print("  1. Copy creature_codex_sniffer.cpp to src/server/scripts/Custom/")
    print("  2. Copy cs_creature_codex.cpp to src/server/scripts/Custom/")
    print("  3. Register in custom_script_loader.cpp:")
    print('     void AddSC_creature_codex_sniffer();')
    print('     void AddSC_creature_codex_commands();')
    print('     AddSC_creature_codex_sniffer();')
    print('     AddSC_creature_codex_commands();')
    print("  4. Rebuild your server")


if __name__ == "__main__":
    main()
