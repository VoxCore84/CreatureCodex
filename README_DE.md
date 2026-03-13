# CreatureCodex

[![GitHub](https://img.shields.io/github/v/release/VoxCore84/CreatureCodex?label=latest)](https://github.com/VoxCore84/CreatureCodex/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Ihre NPCs kämpfen nicht. Sie stehen da und auto-attacken, weil `creature_template_spell` leer ist und kein SmartAI ihnen sagt, was sie zaubern sollen. CreatureCodex behebt das.

**Repository:** [github.com/VoxCore84/CreatureCodex](https://github.com/VoxCore84/CreatureCodex)

## Was es macht

1. **Addon installieren** auf jedem TrinityCore-Server — Repacks eingeschlossen, keine Server-Patches nötig
2. **In der Nähe von Kreaturen herumlaufen** — das Addon erfasst jeden Zauber, jede Kanalisierung und Aura in Echtzeit
3. **Export-Panel öffnen**, Tab **SmartAI** wählen — fertiges SQL mit geschätzten Cooldowns, HP-Phasen-Triggern und Zieltypen
4. **SQL anwenden** — Ihre NPCs zaubern jetzt mit richtigem Timing und Verhalten

CreatureCodex verwandelt Beobachtung in funktionierendes SmartAI. Sie schauen Mobs beim Kämpfen zu, es schreibt die `smart_scripts` und `creature_template_spell` Inserts für Sie.

### Die vollständige Pipeline

```
An Mobs herangehen → Addon erfasst Zauber → Im Spiel durchsuchen → Als SQL exportieren
                                                                      ├── creature_template_spell (Zauberlisten)
                                                                      ├── smart_scripts (AI mit Cooldowns)
                                                                      └── new-only (nur die Lücken)
```

Der SmartAI-Export ist nicht nur eine Liste von Zauber-IDs — er nutzt die Timing-Intelligenz des Addons zur Cooldown-Schätzung aus beobachteten Cast-Intervallen, erkennt HP-Phasen-Fähigkeiten (Zauber die nur unter 40% HP gesehen werden, erhalten `event_type=2` statt zeitbasierter Wiederholungen), und leitet Zieltypen aus dem Cast-zu-Aura-Verhältnis ab. Ein erster Entwurf zum Feintunen, kein leeres Blatt.

## Warum das ohne dieses Tool schwer ist

Diese Daten werden nicht in DB2-Dateien mitgeliefert. Sie müssen von einem Live-Server beobachtet werden. In 12.x wurde das dramatisch schwerer:

- **`COMBAT_LOG_EVENT_UNFILTERED` ist praktisch tot.** Das Kampflog war der Goldstandard. In 12.x ist Cross-Addon GUID-Tracking stark eingeschränkt. Passives CLEU-Lauschen liefert keine zuverlässigen Daten mehr.

- **Taint und geheime Werte.** Die 12.x-Engine injiziert undurchsichtige C++ `userdata`-Taints in Zauber-IDs, GUIDs und Aura-Daten. Standard-Lua `tonumber()`/`tostring()` versagen stillschweigend. Jedes Addon muss jeden Zugriff in `pcall` mit `issecretvalue()`-Prüfungen wrappen.

- **Sofortzauber sind unsichtbar.** `UnitCastingInfo`/`UnitChannelInfo` sehen nur Zauber mit Zauberleiste. Sofortzauber, getriggerte Zauber und viele Boss-Mechaniken erscheinen nie — ein erheblicher Teil jeder Kreatur-Zauberliste ist client-seitig nicht beobachtbar.

- **Traditionelles Sniffen ist aufwendig.** Die Ymir → WowPacketParser Pipeline funktioniert, erfordert aber spezialisiertes Tooling, Cache-Leeren, bestimmte Bewegungsmuster (Laufen = dicht, Fliegen = dünn) und erhebliche Nachbearbeitung.

**CreatureCodex umgeht all das.** Der client-seitige Scanner pollt Zauberleisten mit 10 Hz und scannt Auren mit 5 Hz mit Taint-sicheren Wrappern. Funktioniert auf jedem Server — Repacks, Custom Builds, alles mit 12.x-Client.

Für Server mit C++-Hook-Möglichkeit fangen vier `UnitScript`-Callbacks 100% aller Casts ab, einschließlich sofortiger und versteckter. Beide Schichten deduplizieren automatisch — null Lücken, null Rauschen.

## Funktionsweise

CreatureCodex hat zwei Schichten:

1. **Client-seitiger visueller Scanner** (funktioniert überall, keine Server-Patches nötig)
   - Fragt `UnitCastingInfo`/`UnitChannelInfo` mit 10 Hz ab
   - Scannt Nameplates im Round-Robin-Verfahren mit 5 Hz nach Auren
   - Zeichnet Zaubername, Schule, Kreatur-Entry, HP% und Zeitstempel auf

2. **Server-seitiger Sniffer** (erfordert TrinityCore C++-Hooks)
   - Vier `UnitScript`-Hooks übertragen jedes Kreatur-Zauber-Event als Addon-Nachricht
   - Erfasst 100% aller Zauber, einschließlich sofortiger/versteckter
   - Sendet nur an Spieler in der Nähe (100 Yard) mit installiertem CreatureCodex

Wenn beide Schichten zusammenarbeiten, dedupliziert das Addon automatisch — vollständige Abdeckung ohne Lücken.

## Nur-Client-Installation (keine Server-Patches)

Wenn Sie nur den visuellen Scanner ohne Server-Modifikation möchten:

1. Kopieren Sie den Inhalt des `client/`-Ordners nach:
   ```
   Interface\AddOns\CreatureCodex\
   ```
2. Der Ordner sollte enthalten: `CreatureCodex.toc`, `CreatureCodex.lua`, `Export.lua`, `UI.lua`, `Minimap.lua` und den `Libs/`-Ordner.
3. Einloggen. Das Addon registriert sich automatisch über Addon Compartment und Minimap-Button.
4. Gehen Sie in die Nähe von Kreaturen und beobachten Sie Kämpfe — Zauber werden in Echtzeit erfasst.

**Was Sie bekommen**: Sichtbare Zauber und Kanalisierungen (alles, was die WoW-API erkennen kann).
**Was Sie verpassen**: Sofortzauber, versteckte Zauber und Auren ohne sichtbare Zauberleiste.

## Vollinstallation (Server + Client)

### Voraussetzungen

- TrinityCore `master`-Branch (12.x / The War Within)
- C++20-Compiler (MSVC 2022+, GCC 13+, Clang 16+)
- Eluna Lua Engine (optional, für Zauberlisten-Abfragen und Aggregation)

### Schritt 1: Core-Hooks zu ScriptMgr hinzufügen

Diese vier virtuellen Methoden müssen zu `UnitScript` in Ihrem ScriptMgr hinzugefügt werden.

**`src/server/game/Scripting/ScriptMgr.h`** — Zu `class UnitScript` hinzufügen:
```cpp
// CreatureCodex Hooks
virtual void OnCreatureSpellCast(Creature* /*creature*/, SpellInfo const* /*spell*/) {}
virtual void OnCreatureSpellStart(Creature* /*creature*/, SpellInfo const* /*spell*/) {}
virtual void OnCreatureChannelFinished(Creature* /*creature*/, SpellInfo const* /*spell*/) {}
virtual void OnAuraApply(Unit* /*target*/, AuraApplication* /*aurApp*/) {}
```

**`src/server/game/Scripting/ScriptMgr.cpp`** — FOREACH_SCRIPT-Dispatcher hinzufügen:
```cpp
void ScriptMgr::OnCreatureSpellCast(Creature* creature, SpellInfo const* spell)
{
    FOREACH_SCRIPT(UnitScript, [&](UnitScript* script) { script->OnCreatureSpellCast(creature, spell); });
}

void ScriptMgr::OnCreatureSpellStart(Creature* creature, SpellInfo const* spell)
{
    FOREACH_SCRIPT(UnitScript, [&](UnitScript* script) { script->OnCreatureSpellStart(creature, spell); });
}

void ScriptMgr::OnCreatureChannelFinished(Creature* creature, SpellInfo const* spell)
{
    FOREACH_SCRIPT(UnitScript, [&](UnitScript* script) { script->OnCreatureChannelFinished(creature, spell); });
}

void ScriptMgr::OnAuraApply(Unit* target, AuraApplication* aurApp)
{
    FOREACH_SCRIPT(UnitScript, [&](UnitScript* script) { script->OnAuraApply(target, aurApp); });
}
```

Außerdem die Deklarationen zur `ScriptMgr`-Klasse im Header hinzufügen:
```cpp
void OnCreatureSpellCast(Creature* creature, SpellInfo const* spell);
void OnCreatureSpellStart(Creature* creature, SpellInfo const* spell);
void OnCreatureChannelFinished(Creature* creature, SpellInfo const* spell);
void OnAuraApply(Unit* target, AuraApplication* aurApp);
```

### Schritt 2: Hooks in Spell.cpp und Unit.cpp einbinden

**`src/server/game/Spells/Spell.cpp`** — In `Spell::SendSpellGo()` (nach dem Paketversand):
```cpp
if (Creature* creature = m_caster->ToCreature())
    sScriptMgr->OnCreatureSpellCast(creature, m_spellInfo);
```

**`src/server/game/Spells/Spell.cpp`** — Am Anfang von `Spell::cast()` (nach den initialen Prüfungen):
```cpp
if (Creature* creature = m_caster->ToCreature())
    sScriptMgr->OnCreatureSpellStart(creature, m_spellInfo);
```

**`src/server/game/Spells/Spell.cpp`** — In `Spell::SendChannelUpdate()` wenn `time == 0`:
```cpp
if (Creature* creature = m_caster->ToCreature())
    sScriptMgr->OnCreatureChannelFinished(creature, m_spellInfo);
```

**`src/server/game/Entities/Unit/Unit.cpp`** — In `Unit::_ApplyAura()` (nach erfolgreicher Aura-Anwendung):
```cpp
sScriptMgr->OnAuraApply(this, aurApp);
```

### Schritt 3: IsAddonRegistered-Hilfsmethode hinzufügen

Der Sniffer prüft, ob ein Spieler den `CCDX`-Addon-Prefix registriert hat. Fügen Sie dies zu `WorldSession` hinzu:

**`src/server/game/Server/WorldSession.h`**:
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

### Schritt 4: RBAC-Berechtigung hinzufügen

**`src/server/game/Accounts/RBAC.h`** — Zum Berechtigungs-Enum hinzufügen:
```cpp
RBAC_PERM_COMMAND_CREATURE_CODEX = 3012,
```

Dann SQL anwenden:
```
mysql -u root -p auth < sql/auth_rbac_creature_codex.sql
```

### Schritt 5: Sniffer-Skripte kopieren

1. Kopieren Sie `server/Custom/creature_codex_sniffer.cpp` und `server/Custom/cs_creature_codex.cpp` nach `src/server/scripts/Custom/`.

2. Registrieren Sie sie in `custom_script_loader.cpp`:
   ```cpp
   void AddSC_creature_codex_sniffer();
   void AddSC_creature_codex_commands();

   void AddCustomScripts()
   {
       // ... Ihre bestehenden Skripte ...
       AddSC_creature_codex_sniffer();
       AddSC_creature_codex_commands();
   }
   ```

### Schritt 6: (Optional) Eluna-Server-Skripte

Bei Verwendung von Eluna kopieren Sie `server/lua_scripts/creature_codex_server.lua` in Ihr Eluna-Skriptverzeichnis. Dies fügt hinzu:
- **Zauberlisten-Abfragen**: Addon kann die vollständige Zauberliste aus `creature_template_spell` anfordern
- **Kreatur-Informationen**: Name, Fraktion, Levelbereich, Klassifizierung
- **Zonen-Vollständigkeit**: Alle Kreaturen einer Karte mit bekannten Zauberzahlen abfragen
- **Mehrspieler-Aggregation**: Spieler können Entdeckungen an eine gemeinsame Server-Tabelle senden

Für die Aggregation SQL auf die gewünschte Datenbank anwenden (Standard: `characters`):
```
mysql -u root -p characters < sql/codex_aggregated.sql
```

Bei Verwendung einer anderen Datenbank auch `AGGREGATION_DB` am Anfang von `creature_codex_server.lua` anpassen.

### Schritt 7: Client-Addon installieren

Kopieren Sie den `client/`-Inhalt nach `Interface\AddOns\CreatureCodex\` und kompilieren Sie Ihren Server neu.

## Verwendung

### Slash-Befehle

| Befehl | Beschreibung |
|--------|-------------|
| `/cc` oder `/codex` | Browser-Panel ein-/ausblenden |
| `/cc export` | Export-Panel öffnen |
| `/cc debug` | Debug-Ausgabe im Chat ein-/ausschalten |
| `/cc stats` | Erfassungsstatistiken ausgeben |
| `/cc zone` | Zonen-Kreaturdaten vom Server abfragen (erfordert Eluna) |
| `/cc submit` | Aggregierte Daten an Server senden (erfordert Eluna) |
| `/cc reset` | Alle gespeicherten Daten löschen (mit Bestätigung) |

### GM-Befehle (erfordert RBAC 3012)

| Befehl | Beschreibung |
|--------|-------------|
| `.codex query <entry>` | Alle Zauber für einen Kreatur-Entry anzeigen |
| `.codex stats` | Sniffer-Statistiken (Online-Spieler, Addon-Nutzer, Blacklist-Größe) |
| `.codex blacklist add <spellId>` | Zauber zur Broadcast-Blacklist hinzufügen |
| `.codex blacklist remove <spellId>` | Zauber von der Blacklist entfernen |
| `.codex blacklist list` | Alle Blacklist-Einträge anzeigen |

### Export-Formate

Das Export-Panel bietet vier Tabs:

1. **Raw** — Klartext: `KreaturName (entry) - ZauberName [spellId] x Anzahl`
2. **SQL** — Fertige `INSERT INTO creature_template_spell`-Anweisungen
3. **SmartAI** — `INSERT INTO smart_scripts` für AI-gesteuerte Zauber
4. **New Only** — Wie SQL, aber nur Zauber die noch nicht in `creature_template_spell` sind

### Minimap-Button

Linksklick öffnet den Browser. Rechtsklick öffnet den Export. Der Button kann verschoben werden.

## Protokoll-Referenz

Addon und Server kommunizieren über den `CCDX`-Addon-Message-Prefix mit Pipe-getrennten Nachrichten:

| Richtung | Code | Format | Zweck |
|----------|------|--------|-------|
| S->C | `SC` | `SC\|entry\|spellID\|school\|name\|hp%` | Zauber gewirkt |
| S->C | `SS` | `SS\|entry\|spellID\|school\|name\|hp%` | Zauber begonnen |
| S->C | `CF` | `CF\|entry\|spellID\|school\|name\|hp%` | Kanalisierung beendet |
| S->C | `AA` | `AA\|entry\|spellID\|school\|name\|hp%` | Aura angelegt |
| C->S | `SL` | `SL\|entry` | Zauberliste anfordern |
| C->S | `CI` | `CI\|entry` | Kreatur-Info anfordern |
| C->S | `ZC` | `ZC\|mapId` | Zonen-Kreaturen anfordern |
| C->S | `AG` | `AG\|entry\|spellId:count,...` | Aggregierte Daten senden |

## Dateistruktur

```
CreatureCodex/
  client/                          -- Client-Addon
    CreatureCodex.toc
    CreatureCodex.lua              -- Kern-Engine (Erfassung + DB)
    Export.lua                     -- 4-Tab-Export
    UI.lua                        -- Browser-Panel
    Minimap.lua                   -- Minimap-Button
    Libs/                         -- LibStub, CallbackHandler, LibDataBroker, LibDBIcon
  server/
    Custom/
      creature_codex_sniffer.cpp  -- C++ UnitScript-Hooks
      cs_creature_codex.cpp       -- .codex GM-Befehlsbaum
    lua_scripts/
      creature_codex_server.lua   -- Eluna-Handler
  sql/
    auth_rbac_creature_codex.sql  -- RBAC-Berechtigung für .codex
    codex_aggregated.sql -- Mehrspieler-Aggregationstabelle
  README.md                       -- Englische Version
  README_RU.md                    -- Russische Version
  README_DE.md                    -- Diese Datei
```

## Lizenz

MIT. Bibliotheken in `Libs/` behalten ihre ursprünglichen Lizenzen.
