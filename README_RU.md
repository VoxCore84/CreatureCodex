# CreatureCodex

Серверный сниффер заклинаний и аур существ для эмуляторов WoW на базе TrinityCore.

CreatureCodex перехватывает каждое произнесение заклинания, каналирование и наложение ауры существами — включая мгновенные/скрытые касты, которые клиентский API не видит — и сохраняет их в базу данных с возможностью просмотра и экспорта в SQL для `creature_template_spell` или SmartAI.

## Зачем это нужно

Эмуляторам TrinityCore необходимы полные данные о заклинаниях существ в таблице `creature_template_spell`, чтобы NPC могли нормально сражаться. Без этих данных мобы просто стоят и бьют автоатакой. Эта информация не поставляется в файлах DB2 — её нужно наблюдать на живом ритейл-сервере, либо через перехват пакетов, либо через аддоны.

**Клиент 12.x Midnight сделал это значительно сложнее:**

- **`COMBAT_LOG_EVENT_UNFILTERED` фактически мёртв.** Боевой лог раньше был золотым стандартом для захвата кастов существ. В 12.x межаддонная коммуникация и отслеживание GUID сильно ограничены. Пассивное прослушивание CLEU больше не даёт надёжных данных о заклинаниях существ.

- **Taint и секретные значения.** Движок 12.x активно внедряет непрозрачные C++ `userdata`-заражения в базовые переменные UI — ID заклинаний, GUID, данные аур. Функция `issecretvalue()` контролирует доступ к этим значениям, а стандартные Lua `tonumber()`/`tostring()` молча ломаются на заражённых данных. Любой аддон, работающий с данными заклинаний или юнитов, должен оборачивать каждый доступ в `pcall` с явной проверкой секретных значений — иначе он сломается без предупреждения.

- **Мгновенные и скрытые касты невидимы.** `UnitCastingInfo` и `UnitChannelInfo` видят только заклинания с видимой полосой каста. Мгновенные касты, триггерные заклинания и многие механики боссов никогда не появляются в этих API. На ритейле это означает, что значительная часть списка заклинаний существа просто ненаблюдаема со стороны клиента.

- **Традиционный сниффинг дорогой.** Классический пайплайн — запустить Ymir-сниффер, захватить трафик, обработать через WowPacketParser, вручную извлечь данные — работает, но требует специализированных инструментов, аккуратной очистки кэша, определённых паттернов перемещения (пешком = плотные данные, полёт = разреженные) и значительной постобработки. Это не то, что можно дать гильдии игроков со словами «идите помогите».

**CreatureCodex решает это двухуровневым подходом:**

Клиентский визуальный сканер делает всё возможное с ограниченными API — опрашивает полосы каста на 10 Гц, сканирует ауры неймплейтов на 5 Гц, оборачивает каждый доступ в taint-безопасные хелперы. Это работает на любом сервере без каких-либо патчей.

Серверные C++ хуки полностью обходят все клиентские ограничения. Четыре хука `UnitScript` срабатывают на каждый `Spell::cast()`, `Spell::SendSpellGo()`, `Spell::SendChannelUpdate()` и `Unit::_ApplyAura()` — перехватывая 100% кастов, включая мгновенные, скрытые и триггерные заклинания. Данные транслируются как лёгкие аддон-сообщения только ближайшим игрокам с установленным аддоном, поэтому нулевая нагрузка для тех, у кого его нет.

При совместной работе обоих уровней аддон автоматически удаляет дубликаты, и вы получаете полные, без пробелов базы данных заклинаний существ, которые можно экспортировать прямо в SQL.

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
