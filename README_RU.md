# CreatureCodex v1.0.0

[![GitHub](https://img.shields.io/github/v/release/VoxCore84/CreatureCodex?label=v1.0.0)](https://github.com/VoxCore84/CreatureCodex/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Ваши NPC не сражаются. Они стоят и бьют автоатакой, потому что `creature_template_spell` (таблица базы данных, назначающая заклинания существам) пуст и нет SmartAI (система скриптового поведения TrinityCore), который бы говорил им что кастовать. CreatureCodex решает эту проблему.

**Репозиторий:** [github.com/VoxCore84/CreatureCodex](https://github.com/VoxCore84/CreatureCodex)

## Что он делает

1. **Установите аддон** на любой сервер TrinityCore — включая репаки, без патчей сервера
2. **Гуляйте рядом с существами** — аддон захватывает видимые касты, каналирования и ауры в реальном времени (серверные хуки добавляют мгновенные/скрытые заклинания для 100% покрытия)
3. **Откройте панель экспорта**, вкладка **SmartAI** — готовый SQL с рассчитанными кулдаунами, фазами по HP и типами целей
4. **Примените SQL** — ваши NPC теперь кастуют заклинания с правильным таймингом и поведением

CreatureCodex превращает наблюдение в рабочий SmartAI. Вы наблюдаете за мобами, а он пишет `smart_scripts` и `creature_template_spell` за вас.

### Полный пайплайн

```
                    ┌─ Визуальный сканер (клиентский аддон, работает везде)
Подойти к мобам ────┼─ Серверные хуки (C++ UnitScript, 100% покрытие)
                    └─ Интеграция с Ymir (авто-слияние из дампов пакетов)
                                          │
                                          ▼
                              Просмотр в игре → Экспорт в SQL
                                                  ├── creature_template_spell (списки заклинаний)
                                                  ├── smart_scripts (AI с кулдаунами)
                                                  └── new-only (только пробелы)
```

Экспорт SmartAI — это не просто список ID заклинаний. Он использует тайминг-аналитику аддона для оценки кулдаунов по наблюдённым интервалам кастов, определяет фазовые способности по HP (заклинания, замеченные хотя бы раз ниже 40% HP, получают `event_type=2` вместо повторов по таймеру), и определяет типы целей по соотношению кастов к аурам. Это черновик, который можно доработать, а не чистый лист.

## Почему это сложно без него

Эти данные не поставляются в DB2-файлах. Их нужно наблюдать на живом сервере. В 12.x это стало значительно сложнее:

- **`COMBAT_LOG_EVENT_UNFILTERED` фактически мёртв.** Боевой лог был золотым стандартом для захвата кастов. В 12.x отслеживание GUID через аддоны сильно ограничено. Пассивное прослушивание CLEU больше не даёт надёжных данных.

- **Taint и секретные значения.** Движок 12.x внедряет непрозрачные C++ `userdata`-заражения в ID заклинаний, GUID и данные аур. Стандартные Lua `tonumber()`/`tostring()` молча ломаются на заражённых значениях. Любой аддон должен оборачивать каждый доступ в `pcall` с проверкой `issecretvalue()`.

- **Мгновенные касты невидимы.** `UnitCastingInfo`/`UnitChannelInfo` видят только заклинания с полосой каста. Инстанты, триггерные заклинания и многие механики боссов невидимы — значительная часть списка заклинаний существа ненаблюдаема с клиента.

- **Традиционный сниффинг требует постобработки.** Пайплайн Ymir → WowPacketParser даёт лучшие данные, но превращение сырых дампов пакетов в готовые списки заклинаний всегда означало оффлайн-парсинг, ручной просмотр и написание SQL вручную.

**CreatureCodex обходит всё это.** Клиентский сканер опрашивает касты на 10 Гц и сканирует ауры на 5 Гц с taint-безопасными обёртками. Работает на любом сервере — репаки, кастомные сборки, всё что запускает клиент 12.x.

Для серверов с возможностью добавить C++ хуки, четыре коллбэка `UnitScript` перехватывают 100% кастов включая мгновенные и скрытые. Оба уровня автоматически дедуплицируются — ноль пробелов, ноль шума.

А если вы сниффите через Ymir, CreatureCodex интегрируется напрямую — запустите включённый инструмент на вывод WPP, `/reload`, и аддон автоматически объединит данные сниффа с данными сканера. Или пропустите аддон и сгенерируйте SQL прямо из ваших дампов пакетов.

## Как это работает

CreatureCodex имеет три источника данных:

1. **Клиентский визуальный сканер** (работает везде, без патчей сервера)
   - Опрашивает `UnitCastingInfo`/`UnitChannelInfo` с частотой 10 Гц
   - Сканирует неймплейты на наличие аур с частотой 5 Гц
   - Записывает название заклинания, школу, entry существа и метки времени (% HP доступен только через серверные хуки)

2. **Серверный сниффер** (требует хуки C++ в TrinityCore)
   - Четыре хука `UnitScript` транслируют каждое событие заклинания как аддон-сообщение
   - Перехватывает 100% кастов, включая мгновенные/скрытые
   - Транслирует только ближайшим игрокам (100 ярдов) с установленным аддоном

3. **Интеграция с Ymir** (слияние из дампов пакетов в реальном времени)
   - Запускайте Ymir параллельно с игрой как обычно — CreatureCodex работает одновременно
   - После обработки `.pkt` файлов WowPacketParser запустите включённый Python-инструмент для конвертации
   - Аддон автоматически объединяет данные сниффа по `/reload` — не нужно выходить из игры
   - Ловит мгновенные касты, скрытые заклинания и триггерные способности, которые визуальный сканер не видит
   - Также генерирует SQL напрямую из данных сниффа, если предпочитаете обойтись без аддона

При совместной работе нескольких источников аддон автоматически удаляет дубликаты — полное покрытие без пробелов.

## Скачать

Загрузите последний релиз со [страницы релизов](https://github.com/VoxCore84/CreatureCodex/releases). Скачайте `CreatureCodex.zip` и распакуйте — в архиве всё: клиентский аддон, серверные скрипты, инструменты и документация.

## Установка

<details>
<summary><strong>Установка только клиента (без патчей сервера)</strong> — нажмите для раскрытия</summary>

Если вам нужен только визуальный сканер без модификации сервера:

1. Скопируйте папку `CreatureCodex/` (с .lua файлами) в папку аддонов вашей установки WoW:
   ```
   <Папка WoW>/Interface/AddOns/CreatureCodex/
   ```
   Например: `C:\WoW\_retail_\Interface\AddOns\CreatureCodex\`. Создайте папку `AddOns` если её нет.
2. Папка должна содержать: `CreatureCodex.toc`, `CreatureCodex.lua`, `Export.lua`, `UI.lua`, `Minimap.lua` и папку `Libs/`.
3. Войдите в игру. Аддон регистрируется автоматически через кнопку на миникарте (золотая иконка книги).
4. Подойдите к существам и наблюдайте за боем — заклинания записываются в реальном времени.
5. Введите `/cc` в чат чтобы открыть панель просмотра и убедиться что аддон работает.

**Что вы получите**: Видимые касты и каналирования (всё, что может обнаружить WoW API).
**Что вы пропустите**: Мгновенные касты, скрытые заклинания и ауры без видимой полосы каста.

> **Совет:** Если аддон не отображается в списке аддонов, откройте Меню игры → Аддоны → включите **«Загружать устаревшие аддоны»** вверху. Это нужно, когда версия клиента новее, чем Interface-версия в TOC-файле аддона.

</details>

<details>
<summary><strong>Полная установка (Сервер + Клиент)</strong> — нажмите для раскрытия</summary>

### Требования

- TrinityCore ветка `master` (12.x / The War Within)
- Компилятор C++20 (MSVC 2022+, GCC 13+, Clang 16+)
- Eluna Lua Engine (опционально, для запросов списков заклинаний и агрегации)

### Шаг 1: Добавить хуки в ScriptMgr

Четыре виртуальных метода необходимо добавить в `UnitScript` в вашем ScriptMgr.

**`src/server/game/Scripting/ScriptMgr.h`** — Добавить в `class UnitScript`:
```cpp
// Хуки CreatureCodex
virtual void OnCreatureSpellCast(Creature* /*creature*/, SpellInfo const* /*spell*/) {}
virtual void OnCreatureSpellStart(Creature* /*creature*/, SpellInfo const* /*spell*/) {}
virtual void OnCreatureChannelFinished(Creature* /*creature*/, SpellInfo const* /*spell*/) {}
virtual void OnAuraApply(Unit* /*target*/, AuraApplication* /*aurApp*/) {}
```

**`src/server/game/Scripting/ScriptMgr.cpp`** — Добавить диспетчеры FOREACH_SCRIPT:
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

**`src/server/game/Scripting/ScriptMgr.h`** — Также добавьте эти объявления в `class ScriptMgr` (другой класс в том же файле — ищите `class TC_GAME_API ScriptMgr`):
```cpp
void OnCreatureSpellCast(Creature* creature, SpellInfo const* spell);
void OnCreatureSpellStart(Creature* creature, SpellInfo const* spell);
void OnCreatureChannelFinished(Creature* creature, SpellInfo const* spell);
void OnAuraApply(Unit* target, AuraApplication* aurApp);
```

### Шаг 2: Подключить хуки в Spell.cpp и Unit.cpp

Четыре однострочных хука добавляются внутри существующих блоков `if (Creature* caster = ...)` в `Spell.cpp` и в конце `Unit::_ApplyAura()` в `Unit.cpp`.

Точный код, имена переменных и точки вставки см. в **`server/HOOKS.md`**. Авто-патчер (`install_hooks.py`) применяет их автоматически — используйте `HOOKS.md` только если предпочитаете ручной патчинг.

### Шаг 3: Добавить вспомогательный метод IsAddonRegistered

Сниффер проверяет, зарегистрирован ли у игрока префикс аддона `CCDX`. Добавьте этот небольшой метод в `WorldSession` (он читает член `_registeredAddonPrefixes`, который уже существует в классе):

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

### Шаг 4: Добавить разрешение RBAC

**`src/server/game/Accounts/RBAC.h`** — Добавить в enum разрешений:
```cpp
RBAC_PERM_COMMAND_CREATURE_CODEX = 3012,
```

Затем применить `sql/auth_rbac_creature_codex.sql` к базе данных `auth`, или вручную:
```sql
INSERT IGNORE INTO `rbac_permissions` (`id`, `name`) VALUES (3012, 'Command: codex');
-- Привязать к роли GM (роль 193 = GM-команды)
INSERT IGNORE INTO `rbac_linked_permissions` (`id`, `linkedId`) VALUES (193, 3012);
```

### Шаг 5: Скопировать скрипты сниффера

1. Скопируйте `server/creature_codex_sniffer.cpp` и `server/cs_creature_codex.cpp` в `src/server/scripts/Custom/`.

2. Зарегистрируйте их в `custom_script_loader.cpp`:
   ```cpp
   void AddSC_creature_codex_sniffer();
   void AddSC_creature_codex_commands();

   void AddCustomScripts()
   {
       // ... ваши существующие скрипты ...
       AddSC_creature_codex_sniffer();
       AddSC_creature_codex_commands();
   }
   ```

### Шаг 6: (Опционально) Серверные скрипты Eluna

При использовании Eluna, скопируйте `server/lua_scripts/creature_codex_server.lua` в директорию скриптов Eluna (по умолчанию: `lua_scripts/` рядом с бинарником worldserver). Это добавит:
- **Запросы списков заклинаний**: Аддон может запросить полный список заклинаний из `creature_template_spell`
- **Информация о существе**: Имя, фракция, диапазон уровней, классификация
- **Полнота по зоне**: Запрос всех существ на карте с количеством известных заклинаний
- **Многопользовательская агрегация**: Игроки могут отправлять открытия в общую серверную таблицу

Для агрегации создайте таблицу в базе данных (по умолчанию: `characters`):
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

Эта таблица должна существовать в вашей базе данных `characters` (той же, которую использует `CharDBExecute`).

### Шаг 7: Сборка и установка

1. Скопируйте папку `CreatureCodex/` в `Interface\AddOns\CreatureCodex\`.
2. Пересоберите сервер. Из директории сборки:
   ```bash
   # CMake + Make (Linux)
   cmake --build . --config RelWithDebInfo -j $(nproc)

   # CMake + Ninja
   ninja -j$(nproc)

   # Visual Studio (Windows)
   # Откройте .sln и соберите в Release или RelWithDebInfo
   ```

</details>

<details>
<summary><strong>Интеграция с Ymir (пользователи сниффов)</strong> — нажмите для раскрытия</summary>

Если вы сниффите через Ymir, CreatureCodex работает параллельно. Аддон захватывает всё, что видит клиентский API, в реальном времени, а включённый Python-инструмент заполняет пробелы — мгновенные касты, скрытые заклинания, триггерные способности — из вывода WowPacketParser. Всё автоматически объединяется внутри аддона. Вы не покидаете игру.

### Как это работает

1. **Играйте как обычно** с Ymir в фоне и установленным CreatureCodex
2. **Аддон захватывает данные в реальном времени** — видимые касты и ауры через визуальный сканер
3. **Обработайте пакеты** — запустите WowPacketParser на ваших `.pkt` файлах (можно прямо при открытой игре)
4. **Подайте результаты в аддон:**
   ```bash
   python tools/wpp_import.py --addon sniff_output.txt
   ```
   Скопируйте сгенерированный `CreatureCodexWPP.lua` в `WTF/Account/<ВАШ_АККАУНТ>/SavedVariables/`
5. **`/reload` в игре** — аддон автоматически объединит данные сниффа и покажет что импортировал:
   ```
   [CreatureCodex] Imported sniff data: +142 creatures, +891 spells from WPP.
   ```
6. **Просматривайте и экспортируйте** через `/cc` — ваши данные теперь включают и наблюдения сканера, и подтверждённые пакетами заклинания

Данные сниффа заполняют именно то, что визуальный сканер не видит: мгновенные касты, серверные триггерные заклинания и ауры, наложенные без видимой полосы каста. Аддон дедуплицирует всё — двойного учёта не будет.

### Требования

- Python 3.10+
- `.txt` файлы вывода WowPacketParser (человекочитаемый текст, который WPP генерирует из `.pkt` дампов)

### Прямой SQL (без аддона)

Если вам не нужен просмотр в игре и вы хотите просто SQL из данных сниффа:

```bash
# SQL для creature_template_spell (по умолчанию)
python tools/wpp_import.py sniff1.txt sniff2.txt
# → creature_template_spell.sql

# Заготовки SmartAI с рассчитанными кулдаунами
python tools/wpp_import.py --smartai sniff1.txt
# → smart_scripts.sql

# Оба сразу
python tools/wpp_import.py --sql --smartai sniff1.txt

# Применить напрямую
mysql -u root -p world < creature_template_spell.sql
```

Скрипт парсит опкоды SMSG_SPELL_GO, SMSG_SPELL_START и SMSG_AURA_UPDATE. Он оценивает кулдауны по наблюдённым интервалам кастов и определяет типы целей по соотношению кастов к аурам — та же аналитика, что использует аддон.

### Форматы вывода

| Флаг | Файл | Содержимое |
|------|------|------------|
| `--sql` (по умолчанию) | `creature_template_spell.sql` | Пары DELETE + INSERT для списков заклинаний |
| `--smartai` | `smart_scripts.sql` | Заготовки SmartAI с оценками кулдаунов |
| `--addon` | `CreatureCodexWPP.lua` | Авто-слияние в аддон по `/reload` |
| `--lua` | `CreatureCodexDB.lua` | Полная замена SavedVariables |

Используйте `-o` для переопределения имени выходного файла (только один формат). Флаги комбинируются: `--sql --smartai` генерирует оба SQL-файла за один проход.

### Советы

- **Ходьба даёт более плотные данные, чем полёт.** При сниффинге ходите по зонам пешком для лучшего покрытия заклинаний существ.
- **Несколько сниффов объединяются чисто.** Передайте несколько `.txt` файлов для объединения данных из разных сессий.
- **Сканер + снифф = полная картина.** Визуальный сканер даёт названия заклинаний и просмотр в реальном времени; данные сниффа дают ID заклинаний и полное покрытие. Вместе они лучше, чем по отдельности.

</details>

## Использование

### Слеш-команды

| Команда | Описание |
|---------|----------|
| `/cc` или `/codex` | Открыть/закрыть панель просмотра |
| `/cc export` | Открыть панель экспорта |
| `/cc debug` | Включить/выключить отладочный вывод в чат |
| `/cc stats` | Вывести статистику захвата |
| `/cc zone` | Запросить данные о существах зоны с сервера (требуется Eluna) |
| `/cc submit` | Отправить агрегированные данные на сервер (требуется Eluna) |
| `/cc sync` | Перезагрузить UI для импорта данных WPP-снифа (сначала запустите `wpp_import.py --addon`) |
| `/cc reset` | Очистить все сохранённые данные (с подтверждением) |

### GM-команды (требуется RBAC 3012)

| Команда | Описание |
|---------|----------|
| `.codex query <entry>` | Показать все заклинания для entry существа |
| `.codex stats` | Статистика сниффера (онлайн, пользователи аддона, чёрный список) |
| `.codex blacklist add <spellId>` | Добавить заклинание в чёрный список трансляции |
| `.codex blacklist remove <spellId>` | Удалить заклинание из чёрного списка |
| `.codex blacklist list` | Показать все заклинания в чёрном списке |

### Форматы экспорта

Панель экспорта предлагает четыре вкладки:

1. **Raw** — Машиночитаемый формат: `entry:имя|spellId:всего:школа:имяЗаклинания|...` (одно существо на строку, с префиксом `CCEXPORT:v3`)
2. **SQL** — Готовые `INSERT INTO creature_template_spell`
3. **SmartAI** — `INSERT INTO smart_scripts` для AI-кастов
4. **New Only** — Как SQL, но только заклинания отсутствующие в `creature_template_spell`

### Применение экспортированного SQL

После экспорта из аддона у вас есть SQL-текст, готовый к выполнению в базе данных `world`. Три распространённых способа:

- **HeidiSQL** (Windows): Подключитесь к БД, выберите базу `world`, откройте новую вкладку запросов, вставьте SQL и нажмите Execute (F9).
- **phpMyAdmin** (веб): Выберите базу `world`, перейдите на вкладку SQL, вставьте и нажмите Go.
- **MySQL CLI**:
  ```bash
  mysql -u root -p world < exported_spells.sql
  ```
  Или вставьте напрямую в интерактивную сессию `mysql` после команды `USE world;`.

Экспорт SQL и SmartAI содержит пары `DELETE` + `INSERT`, поэтому безопасен для повторного применения — дубликатов не будет.

### Кнопка на миникарте

ЛКМ открывает браузер. ПКМ открывает экспорт. Кнопку можно перетащить.

## Справочник протокола

Аддон и сервер общаются через префикс `CCDX`, сообщения разделены символом `|`:

| Направление | Код | Формат | Назначение |
|-------------|-----|--------|------------|
| S->C | `SC` | `SC\|entry\|spellID\|school\|name\|hp%` | Заклинание произнесено |
| S->C | `SS` | `SS\|entry\|spellID\|school\|name\|hp%` | Начало произнесения |
| S->C | `CF` | `CF\|entry\|spellID\|school\|name\|hp%` | Каналирование завершено |
| S->C | `AA` | `AA\|entry\|spellID\|school\|name\|hp%` | Аура наложена |
| C->S | `SL` | `SL\|entry` | Запрос списка заклинаний |
| C->S | `CI` | `CI\|entry` | Запрос информации о существе |
| C->S | `ZC` | `ZC\|mapId` | Запрос существ зоны |
| C->S | `AG` | `AG\|entry\|spellId:count,...` | Отправка агрегированных данных |
| S->C | `AR` | `AR\|entry\|OK` | Подтверждение агрегации |

## Структура файлов

```
CreatureCodex/
  CreatureCodex/                          -- ПАПКА АДДОНА (копировать в Interface/AddOns/CreatureCodex/)
    CreatureCodex.toc
    CreatureCodex.lua                     -- Ядро (захват + БД)
    Export.lua                            -- 4-вкладочный экспорт
    UI.lua                                -- Панель просмотра
    Minimap.lua                           -- Кнопка на миникарте
    Libs/                                 -- LibStub, CallbackHandler, LibDataBroker, LibDBIcon
  server/
    creature_codex_sniffer.cpp            -- C++ хуки UnitScript (слой трансляции)
    cs_creature_codex.cpp                 -- GM-команда .codex
    install_hooks.py                      -- Авто-патчер хуков TC
    HOOKS.md                              -- Справочник ручного патчинга
    lua_scripts/
      creature_codex_server.lua           -- Обработчики Eluna
  tools/
    wpp_import.py                         -- WPP → SQL / инструмент импорта в аддон
    wpp_watcher.py                        -- Фоновый компаньон для авто-импорта
    _README.txt                           -- Описание папки tools
    parsed/
      _What_To_Do_With_These_Files.txt    -- Руководство по распознанным файлам
  _GUIDE/
    01_Quick_Start.md                     -- Быстрый старт
    02_Server_Setup.md                    -- Серверные хуки + настройка C++
    03_Retail_Sniffing.md                 -- Пайплайн Ymir + WPP
    04_Understanding_Exports.md           -- Форматы экспорта
  session.py                              -- Менеджер сессий (Ymir + резервное копирование SV)
  update_tools.py                         -- Загрузчик инструментов (требуется gh CLI)
  Start Ymir.bat                          -- Запуск Ymir + менеджер сессий (Windows)
  Update Tools.bat                        -- Загрузка/обновление WPP и Ymir (Windows)
  Parse Captures.bat                      -- Запуск WPP на имеющихся .pkt файлах (Windows)
  start_ymir.sh                           -- Запуск Ymir + менеджер сессий (Linux/macOS)
  update_tools.sh                         -- Загрузка/обновление WPP и Ymir (Linux/macOS)
  parse_captures.sh                       -- Запуск WPP на имеющихся .pkt файлах (Linux/macOS)
  README.md                               -- Английская версия
  README_RU.md                            -- Этот файл
  README_DE.md                            -- Немецкая версия
  LICENSE                                 -- MIT
```

## Лицензия

MIT. Библиотеки в `Libs/` сохраняют свои оригинальные лицензии.
