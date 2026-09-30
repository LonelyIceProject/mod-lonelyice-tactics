-- Bot tactics: the id catalogue (spec section 8).
-- Ids, sides, level gates and labels (en / ru). The whole catalogue is sent to the addon in the CAT
-- message, so adding an entry here (plus its implementation in targets.lua / conditions.lua /
-- actions.lua) makes it appear in the editor without touching the addon or C++.
-- Order of the arrays = order in the editor dropdowns.

local catalog = {}

-- Targets ------------------------------------------------------------------------------------------
-- side: "own" (friendly units) or "foe"; lvl: bot level needed to use it (0 everywhere: no level gates).
catalog.targets = {
    { id = "self",       side = "own", lvl = 0,  label = { en = "Bot itself",       ru = "Сам бот" } },
    { id = "ally",       side = "own", lvl = 0,  label = { en = "Ally",             ru = "Союзник" } },
    { id = "tank",       side = "own", lvl = 0,  label = { en = "Tank",             ru = "Танк" } },
    { id = "healer",     side = "own", lvl = 0, label = { en = "Healer",           ru = "Лекарь" } },
    { id = "leader",     side = "own", lvl = 0,  label = { en = "You (leader)",     ru = "Вы (лидер)" } },
    { id = "foe_cur",    side = "foe", lvl = 0,  label = { en = "Current target",   ru = "Текущая цель" } },
    { id = "foe_leader_tgt", side = "foe", lvl = 0, label = { en = "Your target",      ru = "Цель лидера (ваша)" } },
    { id = "foe_tank_tgt",   side = "foe", lvl = 0, label = { en = "Tank's target",    ru = "Цель танка" } },
    { id = "foe_near",   side = "foe", lvl = 0,  label = { en = "Nearest foe",      ru = "Ближайший" } },
    { id = "foe_me",     side = "foe", lvl = 0,  label = { en = "Attacking me",     ru = "Бьёт меня" } },
    { id = "foe_healer", side = "foe", lvl = 0, label = { en = "Attacking healer", ru = "Бьёт лекаря" } },
    { id = "foe_skull",  side = "foe", lvl = 0,  label = { en = "Skull mark",       ru = "Метка «череп»" } },
    { id = "foe_moon",   side = "foe", lvl = 0, label = { en = "Moon mark",        ru = "Метка «луна»" } },
    { id = "foe_boss",   side = "foe", lvl = 0, label = { en = "Boss or elite",    ru = "Босс или элитный" } },
}

-- Conditions ---------------------------------------------------------------------------------------
-- param: "none" | "num" | "spell" | "spellid" | "dispel" | "enum". For "num": default/min/max (integers).
-- "spell" = a spell of the bot's book (aura picker); "spellid" = any spell id (typed / pasted link).
-- label = dropdown text, prefix/unit = inline text around the value in the rule row.
catalog.conditions = {
    { id = "any", param = "none", lvl = 0,
      label = { en = "any", ru = "любой" }, prefix = { en = "any", ru = "любой" } },
    { id = "hp_lt", param = "num", lvl = 0, default = 30, min = 1, max = 100,
      label = { en = "HP below...", ru = "здоровье ниже…" },
      prefix = { en = "HP <", ru = "здоровье <" }, unit = { en = "%", ru = "%" } },
    { id = "hp_ge", param = "num", lvl = 0, default = 90, min = 1, max = 100,
      label = { en = "HP at least...", ru = "здоровье не ниже…" },
      prefix = { en = "HP ≥", ru = "здоровье ≥" }, unit = { en = "%", ru = "%" } },
    { id = "lowest", param = "none", lvl = 0,
      label = { en = "lowest HP", ru = "самый раненый" }, prefix = { en = "lowest HP", ru = "самый раненый" } },
    { id = "mp_lt", param = "num", lvl = 0, default = 20, min = 1, max = 100,
      label = { en = "mana below...", ru = "мана ниже…" },
      prefix = { en = "mana <", ru = "мана <" }, unit = { en = "%", ru = "%" } },
    { id = "dead", param = "none", lvl = 0,
      label = { en = "dead", ru = "мёртв" }, prefix = { en = "dead", ru = "мёртв" } },
    { id = "no_aura", param = "spell", lvl = 0,
      label = { en = "missing aura...", ru = "нет эффекта…" }, prefix = { en = "no", ru = "нет" } },
    { id = "has_aura", param = "spell", lvl = 0,
      label = { en = "has aura...", ru = "есть эффект…" }, prefix = { en = "has", ru = "есть" } },
    { id = "dispel", param = "dispel", lvl = 0, default = "magic",
      label = { en = "dispellable...", ru = "можно снять…" }, prefix = { en = "dispel:", ru = "снять:" } },
    -- What a player can read off the unit frame: class, mana bar, creature type.
    { id = "class_is", param = "enum", enum = "unit_class", lvl = 0, default = "mage",
      label = { en = "class is...", ru = "класс…" }, prefix = { en = "class:", ru = "класс:" } },
    { id = "caster", param = "none", lvl = 0,
      label = { en = "has a mana bar (caster)", ru = "есть мана (заклинатель)" },
      prefix = { en = "has mana (caster)", ru = "есть мана (заклинатель)" } },
    { id = "ctype_is", param = "enum", enum = "creature_type", lvl = 0, default = "humanoid",
      label = { en = "creature type...", ru = "тип существа…" }, prefix = { en = "type:", ru = "тип:" } },
    { id = "casting", param = "none", lvl = 0,
      label = { en = "casting (interruptible)", ru = "читает заклинание" },
      prefix = { en = "casting (interruptible)", ru = "читает заклинание" } },
    { id = "dist_gt", param = "num", lvl = 0, default = 20, min = 1, max = 100,
      label = { en = "farther than...", ru = "дальше…" },
      prefix = { en = "farther than", ru = "дальше" }, unit = { en = "yd", ru = "ярд." } },
    { id = "near_ge", param = "num", lvl = 0, default = 3, min = 1, max = 20,
      label = { en = "enemies nearby at least...", ru = "врагов рядом не меньше…" },
      prefix = { en = "enemies ≥", ru = "врагов рядом ≥" } },
    { id = "combat_gt", param = "num", lvl = 0, default = 30, min = 1, max = 600,
      label = { en = "combat longer than...", ru = "бой длится дольше…" },
      prefix = { en = "combat >", ru = "бой дольше" }, unit = { en = "s", ru = "с" } },
    -- tactics-round2-spec 3. "healer_mp_lt" .. "my_mp_lt" look at the party / the bot itself (the rule's
    -- target only has to be alive). param "spellid" = any spell id (enemy casts), typed or pasted as a link.
    { id = "healer_mp_lt", param = "num", lvl = 0, default = 30, min = 1, max = 100,
      label = { en = "healer's mana below...", ru = "мана лекаря ниже…" },
      prefix = { en = "healer mana <", ru = "мана лекаря <" }, unit = { en = "%", ru = "%" } },
    { id = "tank_hp_lt", param = "num", lvl = 0, default = 40, min = 1, max = 100,
      label = { en = "tank's HP below...", ru = "здоровье танка ниже…" },
      prefix = { en = "tank HP <", ru = "здоровье танка <" }, unit = { en = "%", ru = "%" } },
    { id = "my_hp_lt", param = "num", lvl = 0, default = 40, min = 1, max = 100,
      label = { en = "my HP below...", ru = "моё здоровье ниже…" },
      prefix = { en = "my HP <", ru = "моё здоровье <" }, unit = { en = "%", ru = "%" } },
    { id = "my_mp_lt", param = "num", lvl = 0, default = 30, min = 1, max = 100,
      label = { en = "my mana below...", ru = "моя мана ниже…" },
      prefix = { en = "my mana <", ru = "моя мана <" }, unit = { en = "%", ru = "%" } },
    { id = "me_aura", param = "spell", lvl = 0,
      label = { en = "I have aura...", ru = "на мне эффект…" }, prefix = { en = "on me:", ru = "на мне:" } },
    { id = "me_no_aura", param = "spell", lvl = 0,
      label = { en = "I lack aura...", ru = "на мне нет эффекта…" }, prefix = { en = "not on me:", ru = "нет на мне:" } },
    { id = "no_aura_mine", param = "spell", lvl = 0,
      label = { en = "missing my aura...", ru = "нет моего эффекта…" }, prefix = { en = "no my", ru = "нет моего" } },
    { id = "casting_spell", param = "spellid", lvl = 0,
      label = { en = "casting spell...", ru = "читает заклинание…" }, prefix = { en = "casts", ru = "читает" } },
    { id = "casting_any", param = "none", lvl = 0,
      label = { en = "casting (any)", ru = "читает (любое)" }, prefix = { en = "casting (any)", ru = "читает (любое)" } },
    { id = "moving", param = "none", lvl = 0,
      label = { en = "moving", ru = "движется" }, prefix = { en = "moving", ru = "движется" } },
    { id = "foes_ge", param = "num", lvl = 0, default = 3, min = 1, max = 20,
      label = { en = "enemies in fight at least...", ru = "врагов в бою не меньше…" },
      prefix = { en = "foes in fight ≥", ru = "врагов в бою ≥" } },
}

-- Special actions ---------------------------------------------------------------------------------
-- side "any" works with every target, "foe" only with foe targets.
-- ("spell" and "item" are the two non-special action kinds, see actions.lua.)
catalog.specials = {
    { id = "attack", side = "foe",
      label = { en = "Attack (switch target)", ru = "Атаковать (сменить цель)" },
      desc = { en = "Switch current target; the class AI keeps hitting it",
               ru = "Сменить текущую цель, дальше её бьёт классовый ИИ" } },
    { id = "behind", side = "any",
      label = { en = "Stand behind tank", ru = "Встать за танка" },
      desc = { en = "Move behind the tank and stay there", ru = "Отойти за спину танку и держаться там" } },
    { id = "follow", side = "any",
      label = { en = "Follow leader", ru = "Следовать за лидером" },
      desc = { en = "Drop everything and run to you", ru = "Бросить всё и бежать к вам" } },
    { id = "wait", side = "any",
      label = { en = "Wait", ru = "Ждать" },
      desc = { en = "Do nothing: blocks the rules below while true",
               ru = "Ничего не делать: блокирует правила ниже, пока условие верно" } },
}

-- Item categories (picker tabs) ---------------------------------------------------------------------
catalog.itemcats = {
    { id = "potion", label = { en = "Potions", ru = "Зелья" } },
    { id = "elixir", label = { en = "Elixirs & flasks", ru = "Эликсиры и настои" } },
    { id = "food",   label = { en = "Food, drink, bandages", ru = "Еда, питьё, бинты" } },
    { id = "enh",    label = { en = "Oils, poisons, stones", ru = "Масла, яды, точила" } },
    { id = "misc",   label = { en = "Other", ru = "Прочее" } },
}

-- Consumable (item class 0) subclass -> item category id. Anything missing -> "misc".
catalog.itemSubclassCat = {
    [1] = "potion",
    [2] = "elixir", [3] = "elixir",
    [5] = "food",   [7] = "food",
    [6] = "enh",    [8] = "enh",
}

-- Dispel ids (value of the "dispel" condition) -> DispelType ------------------------------------------
catalog.dispels = {
    { id = "magic",   type = 1, label = { en = "Magic",   ru = "Магия" } },
    { id = "curse",   type = 2, label = { en = "Curse",   ru = "Проклятие" } },
    { id = "disease", type = 3, label = { en = "Disease", ru = "Болезнь" } },
    { id = "poison",  type = 4, label = { en = "Poison",  ru = "Яд" } },
}

-- Option lists of "enum" conditions (value = number compared by the condition) -------------------------
-- NPCs only ever have warrior / paladin / rogue / mage (the class shown on their unit frame).
catalog.enums = {
    unit_class = {
        { id = "warrior", value = 1,  label = { en = "Warrior", ru = "Воин" } },
        { id = "paladin", value = 2,  label = { en = "Paladin", ru = "Паладин" } },
        { id = "rogue",   value = 4,  label = { en = "Rogue",   ru = "Разбойник" } },
        { id = "mage",    value = 8,  label = { en = "Mage",    ru = "Маг" } },
        { id = "hunter",  value = 3,  label = { en = "Hunter (players)",       ru = "Охотник (игроки)" } },
        { id = "priest",  value = 5,  label = { en = "Priest (players)",       ru = "Жрец (игроки)" } },
        { id = "dk",      value = 6,  label = { en = "Death Knight (players)", ru = "Рыцарь смерти (игроки)" } },
        { id = "shaman",  value = 7,  label = { en = "Shaman (players)",       ru = "Шаман (игроки)" } },
        { id = "warlock", value = 9,  label = { en = "Warlock (players)",      ru = "Чернокнижник (игроки)" } },
        { id = "druid",   value = 11, label = { en = "Druid (players)",        ru = "Друид (игроки)" } },
    },
    creature_type = {
        { id = "humanoid",   value = 7, label = { en = "Humanoid",   ru = "Гуманоид" } },
        { id = "beast",      value = 1, label = { en = "Beast",      ru = "Животное" } },
        { id = "undead",     value = 6, label = { en = "Undead",     ru = "Нежить" } },
        { id = "demon",      value = 3, label = { en = "Demon",      ru = "Демон" } },
        { id = "elemental",  value = 4, label = { en = "Elemental",  ru = "Элементаль" } },
        { id = "dragonkin",  value = 2, label = { en = "Dragonkin",  ru = "Дракон" } },
        { id = "giant",      value = 5, label = { en = "Giant",      ru = "Великан" } },
        { id = "mechanical", value = 9, label = { en = "Mechanical", ru = "Механизм" } },
        { id = "critter",    value = 8, label = { en = "Critter",    ru = "Зверёк" } },
    },
}

-- Server messages (ACK texts, errors, default names) ------------------------------------------------
catalog.text = {
    ok               = { en = "Saved.",                                   ru = "Сохранено." },
    bad_bot          = { en = "This bot is not in your party.",           ru = "Этот бот не в вашей группе." },
    bad_preset       = { en = "No such rule set.",                        ru = "Нет такого набора правил." },
    too_many_rules   = { en = "Too many rules for this level.",           ru = "Слишком много правил для этого уровня." },
    locked_target    = { en = "Target is locked at this level: %s.",      ru = "Цель ещё недоступна: %s." },
    locked_condition = { en = "Condition is locked at this level: %s.",   ru = "Условие ещё недоступно: %s." },
    cond2_locked     = { en = "Second condition unlocks at level %d.",    ru = "Второе условие откроется на уровне %d." },
    unknown_id       = { en = "Unknown id: %s.",                          ru = "Неизвестный идентификатор: %s." },
    bad_value        = { en = "Invalid value in rule %d.",                ru = "Неверное значение в правиле %d." },
    unknown_spell    = { en = "Unknown spell in rule %d.",                ru = "Неизвестное заклинание в правиле %d." },
    bad_item         = { en = "Invalid item in rule %d.",                 ru = "Неверный предмет в правиле %d." },
    bad_name         = { en = "Invalid rule set name.",                   ru = "Неверное имя набора." },
    store_failed     = { en = "Could not save (data too large).",         ru = "Не удалось сохранить (слишком много данных)." },
    last_preset      ={ en = "The last rule set cannot be deleted.",     ru = "Последний набор удалить нельзя." },
    proto            = { en = "BotTactics addon version is not supported by the server.",
                         ru = "Версия аддона BotTactics не поддерживается сервером." },
    internal         = { en = "Server script error, see the server log.", ru = "Ошибка серверного скрипта, см. лог сервера." },
    preset_name      = { en = "Preset %d",                                ru = "Набор %d" },

    -- Party window (party-window-spec section 8). C++ reasons map 1:1 to these codes.
    done             = { en = "Done.",                                    ru = "Готово." },
    failed           = { en = "Failed.",                                  ru = "Не удалось." },
    unknown_reason   = { en = "Failed (%s).",                             ru = "Не удалось (%s)." },
    combat           = { en = "Not in combat.",                           ru = "Нельзя в бою." },
    dead             = { en = "The bot is dead.",                         ru = "Бот мёртв." },
    far              = { en = "The bot is too far away.",                 ru = "Бот слишком далеко." },
    no_vendor        = { en = "No vendor near the bot.",                  ru = "Рядом с ботом нет торговца." },
    no_banker        = { en = "No banker near the bot.",                  ru = "Рядом с ботом нет банкира." },
    no_trainer       = { en = "No trainer near the bot.",                 ru = "Рядом с ботом нет наставника." },
    stale            = { en = "Bags changed, refreshing.",                ru = "Сумки изменились, обновляю." },
    bad_pos          = { en = "Invalid item position.",                   ru = "Неверное место предмета." },
    bad_op           = { en = "Unknown operation.",                       ru = "Неизвестная операция." },
    cannot           = { en = "Cannot do this with that item.",           ru = "Нельзя сделать с этим предметом." },
    busy             = { en = "The bot is busy (casting).",               ru = "Бот занят (читает заклинание)." },
    moving           = { en = "The bot is moving, try again.",            ru = "Бот двигается, повторите." },
    trading          = { en = "Close the trade window first.",            ru = "Сначала закройте обмен." },
    no_trade         = { en = "The trade window is not open.",            ru = "Окно обмена не открыто." },
    not_tradable     = { en = "This item cannot be traded.",              ru = "Предмет нельзя передать." },
    full             = { en = "No free space.",                           ru = "Нет места." },
    already          = { en = "Already done.",                            ru = "Уже сделано." },
    in_use           = { en = "The character is already in the game.",    ru = "Персонаж уже в игре." },
    max_bots         = { en = "Bot limit reached.",                       ru = "Достигнут предел ботов." },
    not_allowed      = { en = "Not allowed for this character.",          ru = "Для этого персонажа нельзя." },
    pending          = { en = "The bot is logging in...",                 ru = "Бот входит в игру…" },
    bad_cmd          = { en = "Command not allowed.",                     ru = "Команда не разрешена." },
    bad_spell        = { en = "The bot does not know this spell.",        ru = "Бот не знает этого заклинания." },
    bad_build        = { en = "Invalid talent build: %s",                 ru = "Неверная раскладка: %s" },
    no_dualspec      = { en = "Second specialization not learned.",       ru = "Вторая специализация не освоена." },
    level            = { en = "Requires level %d.",                       ru = "Нужен уровень %d." },
    verify           = { en = "Could not verify the result.",             ru = "Не удалось проверить результат." },
    no_money         = { en = "Not enough money.",                        ru = "Не хватает денег." },
    bad_quest        = { en = "No such quest in the bot's log.",          ru = "В журнале бота нет такого задания." },
    bad_target       = { en = "Invalid target.",                          ru = "Неверная цель." },
    invalid_target   = { en = "The target is gone.",                      ru = "Цель пропала." },
    wrong_thread     = { en = "Internal error (thread).",                 ru = "Внутренняя ошибка (поток)." },
    too_many         = { en = "Too many entries.",                        ru = "Слишком много записей." },
    bad_item_entry   = { en = "No such item.",                            ru = "Нет такого предмета." },
    -- abilities / manual mode (abilities-mirroring-spec 2.1, 2.2): spellbook pseudo-tabs, new C++ reasons
    tab_basic        = { en = "Basic",                                    ru = "Основное" },
    tab_pet          = { en = "Pet",                                      ru = "Питомец" },
    no_pet           = { en = "The bot has no pet.",                      ru = "У бота нет питомца." },
    cannot_cancel    = { en = "This effect cannot be removed.",           ru = "Этот эффект нельзя снять." },
    -- ok texts with numbers (ACK ok of SELLGREY / TRAIN / OUTFIT wear / CMDALL)
    sold             = { en = "Sold %s.",                                 ru = "Продано %s." },
    learned          = { en = "Learned %s.",                              ru = "Выучено %s." },
    outfit_worn      = { en = "Equipped %s.",                             ru = "Надето %s." },
    cmd_sent         = { en = "Command sent to bots: %s.",                ru = "Команда отправлена ботам: %s." },
    outfit_name      = { en = "Outfit %d",                                ru = "Комплект %d" },
    -- ORDER results (reason of "ORDER ... failed" = C++ cast reason)
    order_expired    = { en = "Too late (order expired).",                ru = "Не успел (приказ истёк)." },
    not_known        = { en = "The bot does not know this spell.",        ru = "Бот не знает этого заклинания." },
    cannot_cast      = { en = "Cannot cast now.",                         ru = "Сейчас нельзя применить." },
    mechanics        = { en = "Busy with boss mechanics.",                ru = "Занят механикой босса." },
    range            = { en = "Out of range.",                            ru = "Слишком далеко." },
    cooldown         = { en = "On cooldown.",                             ru = "Ещё не восстановилось." },
    no_item          = { en = "No such item in the bags.",                ru = "Нет такого предмета в сумках." },
    -- AI slider (ai-layer-spec 8): SETSTYLE <bot> ai <n> above the level cap; %d = level of that position
    locked_ai        = { en = "Available from level %d.",                 ru = "Доступно с уровня %d." },
    -- CMDROLE / PULL (multibot-gap "Протокол (реализация)" P8)
    bad_role         = { en = "Unknown role.",                            ru = "Неизвестная роль." },
    no_bots          = { en = "No matching bots.",                        ru = "Нет подходящих ботов." },
    bad_arg          = { en = "Invalid value.",                           ru = "Неверное значение." },
    -- party window extras (party-extras-spec 7): premade builds, glyphs, vendor
    glyph_type       = { en = "The glyph does not fit this socket (major / minor).",
                         ru = "Символ не подходит к этой ячейке (большой / малый)." },
    glyph_pending    = { en = "The glyph is being applied, refreshing...", ru = "Символ ставится, обновляю..." },
    sold_out         = { en = "The vendor is out of this item.",          ru = "У торговца закончился этот товар." },
    bad_spec         = { en = "No such premade build.",                   ru = "Нет такой готовой раскладки." },
    bought           = { en = "Bought %s.",                               ru = "Куплено %s." },
    bought_back      = { en = "Bought back, %s.",                         ru = "Выкуплено, %s." },
    -- money in texts
    money_g          = { en = "g",                                        ru = "з" },
    money_s          = { en = "s",                                        ru = "с" },
    money_c          = { en = "c",                                        ru = "м" },
}

-- Party window: roles (STYLE) -----------------------------------------------------------------------
catalog.roles = {
    { id = "tank", label = { en = "Tank",   ru = "Танк" } },
    { id = "heal", label = { en = "Healer", ru = "Лекарь" } },
    { id = "dps",  label = { en = "Damage", ru = "Боец" } },
}

-- Combat strategies per class and role, from AiFactory::AddDefaultCombatStrategies
-- (PB\Bot\Factory\AiFactory.cpp:295-405). A role is an array of strategy names (the default spec of that
-- role); `byTab[t]` replaces the array when the bot's main talent tab is t (0..2, the tab with most points),
-- so a fury warrior switching to dps gets "fury", not "arms". Roles a class lacks are omitted.
-- Detection: the first role (tank, heal, dps) one of whose own names (not shared with another role of the
-- class) is active. Switching removes the other roles' names and adds this role's names (one "co" command).
catalog.roleStrategies = {
    [1] = {  -- warrior (tabs: 0 arms, 1 fury, 2 protection)
        tank = { "tank", "tank assist", "pull", "pull back", "aoe", "tank face" },
        dps = { "arms", "aoe", "dps assist", byTab = { [1] = { "fury", "aoe", "dps assist" } } },
    },
    [2] = {  -- paladin (0 holy, 1 protection, 2 retribution)
        tank = { "tank", "tank assist", "pull", "pull back", "bthreat", "barmor", "cure", "tank face" },
        heal = { "heal", "dps assist", "cure", "bcast" },
        dps = { "dps", "dps assist", "cure", "baoe" },
    },
    [3] = {  -- hunter
        dps = { "cc", "dps assist", "aoe", "bdps" },
    },
    [4] = {  -- rogue
        dps = { "dps assist", "aoe" },
    },
    [5] = {  -- priest (0 discipline, 1 holy, 2 shadow)
        heal = { "heal", "dps assist", "cure", byTab = { [1] = { "holy heal", "dps assist", "cure" } } },
        dps = { "dps", "shadow debuff", "shadow aoe", "dps assist", "cure" },
    },
    [6] = {  -- death knight (0 blood, 1 frost, 2 unholy)
        tank = { "blood", "tank assist", "pull", "pull back", "tank face" },
        dps = { "frost", "frost aoe", "dps assist", byTab = { [2] = { "unholy", "unholy aoe", "dps assist" } } },
    },
    [7] = {  -- shaman (0 elemental, 1 enhancement, 2 restoration)
        heal = { "resto", "stoneskin", "flametongue", "mana spring", "wrath of air", "dps assist", "cure", "aoe" },
        dps = { "ele", "stoneskin", "wrath", "mana spring", "wrath of air", "dps assist", "cure", "aoe",
                byTab = { [1] = { "enh", "strength of earth", "magma", "healing stream", "windfury",
                                  "dps assist", "cure", "aoe" } } },
    },
    [8] = {  -- mage
        dps = { "dps", "dps assist", "cure", "cc", "aoe" },
    },
    [9] = {  -- warlock
        dps = { "cc", "dps assist", "aoe" },
    },
    [11] = { -- druid (0 balance, 1 feral, 2 restoration)
        tank = { "bear", "tank assist", "pull", "pull back", "feral charge", "tank face" },
        heal = { "resto", "cure", "dps assist", "tranquility" },
        dps = { "balance", "cure", "aoe", "cc", "dps assist",
                byTab = { [1] = { "cat", "aoe", "cc", "dps assist", "feral charge" } } },
    },
}

-- Style toggles (STYLE / SETSTYLE). key = protocol id, list = "co" | "nc", strategy = playerbots name.
-- Adding an entry here adds a switch to the Style tab (labels come from the server) and whitelists
-- "<list> +<strategy>" / "<list> -<strategy>" for CMD.
-- Optional fields (multibot-gap "Протокол (реализация)" P2/P7):
--   class = { class ids }  only these classes get the entry (nil = every class); such entries are "cls" 1
--   group = group id       radio group of catalog.styleGroups (one member on at a time)
--   also  = "co" | "nc"    the command is also run on this second list (mage armor lives in both engines)
-- Strategy names are checked against mod-playerbots (StrategyContext.h, Ai\Class\*\*AiObjectContext.cpp).
catalog.style = {
    { key = "aoe", list = "co", strategy = "aoe",
      label = { en = "Area attacks", ru = "Бить по площади" },
      hint = { en = "Use area abilities when several enemies are close.",
               ru = "Использовать умения по площади, когда врагов рядом несколько." } },
    { key = "save_mana", list = "co", strategy = "save mana",
      label = { en = "Save mana", ru = "Экономить ману" },
      hint = { en = "Prefer cheaper spells and keep a mana reserve.",
               ru = "Выбирать заклинания подешевле и держать запас маны." } },
    { key = "behind", list = "co", strategy = "behind",
      label = { en = "Stay behind the target", ru = "Держаться за спиной цели" },
      hint = { en = "Melee: attack the enemy from behind.", ru = "Ближний бой: заходить врагу за спину." } },
    { key = "avoid_aoe", list = "co", strategy = "avoid aoe",
      label = { en = "Avoid AoE", ru = "Уходить из АоЕ" },
      hint = { en = "Step out of harmful ground effects.", ru = "Выходить из опасных зон на земле." } },
    -- group "assist": AssistStrategyContext has supportsSiblings, "+x" drops the other two (StrategyContext.h:233)
    { key = "dps_assist", list = "co", strategy = "dps assist", group = "assist",
      label = { en = "Assist the tank (hit its target)", ru = "Помогать танку (бить его цель)" },
      hint = { en = "Attack what the tank attacks.", ru = "Атаковать ту же цель, что и танк." } },
    { key = "dps_aoe", list = "co", strategy = "dps aoe", group = "assist",
      label = { en = "Spread over the pack", ru = "Бить цели по площади" },
      hint = { en = "Pick targets so that area attacks hit most enemies.",
               ru = "Выбирать цели так, чтобы атаки по площади задевали больше врагов." } },
    { key = "tank_assist", list = "co", strategy = "tank assist", group = "assist",
      label = { en = "Hold enemies on itself", ru = "Держать врагов на себе" },
      hint = { en = "Tank: pick up enemies that attack the group.",
               ru = "Танк: забирать врагов, которые бьют группу." } },
    { key = "focus", list = "co", strategy = "focus",
      label = { en = "Focus one target", ru = "Фокус на одной цели" },
      hint = { en = "Keep hitting one enemy instead of spreading damage.",
               ru = "Бить одного врага, не распыляясь." } },
    { key = "passive", list = "co", strategy = "passive",
      label = { en = "Passive", ru = "Пассивно" },
      hint = { en = "Do not attack; only follow you.",
               ru = "Не атаковать: только следовать за вами." } },
    { key = "buff", list = "nc", strategy = "buff",
      label = { en = "Group buffs", ru = "Баффы на группу" },
      hint = { en = "Keep buffs up on the group out of combat.", ru = "Поддерживать баффы на группе вне боя." } },
    { key = "loot", list = "nc", strategy = "loot",
      label = { en = "Pick up loot", ru = "Подбирать добычу" },
      hint = { en = "Loot corpses after the fight.", ru = "Обыскивать добычу после боя." } },
    { key = "gather", list = "nc", strategy = "gather",
      label = { en = "Gather herbs and ore", ru = "Собирать травы и руду" },
      hint = { en = "Use gathering professions on the way.", ru = "Собирать по пути, если есть профессия." } },
    { key = "food", list = "nc", strategy = "food",
      label = { en = "Eat and drink", ru = "Есть и пить самостоятельно" },
      hint = { en = "Eat and drink after fights when low.", ru = "Есть и пить после боя, когда нужно." } },
    -- general combat toggles (StrategyContext: "threat")
    { key = "threat", list = "co", strategy = "threat",
      label = { en = "Watch threat", ru = "Следить за угрозой" },
      hint = { en = "Hold back when about to pull aggro from the tank.",
               ru = "Сбавлять урон, когда вот-вот перетянет врага с танка." } },
    -- class toggles
    { key = "tank_face", list = "co", strategy = "tank face", class = { 1, 2, 6, 11 },
      label = { en = "Turn enemies away from the group", ru = "Разворачивать врагов от группы" },
      hint = { en = "Tank: keep enemies facing away from the party.",
               ru = "Танк: держать врагов мордой от группы." } },
    { key = "healer_dps", list = "co", strategy = "healer dps", class = { 2, 5, 7, 11 },
      label = { en = "Healer deals damage", ru = "Лекарь бьёт врагов" },
      hint = { en = "Healer: attack when nobody needs healing.",
               ru = "Лекарь: атаковать, когда лечить некого." } },
    { key = "offheal", list = "co", strategy = "offheal", class = { 11 },
      label = { en = "Cat form with off-heals", ru = "Кошка с подлечиванием" },
      hint = { en = "Feral: fight in cat form and heal the group when needed.",
               ru = "Сила зверя: бить в облике кошки и подлечивать группу." } },
    { key = "boost", list = "co", strategy = "boost", class = { 2, 4, 5, 7, 8, 9, 11 },
      label = { en = "Use cooldowns", ru = "Использовать кулдауны" },
      hint = { en = "Use offensive cooldowns in fights.", ru = "Применять усиления урона в бою." } },
    { key = "stealth", list = "nc", strategy = "stealth", class = { 4 },
      label = { en = "Stealth between fights", ru = "Незаметность вне боя" },
      hint = { en = "Move in stealth out of combat.", ru = "Передвигаться в незаметности вне боя." } },
    { key = "stealthed", list = "co", strategy = "stealthed", class = { 4 },
      label = { en = "Open from stealth", ru = "Нападать из незаметности" },
      hint = { en = "Use stealth openers in combat.", ru = "Начинать бой приёмами из незаметности." } },
    { key = "trap_weave", list = "co", strategy = "trap weave", class = { 3 },
      label = { en = "Trap weaving", ru = "Ловушки в бою" },
      hint = { en = "Step in to drop traps during the fight.", ru = "Подходить и ставить ловушки в бою." } },
    { key = "firestarter", list = "co", strategy = "firestarter", class = { 8 },
      label = { en = "Firestarter", ru = "Поджигатель" },
      hint = { en = "Fire: use Firestarter procs (Flamestrike on the move).",
               ru = "Огонь: использовать срабатывания «Поджигателя»." } },
    { key = "rshadow_prayer", list = "nc", strategy = "rshadow", class = { 5 },
      label = { en = "Shadow Protection", ru = "Защита от тёмной магии" },
      hint = { en = "Keep Shadow Protection on the group.", ru = "Поддерживать защиту от тёмной магии на группе." } },
    { key = "frost_aoe", list = "co", strategy = "frost aoe", class = { 6 },
      label = { en = "Frost: area attacks", ru = "Лёд: атаки по площади" },
      hint = { en = "Frost Death Knight area rotation.", ru = "Ротация по площади для ветки «Лёд»." } },
    { key = "unholy_aoe", list = "co", strategy = "unholy aoe", class = { 6 },
      label = { en = "Unholy: area attacks", ru = "Нечестивость: атаки по площади" },
      hint = { en = "Unholy Death Knight area rotation.", ru = "Ротация по площади для ветки «Нечестивость»." } },
}

-- Radio groups of the Style tab (STYLE field 8). none = every member may be off; cls = class block
-- ("Классовое"); list = section of a non-class group. Members are catalog.style entries with `group`.
catalog.styleGroups = {
    { id = "assist", list = "co", none = true, cls = false,
      label = { en = "Target choice", ru = "Выбор цели" },
      hint = { en = "Whose target to attack. The three options exclude each other.",
               ru = "Чью цель бить. Три варианта исключают друг друга." } },
}

-- Class radio groups: { id, list, class, none, also, label, hint, options = { { suffix, strategy, en, ru } } }.
-- Every option becomes a catalog.style entry "<prefix>_<suffix>" in the group (empty hint: the group has one).
local classGroups = {
    { id = "pal_bless", prefix = "pal_bless", list = "nc", class = { 2 }, none = true,
      label = { en = "Blessing", ru = "Благословение" },
      hint = { en = "Blessing the paladin keeps on the group.", ru = "Какое благословение паладин держит на группе." },
      options = { { "kings", "bkings", "Kings", "Королей" }, { "might", "bmight", "Might", "Могущества" },
                  { "wisdom", "bwisdom", "Wisdom", "Мудрости" }, { "sanc", "bsanc", "Sanctuary", "Неприкосновенности" } } },
    { id = "pal_aura_nc", prefix = "pal_nc", list = "nc", class = { 2 }, none = true,
      label = { en = "Aura out of combat", ru = "Аура вне боя" },
      hint = { en = "Aura between fights.", ru = "Аура между боями." }, options = "pal_auras" },
    { id = "pal_aura_co", prefix = "pal_co", list = "co", class = { 2 }, none = true,
      label = { en = "Aura in combat", ru = "Аура в бою" },
      hint = { en = "Aura during fights.", ru = "Аура во время боя." }, options = "pal_auras" },
    { id = "hunt_aspect_nc", prefix = "hunt_nc", list = "nc", class = { 3 }, none = true,
      label = { en = "Aspect out of combat", ru = "Дух вне боя" },
      hint = { en = "Aspect between fights.", ru = "Дух между боями." }, options = "hunt_aspects" },
    { id = "hunt_aspect_co", prefix = "hunt_co", list = "co", class = { 3 }, none = true,
      label = { en = "Aspect in combat", ru = "Дух в бою" },
      hint = { en = "Aspect during fights.", ru = "Дух во время боя." }, options = "hunt_aspects" },
    { id = "hunt_spec", prefix = "hunt_spec", list = "co", class = { 3 }, none = false,
      label = { en = "Rotation", ru = "Ротация" },
      hint = { en = "Which talent tree rotation the hunter uses.", ru = "Ротация какой ветки талантов использовать." },
      options = { { "bm", "bm", "Beast Mastery", "Повелитель зверей" }, { "mm", "mm", "Marksmanship", "Стрельба" },
                  { "surv", "surv", "Survival", "Выживание" } } },
    { id = "mage_armor", prefix = "mage_armor", list = "nc", also = "co", class = { 8 }, none = false,
      label = { en = "Armor", ru = "Доспех" },
      hint = { en = "Armor spell the mage keeps up.", ru = "Какой доспех маг держит на себе." },
      options = { { "molten", "bdps", "Molten Armor", "Раскалённый доспех" },
                  { "mage", "bmana", "Mage Armor", "Магический доспех" } } },
    { id = "mage_school", prefix = "mage_school", list = "co", class = { 8 }, none = false,
      label = { en = "School", ru = "Школа" },
      hint = { en = "Which rotation the mage uses.", ru = "Какую ротацию использует маг." },
      options = { { "arcane", "arcane", "Arcane", "Тайная магия" }, { "fire", "fire", "Fire", "Огонь" },
                  { "frostfire", "frostfire", "Frostfire", "Ледяной огонь" }, { "frost", "frost", "Frost", "Лёд" } } },
    { id = "lock_curse", prefix = "lock_curse", list = "co", class = { 9 }, none = true,
      label = { en = "Curse", ru = "Проклятие" },
      hint = { en = "Curse the warlock keeps on the target.", ru = "Какое проклятие держать на цели." },
      options = { { "agony", "curse of agony", "Agony", "Агонии" },
                  { "elements", "curse of elements", "Elements", "Стихий" },
                  { "doom", "curse of doom", "Doom", "Рока" },
                  { "exhaustion", "curse of exhaustion", "Exhaustion", "Изнеможения" },
                  { "tongues", "curse of tongues", "Tongues", "Косноязычия" },
                  { "weakness", "curse of weakness", "Weakness", "Слабости" } } },
    { id = "lock_stone", prefix = "lock_stone", list = "nc", class = { 9 }, none = true,
      label = { en = "Weapon stone", ru = "Камень на оружие" },
      hint = { en = "Stone the warlock makes and applies.", ru = "Какой камень создавать и накладывать." },
      options = { { "fire", "firestone", "Firestone", "Камень огня" },
                  { "spell", "spellstone", "Spellstone", "Камень чар" } } },
    { id = "lock_ss", prefix = "lock_ss", list = "nc", class = { 9 }, none = true,
      label = { en = "Soulstone", ru = "Камень души" },
      hint = { en = "Who gets the soulstone.", ru = "Кому ставить камень души." },
      options = { { "self", "ss self", "Self", "Себе" }, { "master", "ss master", "You", "Вам" },
                  { "tank", "ss tank", "Tank", "Танку" }, { "healer", "ss healer", "Healer", "Лекарю" } } },
    { id = "lock_pet", prefix = "lock_pet", list = "nc", class = { 9 }, none = true,
      label = { en = "Demon", ru = "Демон" },
      hint = { en = "Which demon the warlock summons.", ru = "Какого демона призывать." },
      options = { { "imp", "imp", "Imp", "Бес" }, { "voidwalker", "voidwalker", "Voidwalker", "Демон Бездны" },
                  { "succubus", "succubus", "Succubus", "Суккуб" }, { "felhunter", "felhunter", "Felhunter", "Охотник Скверны" },
                  { "felguard", "felguard", "Felguard", "Страж Скверны" } } },
    { id = "sham_earth", prefix = "sham_earth", list = "co", class = { 7 }, none = true,
      label = { en = "Earth totem", ru = "Тотем земли" },
      hint = { en = "Earth totem in combat.", ru = "Тотем земли в бою." },
      options = { { "soe", "strength of earth", "Strength of Earth", "Сила земли" },
                  { "stoneskin", "stoneskin", "Stoneskin", "Каменная кожа" },
                  { "tremor", "tremor", "Tremor", "Трепет" }, { "earthbind", "earthbind", "Earthbind", "Оковы земли" } } },
    { id = "sham_fire", prefix = "sham_fire", list = "co", class = { 7 }, none = true,
      label = { en = "Fire totem", ru = "Тотем огня" },
      hint = { en = "Fire totem in combat.", ru = "Тотем огня в бою." },
      options = { { "searing", "searing", "Searing", "Опаляющий" }, { "magma", "magma", "Magma", "Магма" },
                  { "flametongue", "flametongue", "Flametongue", "Язык пламени" },
                  { "wrath", "wrath", "Totem of Wrath", "Тотем гнева" },
                  { "frostres", "frost resistance", "Frost Resistance", "Сопротивление льду" } } },
    { id = "sham_water", prefix = "sham_water", list = "co", class = { 7 }, none = true,
      label = { en = "Water totem", ru = "Тотем воды" },
      hint = { en = "Water totem in combat.", ru = "Тотем воды в бою." },
      options = { { "stream", "healing stream", "Healing Stream", "Исцеляющий поток" },
                  { "spring", "mana spring", "Mana Spring", "Источник маны" },
                  { "cleansing", "cleansing", "Cleansing", "Очищение" },
                  { "fireres", "fire resistance", "Fire Resistance", "Сопротивление огню" } } },
    { id = "sham_air", prefix = "sham_air", list = "co", class = { 7 }, none = true,
      label = { en = "Air totem", ru = "Тотем воздуха" },
      hint = { en = "Air totem in combat.", ru = "Тотем воздуха в бою." },
      options = { { "woa", "wrath of air", "Wrath of Air", "Гнев воздуха" },
                  { "windfury", "windfury", "Windfury", "Неистовство ветра" },
                  { "natureres", "nature resistance", "Nature Resistance", "Сопротивление силам природы" },
                  { "grounding", "grounding", "Grounding", "Заземление" } } },
}

-- Shared option lists (PaladinResistanceStrategyFactoryInternal, HunterBuffStrategyFactoryInternal).
local sharedOptions = {
    pal_auras = { { "devotion", "barmor", "Devotion", "Благочестия" }, { "retri", "baoe", "Retribution", "Воздаяния" },
                  { "conc", "bcast", "Concentration", "Сосредоточенности" }, { "crusader", "bspeed", "Crusader", "Воина Света" },
                  { "rfire", "rfire", "Fire Resistance", "Защиты от огня" },
                  { "rfrost", "rfrost", "Frost Resistance", "Защиты от магии льда" },
                  { "rshadow", "rshadow", "Shadow Resistance", "Защиты от тёмной магии" } },
    hunt_aspects = { { "hawk", "bdps", "Hawk / Dragonhawk", "Ястреб / Дракондор" },
                     { "pack", "bspeed", "Pack / Cheetah", "Стая / Гепард" },
                     { "wild", "rnature", "Wild", "Дикая природа" } },
}

for _, g in ipairs(classGroups) do
    catalog.styleGroups[#catalog.styleGroups + 1] = { id = g.id, list = g.list, also = g.also, none = g.none,
        cls = true, label = g.label, hint = g.hint }
    local opts = type(g.options) == "string" and sharedOptions[g.options] or g.options
    for _, o in ipairs(opts) do
        catalog.style[#catalog.style + 1] = { key = g.prefix .. "_" .. o[1], list = g.list, strategy = o[2],
            class = g.class, group = g.id, also = g.also, label = { en = o[3], ru = o[4] } }
    end
end

-- Chat command whitelist (CMD / CMDALL and every command Lua sends, party-window-spec 5.2).
-- Checked by protocol.commandAllowed: exact texts, the "co"/"nc" strategy lists (names from catalog.style
-- and catalog.roleStrategies), formation / rti names, always-loot item links, "wait for attack time <n>".
catalog.commands = {
    exact = {
        "follow", "stay", "flee", "grind", "attack my target", "co +passive", "co -passive", "release",
        "revive", "drink", "summon", "reset botAI", "maintenance", "autogear", "trainer learn", "accept *",
        "nc +loot", "nc -loot", "ll useful", "ll normal", "ll gray", "ll all", "ll disenchant",
        -- multibot-gap P6 (ChatTriggerContext.h; PetsAction.cpp params; DisperseSetAction; RollAction)
        "repair", "open items", "talk", "reset", "pull", "pull rti", "roll", "disperse disable",
        "pet attack", "pet follow", "pet stay", "pet aggressive", "pet defensive", "pet passive", "tame abandon",
    },
    formations = { "arrow", "queue", "near", "melee", "line", "circle", "chaos", "shield" },
    -- index = raid target icon id - 1 (1 star .. 8 skull); 0 / "none" clears
    rti = { "star", "circle", "diamond", "triangle", "moon", "square", "cross", "skull" },
    waitAttackMax = 60,
    disperseMax = 30,        -- "disperse set <1..N>" (playerbots accepts 0..100)
    petNameMax = 12,         -- "tame rename <latin letters>" (TameAction::RenamePet)
    tameNameMax = 40,        -- "tame name <creature name>"
    -- strategy names allowed in "co/nc ±" besides catalog.style and catalog.roleStrategies
    strategies = { co = { "wait for attack" }, nc = {} },
}

-- Role scopes of CMDROLE / PULL (multibot-gap P4). Order = order of the "To whom" dropdown.
catalog.roleScopes = {
    { id = "all",    label = { en = "Everyone", ru = "Все" } },
    { id = "tank",   label = { en = "Tanks",    ru = "Танки" } },
    { id = "heal",   label = { en = "Healers",  ru = "Лекари" } },
    { id = "dps",    label = { en = "Damage",   ru = "Бойцы" } },
    { id = "melee",  label = { en = "Melee",    ru = "Ближний бой" } },
    { id = "ranged", label = { en = "Ranged",   ru = "Дальний бой" } },
}

-- Pull card (multibot-gap P5). wait = "wait for attack time"; focus = "co ±focus" for every bot;
-- assist = strategy of the "assist" group set on non-tank bots (tanks keep "tank assist").
catalog.pull = {
    waitMax = 10,
    presets = {
        { id = "single", wait = 2, focus = true,  assist = "dps assist",
          label = { en = "Single target", ru = "Одна цель" },
          hint = { en = "Wait 2 s, everyone on one target.", ru = "Ждать 2 с, все бьют одну цель." } },
        { id = "pack",   wait = 1, focus = false, assist = "dps aoe",
          label = { en = "Pack", ru = "Пачка" },
          hint = { en = "Wait 1 s, spread area damage over the pack.", ru = "Ждать 1 с, бить пачку по площади." } },
        { id = "safe",   wait = 5, focus = true,  assist = "dps assist",
          label = { en = "Careful", ru = "Осторожно" },
          hint = { en = "Wait 5 s so the tank builds threat, one target.",
                   ru = "Ждать 5 с, пока танк наберёт угрозу; одна цель." } },
        { id = "reset",  wait = 0, focus = false, assist = "dps assist",
          label = { en = "Reset", ru = "Сброс" },
          hint = { en = "No waiting, default targeting.", ru = "Без ожидания, обычный выбор цели." } },
    },
}

-- "useful" (playerbots UsefulLootStrategy): the default for bots of a real player (loot.DEFAULT_MODE).
catalog.lootModes = { "useful", "normal", "gray", "all", "disenchant" }

-- AI initiative slider (ai-layer-spec 2.2, 8): labels and hints of the four positions, sent in STYLE field 7.
catalog.aiPositions = {
    [0] = { label = { en = "Strict", ru = "Строго" },
            hint = { en = "Only your rules and the class AI. The AI layer adds nothing of its own.",
                     ru = "Только ваши правила и классовый ИИ. Сам ничего не добавляет." } },
    [1] = { label = { en = "Safety net", ru = "Подстраховка" },
            hint = { en = "Saves itself, interrupts and dispels when no rule did it.",
                     ru = "Спасает себя, прерывает и снимает эффекты, если правила этого не сделали." } },
    [2] = { label = { en = "Partner", ru = "Напарник" },
            hint = { en = "Also heals by priority, picks the right target, keeps its position and uses cooldowns.",
                     ru = "Ещё лечит по приоритету, выбирает цель, держит позицию и тратит кулдауны." } },
    [3] = { label = { en = "Own judgement", ru = "Сам разберётся" },
            hint = { en = "Reacts faster, watches earlier and switches area attacks by itself.",
                     ru = "Реагирует быстрее, следит заранее и сам включает атаки по площади." } },
}

-- Intents of the AI layer (ai-layer-spec 6), in INTENTS order (index = intent index of the AI trace).
catalog.intents = {
    { id = "preserve_self",  label = { en = "Save itself",   ru = "Спасти себя" } },
    { id = "interrupt",      label = { en = "Interrupt",     ru = "Прервать" } },
    { id = "dispel",         label = { en = "Dispel",        ru = "Снять" } },
    { id = "mana_economy",   label = { en = "Mana",          ru = "Мана" } },
    { id = "heal_priority", label = { en = "Priority heal", ru = "Приоритетное лечение" } },
    { id = "focus_target",   label = { en = "Focus target",  ru = "Фокус цели" } },
    { id = "cooldown_burst", label = { en = "Cooldowns",     ru = "Кулдауны" } },
    { id = "position",       label = { en = "Position",      ru = "Позиция" } },
}

-- Lookup tables by id (built once).
local function index(list)
    local t = {}
    for i = 1, #list do list[i].order = i; t[list[i].id] = list[i] end
    return t
end

catalog.targetById = index(catalog.targets)
catalog.conditionById = index(catalog.conditions)
catalog.specialById = index(catalog.specials)
catalog.itemcatById = index(catalog.itemcats)
catalog.dispelById = index(catalog.dispels)
catalog.enumById = {}
for list, opts in pairs(catalog.enums) do catalog.enumById[list] = index(opts) end
catalog.roleById = index(catalog.roles)
catalog.intentById = index(catalog.intents)

catalog.styleByKey = {}
for i = 1, #catalog.style do
    local e = catalog.style[i]
    catalog.styleByKey[e.key] = e
    if e.class then
        e.classSet = {}
        for _, c in ipairs(e.class) do e.classSet[c] = true end
    end
end
catalog.styleGroupById = index(catalog.styleGroups)
catalog.roleScopeById = index(catalog.roleScopes)
catalog.pullPresetById = index(catalog.pull.presets)

-- Add entries from another module (basics.lua, abilities-mirroring-spec 2.3): t = { specials = {...},
-- conditions = {...} }. An entry whose id exists already replaces that entry's fields (label, desc, ...) in
-- place; new ones are appended (editor order). The *ById indexes are rebuilt. Idempotent.
function catalog.extend(t)
    for _, kind in ipairs({ "specials", "conditions" }) do
        local list = catalog[kind]
        local byId = index(list)
        for _, e in ipairs(t[kind] or {}) do
            local cur = byId[e.id]
            if cur then
                for k, v in pairs(e) do cur[k] = v end
            else
                list[#list + 1] = e
                byId[e.id] = e
            end
        end
    end
    catalog.specialById = index(catalog.specials)
    catalog.conditionById = index(catalog.conditions)
end

-- Is a catalog.style entry available to a class?
function catalog.styleFor(e, class)
    return e.classSet == nil or e.classSet[class or 0] == true
end

return catalog
