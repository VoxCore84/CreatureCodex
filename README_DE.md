# CreatureCodex

Server-gestützter Kreatur-Zauber- und Aura-Sniffer für TrinityCore-basierte WoW-Emulatoren.

CreatureCodex erfasst jeden Zauberspruch, jede Kanalisierung und jede Aura-Anwendung von Kreaturen — einschließlich sofortiger/versteckter Zauber, die die Client-API nicht sehen kann — und speichert sie in einer durchsuchbaren Datenbank, die als SQL für `creature_template_spell` oder SmartAI exportiert werden kann.

## Warum dieses Tool existiert

TrinityCore-Emulatoren brauchen vollständige Kreatur-Zauberdaten in `creature_template_spell`, damit NPCs richtig kämpfen. Ohne diese Daten stehen Mobs einfach da und auto-attacken. Diese Daten werden nicht in DB2-Dateien mitgeliefert — sie müssen von einem Live-Retail-Server beobachtet werden, entweder durch Paketmitschnitte oder Addon-basiertes Scraping.

**Der 12.x Midnight-Client hat das dramatisch erschwert:**

- **`COMBAT_LOG_EVENT_UNFILTERED` ist praktisch tot.** Das Kampflog war früher der Goldstandard zum Erfassen von Kreatur-Zaubern. In 12.x sind Cross-Addon-Kommunikation und GUID-Tracking stark eingeschränkt. Passives Lauschen auf CLEU liefert keine zuverlässigen Kreatur-Zauberdaten mehr.

- **Taint und geheime Werte.** Die 12.x-Engine injiziert aktiv undurchsichtige C++ `userdata`-Taints in zentrale UI-Variablen — Zauber-IDs, GUIDs, Aura-Daten. Die `issecretvalue()`-Funktion kontrolliert den Zugriff auf diese Werte, und Standard-Lua `tonumber()`/`tostring()` versagen stillschweigend bei getainteten Daten. Jedes Addon, das Zauber- oder Unit-Daten anfasst, muss jeden Zugriff in `pcall` mit expliziter Secret-Value-Prüfung wrappen — sonst bricht es ohne Warnung.

- **Sofortzauber und versteckte Casts sind unsichtbar.** `UnitCastingInfo` und `UnitChannelInfo` sehen nur Zauber mit sichtbarer Zauberleiste. Sofortzauber, getriggerte Zauber und viele Boss-Mechaniken erscheinen nie in diesen APIs. Auf Retail bedeutet das, dass ein erheblicher Teil der Zauberliste einer Kreatur client-seitig schlicht nicht beobachtbar ist.

- **Traditionelles Sniffen ist aufwendig.** Die klassische Pipeline — Ymir-Paket-Sniffer starten, Traffic mitschneiden, mit WowPacketParser parsen, Zauberdaten manuell extrahieren — funktioniert, erfordert aber spezialisiertes Tooling, sorgfältiges Cache-Leeren, bestimmte Bewegungsmuster (Laufen = dichte Daten, Fliegen = dünn) und erhebliche Nachbearbeitung. Nichts, was man einer Gilde geben und sagen kann „helft mal mit".

**CreatureCodex löst das mit einem Zwei-Schichten-Ansatz:**

Der client-seitige visuelle Scanner holt das Beste aus den eingeschränkten APIs heraus — pollt Zauberleisten mit 10 Hz, scannt Nameplate-Auren mit 5 Hz, wrappt jeden Zugriff in Taint-sichere Helfer. Das funktioniert auf jedem Server ohne Patches.

Die server-seitigen C++-Hooks umgehen alle Client-Einschränkungen komplett. Vier `UnitScript`-Hooks feuern bei jedem `Spell::cast()`, `Spell::SendSpellGo()`, `Spell::SendChannelUpdate()` und `Unit::_ApplyAura()` — und erfassen 100% aller Casts, einschließlich sofortiger, versteckter und getriggerter Zauber. Die Daten werden als leichtgewichtige Addon-Nachrichten nur an nahestehende Spieler mit installiertem Addon gesendet — null Overhead für alle anderen.

Wenn beide Schichten zusammenarbeiten, dedupliziert das Addon automatisch und Sie erhalten vollständige, lückenlose Kreatur-Zauberdatenbanken, die direkt als SQL exportiert werden können.

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

Für die Aggregation SQL anwenden:
```
mysql -u root -p roleplay < sql/roleplay_codex_aggregated.sql
```

### Schritt 7: Client-Addon installieren

Kopieren Sie den `client/`-Inhalt nach `Interface\AddOns\CreatureCodex\` und kompilieren Sie Ihren Server neu.

## Verwendung

### Slash-Befehle

| Befehl | Beschreibung |
|--------|-------------|
| `/cc` oder `/codex` | Browser-Panel ein-/ausblenden |
| `/cc export` | Export-Panel öffnen |
| `/cc wipe` | Alle gespeicherten Daten löschen |
| `/cc search <Name>` | Kreaturen nach Namen suchen |
| `/cc zone` | Nur Kreaturen der aktuellen Zone anzeigen |
| `/cc stats` | Erfassungsstatistiken ausgeben |

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
    roleplay_codex_aggregated.sql -- Mehrspieler-Aggregationstabelle
  README.md                       -- Englische Version
  README_RU.md                    -- Russische Version
  README_DE.md                    -- Diese Datei
```

## Lizenz

MIT. Bibliotheken in `Libs/` behalten ihre ursprünglichen Lizenzen.
