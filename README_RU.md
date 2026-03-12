# CreatureCodex

[![GitHub](https://img.shields.io/github/v/release/VoxCore84/CreatureCodex?label=latest)](https://github.com/VoxCore84/CreatureCodex/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Ваши NPC не сражаются. Они стоят и бьют автоатакой, потому что `creature_template_spell` пуст и нет SmartAI, который бы говорил им что кастовать. CreatureCodex решает эту проблему.

**Репозиторий:** [github.com/VoxCore84/CreatureCodex](https://github.com/VoxCore84/CreatureCodex)

## Что он делает

1. **Установите аддон** на любой сервер TrinityCore — включая репаки, без патчей сервера
2. **Гуляйте рядом с существами** — аддон захватывает каждый каст, каналирование и ауру в реальном времени
3. **Откройте панель экспорта**, вкладка **SmartAI** — готовый SQL с рассчитанными кулдаунами, фазами по HP и типами целей
4. **Примените SQL** — ваши NPC теперь кастуют заклинания с правильным таймингом и поведением

CreatureCodex превращает наблюдение в рабочий SmartAI. Вы наблюдаете за мобами, а он пишет `smart_scripts` и `creature_template_spell` за вас.

### Полный пайплайн

```
Подойти к мобам → Аддон захватывает касты → Просмотр в игре → Экспорт в SQL
                                                                ├── creature_template_spell (списки заклинаний)
                                                                ├── smart_scripts (AI с кулдаунами)
                                                                └── new-only (только пробелы)
```

Экспорт SmartAI — это не просто список ID заклинаний. Он использует тайминг-аналитику аддона для оценки кулдаунов по наблюдённым интервалам кастов, определяет фазовые способности по HP (заклинания, замеченные только ниже 40% HP, получают `event_type=2` вместо повторов по таймеру), и определяет типы целей по соотношению кастов к аурам. Это черновик, который можно доработать, а не чистый лист.

## Почему это сложно без него

Эти данные не поставляются в DB2-файлах. Их нужно наблюдать на живом сервере. В 12.x это стало значительно сложнее:

- **`COMBAT_LOG_EVENT_UNFILTERED` фактически мёртв.** Боевой лог был золотым стандартом для захвата кастов. В 12.x отслеживание GUID через аддоны сильно ограничено. Пассивное прослушивание CLEU больше не даёт надёжных данных.

- **Taint и секретные значения.** Движок 12.x внедряет непрозрачные C++ `userdata`-заражения в ID заклинаний, GUID и данные аур. Стандартные Lua `tonumber()`/`tostring()` молча ломаются на заражённых значениях. Любой аддон должен оборачивать каждый доступ в `pcall` с проверкой `issecretvalue()`.

- **Мгновенные касты невидимы.** `UnitCastingInfo`/`UnitChannelInfo` видят только заклинания с полосой каста. Инстанты, триггерные заклинания и многие механики боссов невидимы — значительная часть списка заклинаний существа ненаблюдаема с клиента.

- **Традиционный сниффинг дорогой.** Пайплайн Ymir → WowPacketParser работает, но требует специальных инструментов, очистки кэша, определённых паттернов движения (пешком = плотные данные, полёт = разреженные) и значительной постобработки.

**CreatureCodex обходит всё это.** Клиентский сканер опрашивает касты на 10 Гц и сканирует ауры на 5 Гц с taint-безопасными обёртками. Работает на любом сервере — репаки, кастомные сборки, всё что запускает клиент 12.x.

Для серверов с возможностью добавить C++ хуки, четыре коллбэка `UnitScript` перехватывают 100% кастов включая мгновенные и скрытые. Оба уровня автоматически дедуплицируются — ноль пробелов, ноль шума.

## Как это работает

CreatureCodex имеет два уровня:

1. **Клиентский визуальный сканер** (работает везде, без патчей сервера)
   - Опрашивает `UnitCastingInfo`/`UnitChannelInfo` с частотой 10 Гц
   - Сканирует неймплейты на наличие аур с частотой 5 Гц
   - Записывает название заклинания, школу, entry существа, % HP и метки времени

2. **Серверный сниффер** (требует хуки C++ в TrinityCore)
   - Четыре хука `UnitScript` транслируют каждое событие заклинания как аддон-сообщение
   - Перехватывает 100% кастов, включая мгновенные/скрытые
   - Транслирует только ближайшим игрокам (100 ярдов) с установленным аддоном

При совместной работе обоих уровней аддон автоматически удаляет дубликаты — полное покрытие без пробелов.

## Установка только клиента (без патчей сервера)

Если вам нужен только визуальный сканер без модификации сервера:

1. Скопируйте содержимое папки `client/` в:
   ```
   Interface\AddOns\CreatureCodex\
   ```
2. Папка должна содержать: `CreatureCodex.toc`, `CreatureCodex.lua`, `Export.lua`, `UI.lua`, `Minimap.lua` и папку `Libs/`.
3. Войдите в игру. Аддон регистрируется автоматически через Addon Compartment и кнопку на миникарте.
4. Подойдите к существам и наблюдайте за боем — заклинания записываются в реальном времени.

**Что вы получите**: Видимые касты и каналирования (всё, что может обнаружить WoW API).
**Что вы пропустите**: Мгновенные касты, скрытые заклинания и ауры без видимой полосы каста.

## Полная установка (Сервер + Клиент)

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

Также добавьте объявления в класс `ScriptMgr` в заголовочном файле:
```cpp
void OnCreatureSpellCast(Creature* creature, SpellInfo const* spell);
void OnCreatureSpellStart(Creature* creature, SpellInfo const* spell);
void OnCreatureChannelFinished(Creature* creature, SpellInfo const* spell);
void OnAuraApply(Unit* target, AuraApplication* aurApp);
```

### Шаг 2: Подключить хуки в Spell.cpp и Unit.cpp

**`src/server/game/Spells/Spell.cpp`** — В `Spell::SendSpellGo()` (после отправки пакета):
```cpp
if (Creature* creature = m_caster->ToCreature())
    sScriptMgr->OnCreatureSpellCast(creature, m_spellInfo);
```

**`src/server/game/Spells/Spell.cpp`** — В начале `Spell::cast()` (после начальных проверок):
```cpp
if (Creature* creature = m_caster->ToCreature())
    sScriptMgr->OnCreatureSpellStart(creature, m_spellInfo);
```

**`src/server/game/Spells/Spell.cpp`** — В `Spell::SendChannelUpdate()` когда `time == 0`:
```cpp
if (Creature* creature = m_caster->ToCreature())
    sScriptMgr->OnCreatureChannelFinished(creature, m_spellInfo);
```

**`src/server/game/Entities/Unit/Unit.cpp`** — В `Unit::_ApplyAura()` (после успешного наложения ауры):
```cpp
sScriptMgr->OnAuraApply(this, aurApp);
```

### Шаг 3: Добавить вспомогательный метод IsAddonRegistered

Сниффер проверяет, зарегистрирован ли у игрока префикс аддона `CCDX`. Добавьте в `WorldSession`:

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

Затем применить SQL:
```
mysql -u root -p auth < sql/auth_rbac_creature_codex.sql
```

### Шаг 5: Скопировать скрипты сниффера

1. Скопируйте `server/Custom/creature_codex_sniffer.cpp` и `server/Custom/cs_creature_codex.cpp` в `src/server/scripts/Custom/`.

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

При использовании Eluna, скопируйте `server/lua_scripts/creature_codex_server.lua` в директорию скриптов Eluna. Это добавит:
- **Запросы списков заклинаний**: Аддон может запросить полный список заклинаний из `creature_template_spell`
- **Информация о существе**: Имя, фракция, диапазон уровней, классификация
- **Полнота по зоне**: Запрос всех существ на карте с количеством известных заклинаний
- **Многопользовательская агрегация**: Игроки могут отправлять открытия в общую серверную таблицу

Для агрегации примените SQL:
```
mysql -u root -p roleplay < sql/roleplay_codex_aggregated.sql
```

### Шаг 7: Установить клиентский аддон

Скопируйте содержимое `client/` в `Interface\AddOns\CreatureCodex\` и пересоберите сервер.

## Использование

### Слеш-команды

| Команда | Описание |
|---------|----------|
| `/cc` или `/codex` | Открыть/закрыть панель просмотра |
| `/cc export` | Открыть панель экспорта |
| `/cc wipe` | Очистить все сохранённые данные |
| `/cc search <имя>` | Поиск существ по имени |
| `/cc zone` | Показать существ только текущей зоны |
| `/cc stats` | Вывести статистику захвата |

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

1. **Raw** — Текст: `ИмяСущества (entry) - ИмяЗаклинания [spellId] x количество`
2. **SQL** — Готовые `INSERT INTO creature_template_spell`
3. **SmartAI** — `INSERT INTO smart_scripts` для AI-кастов
4. **New Only** — Как SQL, но только заклинания отсутствующие в `creature_template_spell`

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

## Структура файлов

```
CreatureCodex/
  client/                          -- Клиентский аддон
    CreatureCodex.toc
    CreatureCodex.lua              -- Ядро (захват + БД)
    Export.lua                     -- 4-вкладочный экспорт
    UI.lua                        -- Панель просмотра
    Minimap.lua                   -- Кнопка на миникарте
    Libs/                         -- LibStub, CallbackHandler, LibDataBroker, LibDBIcon
  server/
    Custom/
      creature_codex_sniffer.cpp  -- C++ хуки UnitScript
      cs_creature_codex.cpp       -- GM-команда .codex
    lua_scripts/
      creature_codex_server.lua   -- Обработчики Eluna
  sql/
    auth_rbac_creature_codex.sql  -- RBAC разрешение для .codex
    roleplay_codex_aggregated.sql -- Таблица многопользовательской агрегации
  README.md                       -- Английская версия
  README_RU.md                    -- Этот файл
  README_DE.md                    -- Немецкая версия
```

## Лицензия

MIT. Библиотеки в `Libs/` сохраняют свои оригинальные лицензии.
