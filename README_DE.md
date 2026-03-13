# CreatureCodex v1.0.0

[![GitHub](https://img.shields.io/github/v/release/VoxCore84/CreatureCodex?label=v1.0.0)](https://github.com/VoxCore84/CreatureCodex/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Ihre NPCs kämpfen nicht. Sie stehen da und auto-attacken, weil `creature_template_spell` (die Datenbanktabelle, die Kreaturen Zauber zuweist) leer ist und kein SmartAI (TrinityCore's skriptgesteuertes Verhaltenssystem) ihnen sagt, was sie zaubern sollen. CreatureCodex behebt das.

**Repository:** [github.com/VoxCore84/CreatureCodex](https://github.com/VoxCore84/CreatureCodex)

## Was es macht

1. **Addon installieren** auf jedem TrinityCore-Server — Repacks eingeschlossen, keine Server-Patches nötig
2. **In der Nähe von Kreaturen herumlaufen** — das Addon erfasst sichtbare Zauber, Kanalisierungen und Auren in Echtzeit (Server-Hooks ergänzen Sofortzauber/versteckte Zauber für 100% Abdeckung)
3. **Export-Panel öffnen**, Tab **SmartAI** wählen — fertiges SQL mit geschätzten Cooldowns, HP-Phasen-Triggern und Zieltypen
4. **SQL anwenden** — Ihre NPCs zaubern jetzt mit richtigem Timing und Verhalten

CreatureCodex verwandelt Beobachtung in funktionierendes SmartAI. Sie schauen Mobs beim Kämpfen zu, es schreibt die `smart_scripts` und `creature_template_spell` Inserts für Sie.

### Die vollständige Pipeline

```
                          ┌─ Visueller Scanner (Client-Addon, funktioniert überall)
An Mobs herangehen ───────┼─ Server-Hooks (C++ UnitScript, 100% Abdeckung)
                          └─ Ymir-Integration (Auto-Merge aus Paketmitschnitten)
                                            │
                                            ▼
                                Im Spiel durchsuchen → Als SQL exportieren
                                                        ├── creature_template_spell (Zauberlisten)
                                                        ├── smart_scripts (AI mit Cooldowns)
                                                        └── new-only (nur die Lücken)
```

Der SmartAI-Export ist nicht nur eine Liste von Zauber-IDs — er nutzt die Timing-Intelligenz des Addons zur Cooldown-Schätzung aus beobachteten Cast-Intervallen, erkennt HP-Phasen-Fähigkeiten (Zauber die mindestens einmal unter 40% HP gesehen wurden, erhalten `event_type=2` statt zeitbasierter Wiederholungen), und leitet Zieltypen aus dem Cast-zu-Aura-Verhältnis ab. Ein erster Entwurf zum Feintunen, kein leeres Blatt.

## Warum das ohne dieses Tool schwer ist

Diese Daten werden nicht in DB2-Dateien mitgeliefert. Sie müssen von einem Live-Server beobachtet werden. In 12.x wurde das dramatisch schwerer:

- **`COMBAT_LOG_EVENT_UNFILTERED` ist praktisch tot.** Das Kampflog war der Goldstandard. In 12.x ist Cross-Addon GUID-Tracking stark eingeschränkt. Passives CLEU-Lauschen liefert keine zuverlässigen Daten mehr.

- **Taint und geheime Werte.** Die 12.x-Engine injiziert undurchsichtige C++ `userdata`-Taints in Zauber-IDs, GUIDs und Aura-Daten. Standard-Lua `tonumber()`/`tostring()` versagen stillschweigend. Jedes Addon muss jeden Zugriff in `pcall` mit `issecretvalue()`-Prüfungen wrappen.

- **Sofortzauber sind unsichtbar.** `UnitCastingInfo`/`UnitChannelInfo` sehen nur Zauber mit Zauberleiste. Sofortzauber, getriggerte Zauber und viele Boss-Mechaniken erscheinen nie — ein erheblicher Teil jeder Kreatur-Zauberliste ist client-seitig nicht beobachtbar.

- **Traditionelles Sniffen erfordert Nachbearbeitung.** Die Ymir → WowPacketParser Pipeline liefert die besten Daten, aber die Umwandlung roher Paketmitschnitte in nutzbare Zauberlisten bedeutete immer Offline-Parsing, manuelle Überprüfung und handgeschriebenes SQL.

**CreatureCodex umgeht all das.** Der client-seitige Scanner pollt Zauberleisten mit 10 Hz und scannt Auren mit 5 Hz mit Taint-sicheren Wrappern. Funktioniert auf jedem Server — Repacks, Custom Builds, alles mit 12.x-Client.

Für Server mit C++-Hook-Möglichkeit fangen vier `UnitScript`-Callbacks 100% aller Casts ab, einschließlich sofortiger und versteckter. Beide Schichten deduplizieren automatisch — null Lücken, null Rauschen.

Und wenn Sie mit Ymir sniffen, integriert sich CreatureCodex direkt — starten Sie das enthaltene Tool auf Ihre WPP-Ausgabe, `/reload`, und das Addon führt Sniff-Daten automatisch mit Scanner-Daten zusammen. Oder überspringen Sie das Addon und generieren Sie SQL direkt aus Ihren Paketmitschnitten.

## Funktionsweise

CreatureCodex hat drei Datenquellen:

1. **Client-seitiger visueller Scanner** (funktioniert überall, keine Server-Patches nötig)
   - Fragt `UnitCastingInfo`/`UnitChannelInfo` mit 10 Hz ab
   - Scannt Nameplates im Round-Robin-Verfahren mit 5 Hz nach Auren
   - Zeichnet Zaubername, Schule, Kreatur-Entry und Zeitstempel auf (HP% nur über Server-Hooks verfügbar)

2. **Server-seitiger Sniffer** (erfordert TrinityCore C++-Hooks)
   - Vier `UnitScript`-Hooks übertragen jedes Kreatur-Zauber-Event als Addon-Nachricht
   - Erfasst 100% aller Zauber, einschließlich sofortiger/versteckter
   - Sendet nur an Spieler in der Nähe (100 Yard) mit installiertem CreatureCodex

3. **Ymir-Integration** (Live-Merge aus Paketmitschnitten)
   - Starten Sie Ymir wie gewohnt neben dem Spiel — CreatureCodex arbeitet parallel
   - Nachdem WowPacketParser Ihre `.pkt`-Dateien verarbeitet hat, konvertieren Sie die Ausgabe mit dem enthaltenen Python-Tool
   - Das Addon führt Sniff-Daten beim `/reload` automatisch zusammen — kein Verlassen des Spiels nötig
   - Fängt Sofortzauber, versteckte Zauber und getriggerte Fähigkeiten ab, die der visuelle Scanner nicht sehen kann
   - Generiert auch SQL direkt aus Sniff-Daten, wenn Sie das Addon überspringen möchten

Bei gemeinsamer Nutzung mehrerer Quellen dedupliziert das Addon automatisch — vollständige Abdeckung ohne Lücken.

## Download

Laden Sie die neueste Version von der [Releases-Seite](https://github.com/VoxCore84/CreatureCodex/releases) herunter. Laden Sie `CreatureCodex.zip` herunter und entpacken Sie es — es enthält alles: das Client-Addon, Server-Skripte, Tools und diese Dokumentation.

## Installation

<details>
<summary><strong>Nur-Client-Installation (keine Server-Patches)</strong> — zum Aufklappen klicken</summary>

Wenn Sie nur den visuellen Scanner ohne Server-Modifikation möchten:

1. Kopieren Sie den `CreatureCodex/`-Ordner (mit den .lua-Dateien) in den Addon-Ordner Ihrer WoW-Installation:
   ```
   <WoW-Verzeichnis>/Interface/AddOns/CreatureCodex/
   ```
   Beispiel: `C:\WoW\_retail_\Interface\AddOns\CreatureCodex\`. Erstellen Sie den `AddOns`-Ordner falls nötig.
2. Der Ordner sollte enthalten: `CreatureCodex.toc`, `CreatureCodex.lua`, `Export.lua`, `UI.lua`, `Minimap.lua` und den `Libs/`-Ordner.
3. Einloggen. Das Addon registriert sich automatisch über den Minimap-Button (goldenes Buch-Icon).
4. Gehen Sie in die Nähe von Kreaturen und beobachten Sie Kämpfe — Zauber werden in Echtzeit erfasst.
5. Geben Sie `/cc` im Chat ein um das Browser-Panel zu öffnen und zu bestätigen dass das Addon funktioniert.

**Was Sie bekommen**: Sichtbare Zauber und Kanalisierungen (alles, was die WoW-API erkennen kann).
**Was Sie verpassen**: Sofortzauber, versteckte Zauber und Auren ohne sichtbare Zauberleiste.

> **Tipp:** Falls das Addon nicht in Ihrer Addon-Liste erscheint, gehen Sie zu Spielmenü → Addons → aktivieren Sie oben **"Veraltete AddOns laden"**. Dies ist nötig, wenn die Client-Version neuer ist als die TOC-Interface-Version des Addons.

</details>

<details>
<summary><strong>Vollinstallation (Server + Client)</strong> — zum Aufklappen klicken</summary>

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

**`src/server/game/Scripting/ScriptMgr.h`** — Außerdem diese Deklarationen zu `class ScriptMgr` hinzufügen (eine andere Klasse in derselben Datei — suchen Sie nach `class TC_GAME_API ScriptMgr`):
```cpp
void OnCreatureSpellCast(Creature* creature, SpellInfo const* spell);
void OnCreatureSpellStart(Creature* creature, SpellInfo const* spell);
void OnCreatureChannelFinished(Creature* creature, SpellInfo const* spell);
void OnAuraApply(Unit* target, AuraApplication* aurApp);
```

### Schritt 2: Hooks in Spell.cpp und Unit.cpp einbinden

Vier einzeilige Hooks werden innerhalb bestehender `if (Creature* caster = ...)`-Blöcke in `Spell.cpp` und am Ende von `Unit::_ApplyAura()` in `Unit.cpp` eingefügt.

Den genauen Code, Variablennamen und Einfügepunkte finden Sie in **`server/HOOKS.md`**. Der Auto-Patcher (`install_hooks.py`) wendet diese automatisch an — verwenden Sie `HOOKS.md` nur, wenn Sie manuell patchen möchten.

### Schritt 3: IsAddonRegistered-Hilfsmethode hinzufügen

Der Sniffer prüft, ob ein Spieler den `CCDX`-Addon-Prefix registriert hat. Fügen Sie diese kleine Hilfsmethode zu `WorldSession` hinzu (sie liest das Member `_registeredAddonPrefixes`, das bereits in der Klasse existiert):

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

Dann `sql/auth_rbac_creature_codex.sql` auf die `auth`-Datenbank anwenden, oder manuell:
```sql
INSERT IGNORE INTO `rbac_permissions` (`id`, `name`) VALUES (3012, 'Command: codex');
-- An GM-Rolle koppeln (Rolle 193 = GM-Befehle)
INSERT IGNORE INTO `rbac_linked_permissions` (`id`, `linkedId`) VALUES (193, 3012);
```

### Schritt 5: Sniffer-Skripte kopieren

1. Kopieren Sie `server/creature_codex_sniffer.cpp` und `server/cs_creature_codex.cpp` nach `src/server/scripts/Custom/`.

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

Bei Verwendung von Eluna kopieren Sie `server/lua_scripts/creature_codex_server.lua` in Ihr Eluna-Skriptverzeichnis (Standard: `lua_scripts/` neben Ihrer worldserver-Binary). Dies fügt hinzu:
- **Zauberlisten-Abfragen**: Addon kann die vollständige Zauberliste aus `creature_template_spell` anfordern
- **Kreatur-Informationen**: Name, Fraktion, Levelbereich, Klassifizierung
- **Zonen-Vollständigkeit**: Alle Kreaturen einer Karte mit bekannten Zauberzahlen abfragen
- **Mehrspieler-Aggregation**: Spieler können Entdeckungen an eine gemeinsame Server-Tabelle senden

Für die Aggregation die Tabelle in der gewünschten Datenbank erstellen (Standard: `characters`):
```sql
CREATE TABLE IF NOT EXISTS `codex_aggregated` (
    `creature_entry` INT UNSIGNED NOT NULL,
    `spell_id` INT UNSIGNED NOT NULL,
    `cast_count` INT UNSIGNED NOT NULL DEFAULT 1,
    `last_reporter` VARCHAR(64) NOT NULL DEFAULT '',
    `last_seen` INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (`creature_entry`, `spell_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

Diese Tabelle muss in Ihrer `characters`-Datenbank existieren (dieselbe, die `CharDBExecute` verwendet).

### Schritt 7: Kompilieren und installieren

1. Kopieren Sie den `CreatureCodex/`-Ordner nach `Interface\AddOns\CreatureCodex\`.
2. Kompilieren Sie Ihren Server neu. Aus Ihrem Build-Verzeichnis:
   ```bash
   # CMake + Make (Linux)
   cmake --build . --config RelWithDebInfo -j $(nproc)

   # CMake + Ninja
   ninja -j$(nproc)

   # Visual Studio (Windows)
   # .sln öffnen und in Release oder RelWithDebInfo kompilieren
   ```

</details>

<details>
<summary><strong>Ymir-Integration (Sniff-Benutzer)</strong> — zum Aufklappen klicken</summary>

Wenn Sie mit Ymir sniffen, arbeitet CreatureCodex parallel dazu. Das Addon erfasst, was die Client-API in Echtzeit sehen kann, und das enthaltene Python-Tool füllt die Lücken — Sofortzauber, versteckte Zauber, getriggerte Fähigkeiten — aus Ihrer WowPacketParser-Ausgabe. Alles wird im Addon automatisch zusammengeführt. Sie verlassen nie das Spiel.

### Funktionsweise

1. **Normal spielen** mit Ymir im Hintergrund und installiertem CreatureCodex
2. **Das Addon erfasst Live-Daten** — sichtbare Zauber und Auren über den visuellen Scanner
3. **Pakete parsen** — WowPacketParser auf Ihre `.pkt`-Dateien ausführen (das kann passieren, während das Spiel noch offen ist)
4. **Ergebnisse ins Addon einspeisen:**
   ```bash
   python tools/wpp_import.py --addon sniff_output.txt
   ```
   Die generierte `CreatureCodexWPP.lua` nach `WTF/Account/<IHR_ACCOUNT>/SavedVariables/` kopieren
5. **`/reload` im Spiel** — das Addon führt die Sniff-Daten automatisch zusammen und meldet den Import:
   ```
   [CreatureCodex] Imported sniff data: +142 creatures, +891 spells from WPP.
   ```
6. **Durchsuchen und exportieren** mit `/cc` — Ihre Daten enthalten jetzt sowohl Scanner-Beobachtungen als auch paketbestätigte Zauber

Die Sniff-Daten füllen genau das, was der visuelle Scanner nicht sehen kann: Sofortzauber, serverseitig getriggerte Zauber und Auren, die ohne sichtbare Zauberleiste angelegt werden. Das Addon dedupliziert alles — kein Doppelzählen.

### Voraussetzungen

- Python 3.10+
- WowPacketParser `.txt`-Ausgabedateien (die menschenlesbaren Textdateien, die WPP aus `.pkt`-Mitschnitten generiert)

### Direkt-SQL (Addon überspringen)

Wenn Sie nicht im Spiel durchsuchen möchten und nur SQL aus Ihren Sniff-Daten brauchen:

```bash
# creature_template_spell SQL (Standard)
python tools/wpp_import.py sniff1.txt sniff2.txt
# → creature_template_spell.sql

# SmartAI-Stubs mit geschätzten Cooldowns
python tools/wpp_import.py --smartai sniff1.txt
# → smart_scripts.sql

# Beides auf einmal
python tools/wpp_import.py --sql --smartai sniff1.txt

# Direkt anwenden
mysql -u root -p world < creature_template_spell.sql
```

Das Skript parst SMSG_SPELL_GO, SMSG_SPELL_START und SMSG_AURA_UPDATE Opcodes. Es schätzt Cooldowns aus beobachteten Cast-Intervallen und leitet Zieltypen aus dem Cast-zu-Aura-Verhältnis ab — dieselbe Intelligenz, die das Addon nutzt.

### Ausgabeformate

| Flag | Ausgabedatei | Inhalt |
|------|-------------|--------|
| `--sql` (Standard) | `creature_template_spell.sql` | DELETE + INSERT Paare für Zauberlisten |
| `--smartai` | `smart_scripts.sql` | SmartAI-Stubs mit Cooldown-Schätzungen |
| `--addon` | `CreatureCodexWPP.lua` | Auto-Merge ins Addon bei `/reload` |
| `--lua` | `CreatureCodexDB.lua` | Vollständiger SavedVariables-Ersatz |

Mit `-o` den Ausgabedateinamen überschreiben (nur bei einzelnem Format). Flags kombinierbar: `--sql --smartai` generiert beide SQL-Dateien in einem Durchlauf.

### Tipps

- **Laufen liefert dichtere Daten als Fliegen.** Beim Sniffen zu Fuß durch Gebiete gehen für bessere Kreatur-Zauber-Abdeckung.
- **Mehrere Sniffs verschmelzen sauber.** Mehrere `.txt`-Dateien übergeben, um Daten aus verschiedenen Sitzungen zu kombinieren.
- **Scanner + Sniff = vollständiges Bild.** Der visuelle Scanner liefert Zaubernamen und Echtzeit-Browsing; die Sniff-Daten liefern Zauber-IDs und volle Abdeckung. Zusammen besser als jedes einzeln.

</details>

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
| `/cc sync` | UI neu laden um WPP-Sniff-Daten zu importieren (zuerst `wpp_import.py --addon` ausführen) |
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

1. **Raw** — Maschinenlesbares Format: `entry:name|spellId:total:school:spellName|...` (eine Kreatur pro Zeile, mit `CCEXPORT:v3` Präfix)
2. **SQL** — Fertige `INSERT INTO creature_template_spell`-Anweisungen
3. **SmartAI** — `INSERT INTO smart_scripts` für AI-gesteuerte Zauber
4. **New Only** — Wie SQL, aber nur Zauber die noch nicht in `creature_template_spell` sind

### Exportiertes SQL anwenden

Nach dem Export aus dem Addon haben Sie SQL-Text, der gegen Ihre `world`-Datenbank ausgeführt werden kann. Drei gängige Wege:

- **HeidiSQL** (Windows): Mit der DB verbinden, `world`-Datenbank auswählen, neuen Query-Tab öffnen, SQL einfügen und Execute (F9) drücken.
- **phpMyAdmin** (Web): `world`-Datenbank auswählen, SQL-Tab öffnen, einfügen und Go klicken.
- **MySQL CLI**:
  ```bash
  mysql -u root -p world < exported_spells.sql
  ```
  Oder direkt in eine interaktive `mysql`-Sitzung einfügen nach `USE world;`.

Die SQL- und SmartAI-Exporte enthalten `DELETE` + `INSERT`-Paare und sind daher sicher wiederholbar — keine Duplikate.

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
| S->C | `AR` | `AR\|entry\|OK` | Aggregations-Bestätigung |

## Dateistruktur

```
CreatureCodex/
  CreatureCodex/                          -- ADDON-ORDNER (nach Interface/AddOns/CreatureCodex/ kopieren)
    CreatureCodex.toc
    CreatureCodex.lua                     -- Kern-Engine (Erfassung + DB)
    Export.lua                            -- 4-Tab-Export
    UI.lua                                -- Browser-Panel
    Minimap.lua                           -- Minimap-Button
    Libs/                                 -- LibStub, CallbackHandler, LibDataBroker, LibDBIcon
  server/
    creature_codex_sniffer.cpp            -- C++ UnitScript-Hooks (Broadcast-Schicht)
    cs_creature_codex.cpp                 -- .codex GM-Befehlsbaum
    install_hooks.py                      -- Auto-Patcher für TC-Source-Hooks
    HOOKS.md                              -- Manuelle Patching-Referenz
    lua_scripts/
      creature_codex_server.lua           -- Eluna-Handler
  tools/
    wpp_import.py                         -- WPP → SQL / Addon-Import-Tool
    wpp_watcher.py                        -- Hintergrund-Companion für Auto-Import
    _README.txt                           -- Übersicht Tools-Ordner
    parsed/
      _What_To_Do_With_These_Files.txt    -- Anleitung für geparste Dateien
  _GUIDE/
    01_Quick_Start.md                     -- In 2 Minuten loslegen
    02_Server_Setup.md                    -- Server-Hooks + C++-Setup
    03_Retail_Sniffing.md                 -- Ymir + WPP Pipeline
    04_Understanding_Exports.md           -- Export-Formate erklärt
  session.py                              -- Session-Manager (Ymir + SV-Backup)
  update_tools.py                         -- Tool-Downloader (erfordert gh CLI)
  Start Ymir.bat                          -- Ymir + Session-Manager starten (Windows)
  Update Tools.bat                        -- WPP und Ymir herunterladen/aktualisieren (Windows)
  Parse Captures.bat                      -- WPP auf vorhandene .pkt-Dateien ausführen (Windows)
  start_ymir.sh                           -- Ymir + Session-Manager starten (Linux/macOS)
  update_tools.sh                         -- WPP und Ymir herunterladen/aktualisieren (Linux/macOS)
  parse_captures.sh                       -- WPP auf vorhandene .pkt-Dateien ausführen (Linux/macOS)
  README.md                               -- Englische Version
  README_RU.md                            -- Russische Version
  README_DE.md                            -- Diese Datei
  LICENSE                                 -- MIT
```

## Lizenz

MIT. Bibliotheken in `Libs/` behalten ihre ursprünglichen Lizenzen.
