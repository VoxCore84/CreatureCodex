# CreatureCodex Server Hooks — Manual Installation

If you prefer to patch manually instead of using `install_hooks.py`, here's exactly what gets added.

## Overview

4 hooks are added to `UnitScript` in the TrinityCore scripting system:

| Hook | Fires when | File with call site |
|------|-----------|-------------------|
| `OnCreatureSpellCast` | After `Spell::SendSpellGo` (cast complete) | `Spell.cpp` |
| `OnCreatureSpellStart` | At `Spell::prepare` (cast begins) | `Spell.cpp` |
| `OnCreatureChannelFinished` | Channel completes in `Spell::update` | `Spell.cpp` |
| `OnAuraApply` | After `Unit::_ApplyAura` stack/remove checks | `Unit.cpp` |

## File 1: `src/server/game/Scripting/ScriptMgr.h`

### In the `UnitScript` class (after `ModifySpellDamageTaken`):

```cpp
        // CreatureCodex hooks — creature spell/aura broadcasting
        virtual void OnCreatureSpellCast(Creature* /*creature*/, SpellInfo const* /*spell*/) { }
        virtual void OnCreatureSpellStart(Creature* /*creature*/, SpellInfo const* /*spell*/) { }
        virtual void OnCreatureChannelFinished(Creature* /*creature*/, SpellInfo const* /*spell*/) { }
        virtual void OnAuraApply(Unit* /*target*/, AuraApplication* /*aurApp*/) { }
```

### In the `ScriptMgr` class (after the `ModifySpellDamageTaken` dispatch declaration):

```cpp
        void OnCreatureSpellCast(Creature* creature, SpellInfo const* spell);
        void OnCreatureSpellStart(Creature* creature, SpellInfo const* spell);
        void OnCreatureChannelFinished(Creature* creature, SpellInfo const* spell);
        void OnAuraApply(Unit* target, AuraApplication* aurApp);
```

## File 2: `src/server/game/Scripting/ScriptMgr.cpp`

### After the `ModifySpellDamageTaken` implementation:

```cpp
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
}
```

## File 3: `src/server/game/Spells/Spell.cpp`

### In `Spell::prepare` — after the `OnSpellStart` AI call:

```cpp
        if (Creature* caster = m_caster->ToCreature())
        {
            if (caster->IsAIEnabled())
                caster->AI()->OnSpellStart(GetSpellInfo());
            sScriptMgr->OnCreatureSpellStart(caster, GetSpellInfo());  // <-- ADD THIS
        }
```

### In `Spell::SendSpellGo` — after the `OnSpellCast` AI call:

```cpp
        if (Creature* caster = m_originalCaster->ToCreature())
        {
            if (caster->IsAIEnabled())
                caster->AI()->OnSpellCast(GetSpellInfo());
            sScriptMgr->OnCreatureSpellCast(caster, GetSpellInfo());  // <-- ADD THIS
        }
```

### In `Spell::update` channel completion — after the `OnChannelFinished` AI call:

```cpp
                if (Creature* creatureCaster = m_caster->ToCreature())
                {
                    if (creatureCaster->IsAIEnabled())
                        creatureCaster->AI()->OnChannelFinished(m_spellInfo);
                    sScriptMgr->OnCreatureChannelFinished(creatureCaster, m_spellInfo);  // <-- ADD THIS
                }
```

## File 4: `src/server/game/Entities/Unit/Unit.cpp`

### In `Unit::_ApplyAura` — after the player criteria updates:

```cpp
    if (Player* player = ToPlayer())
    {
        // ... existing criteria code ...
        player->UpdateCriteria(CriteriaType::GainAura, aura->GetId(), 0, 0, caster);
    }

    sScriptMgr->OnAuraApply(this, aurApp);  // <-- ADD THIS
}
```

## After patching

1. Copy `creature_codex_sniffer.cpp` → `src/server/scripts/Custom/`
2. Copy `cs_creature_codex.cpp` → `src/server/scripts/Custom/`
3. Add to `custom_script_loader.cpp`:
   ```cpp
   void AddSC_creature_codex_sniffer();
   void AddSC_creature_codex_commands();
   // ... in AddCustomScripts():
   AddSC_creature_codex_sniffer();
   AddSC_creature_codex_commands();
   ```
4. Rebuild your server
