# Server Setup — CreatureCodex v1.0.0

**This guide is for TrinityCore developers who build their server from source.**
If you're running a prebuilt repack without source access, skip this — the client addon works on its own.

## What the Server Hooks Do

The client addon captures ~80% of creature spells through visual scanning. The server hooks catch the remaining 20% — instant casts, hidden spells, triggered abilities, and auras applied without visible cast bars.

With both running, you get 100% coverage.

## Requirements

- TrinityCore source code (`master` branch, tested as of 2026-03-13; newer snapshots may require minor API adjustments)
- C++20 compiler (MSVC 2022+, GCC 13+, Clang 16+)
- Ability to rebuild your server

## Option A: Auto-Patcher (Recommended)

The included Python script finds the right spots in your TC source and inserts the hooks automatically.

```
cd server/
python install_hooks.py C:\path\to\TrinityCore
```

Preview first without changing anything:
```
python install_hooks.py C:\path\to\TrinityCore --dry-run
```

Remove the hooks later (best-effort — may leave minor whitespace artifacts; verify with `git diff`):
```
python install_hooks.py C:\path\to\TrinityCore --revert
```

## Option B: Manual Patching

See `server/HOOKS.md` for the exact code and file locations. The core patch is 4 hook call sites across 4 files; full integration also requires the `WorldSession` helper, RBAC enum, and script loader registration (all documented in the steps above).

## After Patching

1. **Copy the server scripts** into your TrinityCore source:
   ```
   server/creature_codex_sniffer.cpp  →  src/server/scripts/Custom/
   server/cs_creature_codex.cpp       →  src/server/scripts/Custom/
   ```

2. **Add the IsAddonRegistered helper** — the sniffer checks if players have the `CCDX` addon registered before broadcasting. Add these two small pieces:

   **`src/server/game/Server/WorldSession.h`** — Add to the `public:` section:
   ```cpp
   bool IsAddonRegistered(std::string_view prefix) const;
   ```

   **`src/server/game/Server/WorldSession.cpp`**:
   ```cpp
   bool WorldSession::IsAddonRegistered(std::string_view prefix) const
   {
       for (auto const& p : _registeredAddonPrefixes)
           if (p == prefix)
               return true;
       return false;
   }
   ```

3. **Register them** in `src/server/scripts/Custom/custom_script_loader.cpp`:
   ```cpp
   // At the top, add the declarations:
   void AddSC_creature_codex_sniffer();
   void AddSC_creature_codex_commands();

   // Inside AddCustomScripts(), add:
   AddSC_creature_codex_sniffer();
   AddSC_creature_codex_commands();
   ```

4. **Rebuild your server**

5. **Start the server** and log in — the addon status bar should show `CreatureCodex: Active`

## GM Commands

The `.codex` command tree requires RBAC permission 3012. Assign it to your GM accounts.

| Command | What it does |
|---------|-------------|
| `.codex query <entry>` | Show all spells assigned to a creature in `creature_template_spell` |
| `.codex stats` | Sniffer statistics (online players, addon users, blacklist) |
| `.codex blacklist add <spellId>` | Stop broadcasting a noisy spell |
| `.codex blacklist remove <spellId>` | Resume broadcasting a spell |
| `.codex blacklist list` | Show all blacklisted spells |

## Known Limitations

- The hooks require **custom patches** not in stock TrinityCore. If TC changes the function signatures in `Spell.cpp` or `Unit.cpp`, the auto-patcher may need updating
- **Passive auras** that are never "applied" through `_ApplyAura` won't trigger the hook
- **Pet/vehicle spells** may be attributed to the vehicle rather than the creature inside it
