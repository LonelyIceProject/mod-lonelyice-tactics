-- BotTactics: client editor for mod-lonelyice-tactics (gambits).
-- Strings (enGB/enUS + ruRU) and the fallback id catalogue. The server sends the real catalogue
-- in CAT (ids, level gates, labels); this copy is only used until CAT arrives.

BotTactics = BotTactics or {}
local BT = BotTactics

local RU = GetLocale() == "ruRU"
BT.RU = RU

local function S(en, ru)
    if RU then
        return ru
    end
    return en
end
-- Tab files (party-window-spec 6.1) define their own strings with it.
BT.S = S

local L = {}
BT.L = L

L.title = S("Party", "Отряд")
L.party = S("Party", "Отряд")
L.noBots = S("No bots of yours in the group. Invite your bots and they will appear here.",
    "В группе нет ваших ботов. Пригласите ботов, и они появятся здесь.")
L.waiting = S("Waiting for the server...", "Ожидание ответа сервера...")
L.noServer = S("No answer from the server: is the tactics module running?",
    "Сервер не отвечает: включён ли модуль тактик?")
L.lvl = S("level %d", "%d ур.")
L.lvlShort = S("lvl %d", "%d ур.")
L.selfSuffix = S("(himself)", "(сам)")
L.leaderSuffix = S("(you)", "(вы)")
L.fromLvl = S("(lvl %d)", "(с %d ур.)")
L.slotsLabel = S("Tactic slots", "Слоты тактики")
L.slotsValue = S("%d / %d", "%d / %d")
L.slotsNext = S(" - +1 at lvl %d", " - +1 на %d ур.")
L.enabled = S("Tactics on", "Тактика включена")
L.enabledTip = S("When off, this bot plays only its class AI.", "Если выключено, бот играет только классовым ИИ.")
L.combat = S("In combat", "В бою")
L.noncombat = S("Out of combat", "Вне боя")
L.newPreset = S("+ preset", "+ набор")
L.presetDefault = S("Preset %d", "Набор %d")
L.presetName = S("Preset name (Enter to save)", "Название набора (Enter - сохранить)")
L.deletePreset = S("Delete this preset", "Удалить этот набор")
L.rename = S("Rename", "Переименовать")
L.deleteShort = S("Delete", "Удалить")
L.presetTip = S("Click: make active. Double-click: rename. Right-click: menu.",
    "Щелчок: сделать активным. Двойной щелчок: переименовать. Правый щелчок: меню.")
L.off = S("tactics off", "тактика выключена")
L.deleteConfirm =S("Delete preset \"%s\"?", "Удалить набор «%s»?")
L.revert = S("Revert", "Отменить")
L.revertTip = S("Drop unsaved changes and reload the rules from the server.",
    "Отбросить несохранённые изменения и заново загрузить правила с сервера.")
L.mechRow = S("Dungeon & boss mechanics - always first", "Механики подземелий и боссов - всегда первыми")
L.mechTag = S("cannot be overridden", "нельзя перебить")
L.classRow = S("Class AI - always last", "Классовый ИИ - всегда последним")
L.classTag = S("when no rule fits", "если ни одно правило не подошло")
-- abilities / manual mode (abilities-mirroring-spec 2.4, 3.5)
L.classRowManual = S("Class AI is off (manual mode)", "Классовый ИИ выключен (ручной режим)")
L.classTagManual = S("only your rules act", "действуют только ваши правила")
L.petSpellNote = S("Pet ability: the bot's pet uses it", "Умение питомца: применяет питомец бота")
L.pickCancel = S("Choose the effect to remove", "Выберите эффект, который снять")
L.botAuras = S("Effects on the bot now", "Эффекты на боте сейчас")
L.cancelAction = S("Remove: %s", "Снять: %s")
L.petAction = S("Pet: %s", "Питомец: %s")
L.style_manual = S("Manual mode", "Ручной режим")
L.style_manualOn = S("Only my rules", "Только мои правила")
L.style_manualTip = S("The class AI stops choosing actions: the bot only does what your rules say (attack, spells, "
    .. "pet...). Mechanics, following, looting, eating and mounting stay automatic.",
    "Классовый ИИ перестаёт выбирать действия: бот делает только то, что велят ваши правила (атака, умения, "
    .. "питомец...). Механики, следование, добыча, еда и езда остаются автоматическими.")
L.style_manualStrict = S("Potions and racials too", "Даже зелья и расовые")
L.style_manualStrictTip = S("Also potions and racial abilities only by rules (otherwise the class AI still uses them "
    .. "to survive).", "Зелья и расовые умения тоже только по правилам (иначе классовый ИИ всё ещё пьёт их, чтобы "
    .. "выжить).")
L.style_manualDim = S("Manual mode: the class AI is off, this has no effect.",
    "Ручной режим: классовый ИИ выключен, это ни на что не влияет.")
L.style_manualAiDim = S("Manual mode: the free AI layer is off.", "Ручной режим: свободный слой выключен.")
L.addRule = S("+ Add rule (free slots: %d)", "+ Добавить правило (свободно слотов: %d)")
L.slotLocked = S("Slot %d unlocks at level %d", "Слот %d откроется на %d уровне")
L.overSlots = S("Beyond the slot limit: this rule is ignored", "Сверх лимита слотов: правило не действует")
L.addCond = S("+ condition", "+ условие")
L.addCondLocked = S("+ condition (lvl %d)", "+ условие (с %d ур.)")
L.cond2Tip = S("Second condition: both must be true.", "Второе условие: должны выполняться оба.")
L.removeCond = S("Remove condition", "Убрать условие")
L.chooseAction = S("Choose action...", "Выберите действие...")
L.chooseAura = S("choose...", "выбрать...")
-- condition param "spellid" (any spell, e.g. what an enemy casts): id box + spell name
L.condSpellId = S("Spell id", "ID заклинания")
L.condSpellUnknown = S("unknown spell", "нет такого заклинания")
L.condSpellIdTip = S("Type the spell id or shift-click / paste a spell link.",
    "Введите ID заклинания или вставьте ссылку на заклинание (Shift+щелчок).")
L.own = S("own", "свои")
L.foe = S("foe", "враг")
L.groupOwn = S("Own", "Свои")
L.groupFoe = S("Foes", "Враги")
L.up = S("Move up", "Выше")
L.down = S("Move down", "Ниже")
L.delete = S("Delete rule", "Удалить правило")
L.drag = S("Drag to reorder", "Перетащите, чтобы изменить порядок")
L.toggle = S("Rule on/off", "Правило вкл./выкл.")
L.locked = S("Locked for this level", "Недоступно на этом уровне")
L.saving = S("Saving...", "Сохранение...")
L.saved = S("Saved", "Сохранено")
L.loading = S("Loading...", "Загрузка...")
L.incompleteAction = S("Not saved: rule %d has no action", "Не сохранено: в правиле %d не выбрано действие")
L.incompleteAura = S("Not saved: rule %d needs an aura", "Не сохранено: в правиле %d не выбран эффект")
L.incompleteSpell = S("Not saved: rule %d needs a spell", "Не сохранено: в правиле %d не выбрано заклинание")
L.notSaved = S("Not saved: %s", "Не сохранено: %s")
L.error = S("Error: %s", "Ошибка: %s")
L.legend = S("Higher row = higher priority. If an action is impossible right now, the next row is checked. Blue glow = the rule just fired.",
    "Строка выше - приоритет выше. Если действие сейчас невозможно, проверяется следующая строка. Синяя подсветка - правило только что сработало.")
L.showFired = S("Show fired rules over party frames", "Показывать сработавшие правила над рамками группы")
L.itemCount = S("x%d", "x%d")

-- picker
L.pickAction = S("Action", "Действие")
L.pickAura = S("Aura for condition", "Эффект для условия")
L.pickSub = S("rule %d - %s", "правило %d - %s")
L.pickCond = S("Condition", "Условие")
L.allConds = S("All conditions", "Все условия")
L.chooseCond = S("Choose a condition", "Выберите условие")
L.cgUnit = S("Target state", "Состояние цели")
L.cgWho = S("Who the target is", "Кто цель")
L.cgAura = S("Effects", "Эффекты")
L.cgCast = S("Casting", "Заклинания")
L.cgMe = S("Me", "Я сам")
L.cgParty = S("Party and fight", "Отряд и бой")
L.cgPet = S("Pet", "Питомец")
L.cgOther = S("Other", "Прочее")
L.allAbilities = S("All abilities", "Все способности")
L.specials = S("Special actions", "Особые действия")
L.search = S("Search...", "Поиск...")
L.searchTitle = S("Search", "Поиск")
L.available = S("%d available", "%d доступно")
L.found = S("%d found", "%d найдено")
L.talent = S("talent", "талант")
L.unkTrainer = S("Learned from the trainer at level %d", "Изучается у наставника на %d уровне")
L.unkTalent = S("Unlocked by a talent", "Открывается талантом")
L.notLearned = S("Not learned yet", "Ещё не изучено")
L.inBags = S("In bags: %d", "В сумках: %d шт.")
L.emptyBags = S("Nothing in the bags. Bots only use what they carry.",
    "В сумках ничего нет. Бот применяет только то, что несёт с собой.")
L.nothing = S("Nothing found.", "Ничего не найдено.")
L.keys = S("Up/Down: select   Enter: confirm   Tab: category   Esc: close",
    "Вверх/вниз: выбор   Enter: подтвердить   Tab: категория   Esc: закрыть")
L.specialNote = S("Special tactic action", "Особое действие тактики")
L.chooseHint = S("Choose an ability", "Выберите способность")
L.foeOnly = S("Needs an enemy target", "Нужна вражеская цель")
L.bookLoading = S("Loading the spellbook...", "Загрузка книги заклинаний...")

-- launcher / slash
L.launcherTip = S("Click: open the party window. Drag: move this button.", "Щелчок: открыть окно отряда. Перетаскивание: сдвинуть кнопку.")
L.slashHelp = S("/party, /tactics, /bt - open the party window; /bt button - show/hide the screen button; /bt reset - reset window positions",
    "/party, /tactics, /bt - открыть окно отряда; /bt button - показать/скрыть кнопку на экране; /bt reset - сбросить положение окон")
L.fired = S("fired", "сработало")

-- ---------------------------------------------------------------- party window (party-window-spec 6.2)
-- Separator of short "a - b - c" lines (the middle dot of the mock is not in every 3.3.5 font).
L.dot = " - "
L.tabTactics = S("Tactics", "Тактика")
L.tabBook = S("Spellbook", "Книга")
L.tabGear = S("Equipment", "Снаряжение")
L.tabBags = S("Bags & trade", "Сумки и обмен")
L.tabTalents = S("Talents", "Таланты")
L.tabStyle = S("Style", "Стиль")
L.tabMisc = S("Other", "Прочее")

-- orders strip
L.ordAll = S("All", "Всем")
L.ordAttack = S("Attack my target", "Атаковать мою цель")
L.ordFollow = S("Follow me", "За мной")
L.ordStay = S("Stay here", "Стоять здесь")
L.ordFlee = S("Fall back", "Отступить")
L.ordPassive = S("Passive", "Пассивно")
L.ordPassiveTip = S("Bots do not attack on their own (co +passive / co -passive). Always all bots, whatever the scope.",
    "Боты не нападают сами (co +passive / co -passive). Всегда для всех ботов, без учёта «Кому».")
L.ordFormation = S("Formation", "Построение")
L.ordMarks = S("Marks", "Метки")
L.ordRevive = S("Raise the fallen", "Воскресить павших")
L.ordRelease = S("Release spirit", "Отпустить дух")
L.ordSpirit = S("Go to the spirit healer", "К духу-целителю")
L.ordDrink = S("Drink / eat", "Пить / есть")
L.ordLoot = S("Loot", "Добыча")
L.lootAllBots = S("Loot rule for every bot", "Правило добычи для всех ботов")
L.ordReviveShort = S("Revive", "Воскресить")
L.ordAttackShort = S("Attack", "Атаковать")
L.ordWho = S("To:", "Кому:")
L.ordWhoTip = S("Who gets the orders of this strip and of the Pull card.",
    "Кто получает приказы этой полосы и карточки «Пулл».")
L.ordPull = S("Pull", "Пулл")
L.ordTankPull = S("Tank: pull my target", "Танк: стянуть мою цель")
L.ordTankPullRti = S("Tank: pull the marked target", "Танк: стянуть цель с меткой")
-- role scopes (CMDROLE); the server's PULLSET labels replace these
L.scopes = {
    { id = "all", label = S("Everyone", "Все") },
    { id = "tank", label = S("Tanks", "Танки") },
    { id = "heal", label = S("Healers", "Лекари") },
    { id = "dps", label = S("Damage", "Бойцы") },
    { id = "melee", label = S("Melee", "Ближний бой") },
    { id = "ranged", label = S("Ranged", "Дальний бой") },
}
-- pull card (multibot-gap P5); presets used until PULLSET brings the server's
L.pullTitle = S("Pull", "Пулл")
L.pullWait = S("Wait before attacking: %d s", "Ждать перед атакой: %d с")
L.pullWaitTip = S("Bots wait this long after the fight starts so the tank gets the enemies first.",
    "Сколько секунд боты ждут после начала боя, чтобы танк успел забрать врагов.")
L.pullPresets = S("Presets", "Пресеты")
L.pullFocus = S("Focus one target", "Фокус на одной цели")
L.pullTarget = S("Targets:", "Цели:")
L.pullAssist = S("Tank's target", "Цель танка")
L.pullAoe = S("Spread over the pack", "По площади")
L.pullNoTanks = S("Tanks keep their own targeting: choose another scope.",
    "Танки выбирают цели сами: выберите другую область.")
L.pullNote = S("The wait is not kept after a bot logs out: press again after a relog.",
    "Ожидание не сохраняется после выхода бота: после перезахода нажмите ещё раз.")
L.pullPresetList = {
    { id = "single", label = S("Single target", "Одна цель"), wait = 2, focus = true, aoe = false },
    { id = "pack", label = S("Pack", "Пачка"), wait = 1, focus = false, aoe = true },
    { id = "safe", label = S("Careful", "Осторожно"), wait = 5, focus = true, aoe = false },
    { id = "reset", label = S("Reset", "Сброс"), wait = 0, focus = false, aoe = false },
}

L.formations = {
    { id = "arrow", label = S("Arrow", "Стрела") },
    { id = "queue", label = S("Column", "Колонна") },
    { id = "near", label = S("Close", "Ближнее") },
    { id = "melee", label = S("Melee", "Ближний бой") },
    { id = "line", label = S("Line", "Линия") },
    { id = "circle", label = S("Circle", "Круг") },
    { id = "chaos", label = S("Chaos", "Хаос") },
    { id = "shield", label = S("Shield", "Щит") },
}
-- icon = index of Interface\TargetingFrame\UI-RaidTargetingIcon_<n>
L.marks = {
    { id = "none", icon = 0, label = S("No mark", "Без метки") },
    { id = "star", icon = 1, label = S("Star", "Звезда") },
    { id = "circle", icon = 2, label = S("Circle", "Круг") },
    { id = "diamond", icon = 3, label = S("Diamond", "Ромб") },
    { id = "triangle", icon = 4, label = S("Triangle", "Треугольник") },
    { id = "moon", icon = 5, label = S("Moon", "Луна") },
    { id = "square", icon = 6, label = S("Square", "Квадрат") },
    { id = "cross", icon = 7, label = S("Cross", "Крест") },
    { id = "skull", icon = 8, label = S("Skull", "Череп") },
}
L.lootModes = {
    { id = "useful", label = S("Useful and valuable", "Полезное и ценное"),
      desc = S("Default. Upgrades for the bot, quest items, food / potions / ammo / trade goods it needs, and anything green or better. No grey or white vendor trash. Throws away gear it replaced with an upgrade, and quest rewards / leftover quest items it does not need; blue and purple ones are sold at the next vendor instead.",
               "По умолчанию. Вещи лучше надетых, предметы заданий, нужные боту еда, зелья, боеприпасы и материалы, а также всё зелёное и выше. Серый и белый хлам не берёт. Выбрасывает вещи, снятые при замене на лучшие, и ненужные награды и остатки предметов заданий; синие и фиолетовые вместо этого продаёт у ближайшего торговца.") },
    { id = "normal", label = S("Anything that sells", "Всё, что продаётся"),
      desc = S("The useful items plus white and grey items with a vendor price.", "Полезное плюс белые и серые вещи, которые можно продать.") },
    { id = "gray", label = S("Grey", "Серое"),
      desc = S("Anything that sells, plus grey items without a price.", "Всё, что продаётся, плюс любые серые вещи.") },
    { id = "disenchant", label = S("Disenchant", "Распыление"),
      desc = S("Anything that sells, plus green+ armour and weapons for disenchanting.", "Всё, что продаётся, плюс зелёные и лучше доспехи и оружие на распыление.") },
    { id = "all", label = S("All", "Всё"), desc = S("Everything on the corpse.", "Всё с добычи.") },
}

-- roster and header
L.inGroup = S("In group", "В группе")
L.myBots = S("My bots", "Мои боты")
L.callBot = S("+ Call a bot", "+ Позвать бота")
L.noGroupBots = S("No bots of yours in the group", "В группе нет ваших ботов")
L.noAcctBots = S("No other characters", "Других персонажей нет")
L.botsLoading = S("Loading the list...", "Загрузка списка...")
L.pillInvite = S("Invite", "Пригласить")
L.pillLogin = S("Log in", "Войти")
L.pillBusy = S("busy", "занят")
L.roleTank = S("tank", "танк")
L.roleHeal = S("healer", "лекарь")
L.roleDps = S("damage", "урон")
L.notInGame = S("offline", "не в игре")
L.inUse = S("in use elsewhere", "занят в другом месте")
L.levelLong = S("level %d", "%d уровень")
L.dead = S("dead", "мёртв")
L.favAdd = S("Add to favourites", "В избранное")
L.favDel = S("Remove from favourites", "Убрать из избранного")
L.logout = S("Log out", "Выйти из игры")
L.kick = S("Remove from group", "Убрать из группы")
L.summon = S("To me", "Ко мне")
L.trade = S("Trade", "Обмен")
L.maintenance = S("Maintenance", "Обслуживание")
L.tooFar = S("Come closer (11 yd)", "Подойдите ближе (11 м)")
L.noAnswer = S("No answer", "Нет ответа")
L.selectBot = S("Select a bot on the left.", "Выберите бота слева.")
L.notInGroup = S("This bot is not in your group. Log it in and invite it to manage it.",
    "Этот бот не в вашей группе. Введите его в игру и пригласите, чтобы управлять им.")
L.noFreeSlot = S("No free tactic slot", "Нет свободного слота тактики")

-- AI log (tactics tab, 6.3)
L.traceTitle = S("AI log", "Журнал ИИ")
L.traceRefresh = S("Refresh", "Обновить")
L.traceAgo = S("%d s ago", "%d с назад")
L.traceEmpty = S("No actions recorded yet.", "Действий пока нет.")
L.traceTip = S("The last actions the class AI and the tactics executed.", "Последние действия классового ИИ и тактики.")
L.traceAi = S("AI: ", "ИИ: ")

-- AI initiative slider (Style tab, ai-layer-spec 9)
L.style_ai = S("AI initiative", "Инициатива ИИ")
L.style_aiLocked = S("Available from level %d", "Доступно с уровня %d")
L.style_aiStat = S("AI: %s; silent %d%%", "ИИ: %s; молчал %d%%")
L.style_aiNone = S("no actions yet", "пока ничего")
L.style_aiOff = S("AI: off", "ИИ: выключен")
-- intent labels (the server's catalog.intents; used until the catalogue carries them)
L.intents = {
    preserve_self = S("Save itself", "Спасти себя"),
    interrupt = S("Interrupt", "Прервать"),
    dispel = S("Dispel", "Снять"),
    mana_economy = S("Mana", "Мана"),
    heal_priority = S("Priority heal", "Приоритетное лечение"),
    focus_target = S("Focus target", "Фокус цели"),
    cooldown_burst = S("Cooldowns", "Кулдауны"),
    position = S("Position", "Позиция"),
}

-- Label of an AI intent id: the catalogue's (if CAT ever carries intents), else the table above, else the id.
function BT.IntentLabel(id)
    if not id or id == "" then
        return ""
    end
    local cat = BT.cat and BT.cat.intentById
    local e = cat and cat[id]
    if e and e.label and e.label ~= "" then
        return e.label
    end
    return L.intents[id] or id
end

-- bags tab (6.5)
L.bmUse = S("Use", "Использовать")
L.bmEquip = S("Equip", "Надеть")
L.bmGive = S("Give to me", "Передать мне")
L.bmSell = S("Sell", "Продать")
L.bmDestroy = S("Destroy", "Выбросить")
L.bmDeposit = S("To bank", "В банк")
L.bmWithdraw = S("From bank", "Из банка")
L.bmMove = S("Move", "Переложить")
L.backpack = S("Backpack", "Рюкзак")
L.bag = S("Bag", "Сумка")
L.keyring = S("Keys", "Ключи")
L.bank = S("Bank", "Банк")
L.bankBag = S("Bank bag", "Банковская сумка")
L.sellGrey = S("Sell grey", "Продать серое")
L.sellGreyTip = S("Needs a vendor next to the bot.", "Нужен торговец рядом с ботом.")
L.bagsHint = S("Click: the chosen action. Right-click: menu. Drag: move.",
    "Щелчок - выбранное действие, правый щелчок - меню, перетаскивание - перенос.")
L.clickDoes = S("Click: %s", "Щелчок: %s")
L.openTrade = S("Open trade with %s", "Открыть обмен с %s")
L.tradeNear = S("Available next to the bot", "Доступно рядом с ботом")
L.tradeNote = S("The normal trade window opens. Put the bot's items in with the \"Give to me\" mode; gold goes in the trade window.",
    "Откроется обычное окно торговли. Вещи бота выкладываются щелчком в режиме «Передать мне», золото - полем в окне обмена.")
L.tradeIsOpen = S("Trade is open: click the bot's items.", "Обмен открыт: щёлкайте по вещам бота.")
L.bankNote = S("Available when the bot stands next to a banker.", "Доступно, когда бот стоит рядом с банкиром.")
L.bankOn = S("Banker nearby: the bank is shown below the bags.", "Банкир рядом: банк показан под сумками.")
L.confirmDestroy = S("Destroy %s?", "Выбросить %s?")
L.confirmSell = S("Sell %s?", "Продать %s?")

-- other tab (6.8)
L.cardBot = S("Bot", "Бот")
L.summonMe = S("Summon to me", "Призвать ко мне")
L.resetAI = S("Reset AI", "Сбросить ИИ")
L.maintDo = S("Maintain", "Обслужить")
L.autogear = S("Auto-gear", "Автоподбор снаряжения")
L.confirmAutogear = S("Run auto-gear for %s? Equipped items may be replaced.",
    "Запустить автоподбор снаряжения для %s? Надетые вещи могут быть заменены.")
L.maintNote = S("Repair, consumables, reagents, selling junk - one button (playerbots maintenance).",
    "Починка, расходники, реагенты, продажа хлама - одной кнопкой (команда playerbots maintenance).")
L.cardOutfits = S("Outfits", "Комплекты одежды")
L.outfitSave = S("+ Save equipped", "+ Сохранить надетое")
L.outfitName = S("Outfit name:", "Название комплекта:")
L.outfitNone = S("No outfits yet.", "Комплектов пока нет.")
L.outfitsFull = S("No free outfit slots", "Нет свободных мест для комплекта")
L.outfitNote = S("Click: wear. Right-click: rename or delete. Stored on the server.",
    "Щелчок - надеть, правый щелчок - переименовать или удалить. Хранятся на сервере.")
L.confirmOutfitDel = S("Delete outfit \"%s\"?", "Удалить комплект «%s»?")
L.cardLoot = S("Loot", "Добыча")
L.lootOn = S("Pick up loot", "Подбирать добычу")
L.lootAlways = S("Always loot:", "Подбирать всегда:")
L.lootAdd = S("+ item", "+ предмет")
L.lootAddPrompt = S("Item link (shift-click an item) or item id:", "Ссылка на предмет (Shift+щелчок по предмету) или номер предмета:")
L.lootDelTip = S("Click: remove from the list", "Щелчок - убрать из списка")
L.cardQuests = S("Quests", "Задания")
L.acceptAll = S("Accept all from NPC", "Принять все у NPC")
L.questDrop = S("Drop", "Бросить")
L.questNone = S("No quests.", "Заданий нет.")
L.questDone = S("complete", "выполнено")
L.confirmQuestDrop = S("Drop quest \"%s\"?", "Бросить задание «%s»?")
L.cardGroup = S("Party", "Отряд")
L.defaultMark = S("Default mark", "Метка по умолчанию")
L.allLogin = S("All: log in", "Всем: войти")
L.allLoginTip = S("Logs in up to 4 offline bots of your account.", "Вводит в игру до 4 ботов вашего аккаунта, которые не в игре.")
L.repair = S("Repair", "Починить")
L.repairTip = S("Needs a repair vendor next to the bot.", "Нужен ремонтник рядом с ботом.")
L.openItems = S("Open containers", "Открыть контейнеры")
L.openItemsTip = S("Opens lockboxes, clams and bags of loot in the bot's bags.",
    "Открывает сундучки, раковины и мешки с добычей в сумках бота.")
L.resetActions = S("Reset actions", "Сбросить действия")
L.resetActionsTip = S("Drops what the bot is doing right now (reset).", "Прерывает текущие действия бота (reset).")
L.talkNpc = S("Talk to NPC", "Поговорить с NPC")
L.talkNpcTip = S("The bot talks to your target (quest giver).", "Бот заговаривает с вашей целью (кто выдаёт задания).")
L.allLogout = S("All: log out", "Всем выйти")
L.confirmAllLogout = S("Log out every bot of yours in the group (%d)?", "Вывести из игры всех ваших ботов в группе (%d)?")
L.allMaint = S("All: maintain", "Всем: обслуживание")
L.allSellGrey = S("All: sell grey", "Всем: продать серое")
L.callFavs = S("Call favourites", "Позвать избранных")
L.callFavsTip = S("Invites your favourite bots (logging in those offline) until the party is full.",
    "Приглашает избранных ботов (кто не в игре - вводит) до полной группы.")
L.noFavs = S("No favourites to call", "Некого звать из избранных")
L.rollItem = S("Roll for item", "Кубик на предмет")
L.rollPrompt = S("Item link (shift-click an item) or item id: bots roll if it suits them.",
    "Ссылка на предмет (Shift+щелчок) или номер: боты бросят кубик, если он им подходит.")
L.disperse = S("Spread out", "Разбежаться")
L.disperseOff = S("Do not spread", "Не разбегаться")
L.disperseYd = S("%d yd", "%d м")
L.grindMode = S("Grind mode", "Режим фарма")
L.grindTip = S("Bots hunt enemies nearby on their own (grind); off = follow you.",
    "Боты сами бьют врагов вокруг (grind); выкл. - следовать за вами.")
L.autoRelease = S("Release dead bots", "Отпускать дух павших")
L.autoReleaseTip = S("A bot that dies releases its spirit at once (addon option).",
    "Павший бот сразу отпускает дух (настройка аддона).")

BINDING_HEADER_BOTTACTICS = L.title
BINDING_NAME_BOTTACTICS_TOGGLE = S("Open / close the party window", "Открыть / закрыть окно отряда")

-- ---------------------------------------------------------------- fallback catalogue (spec section 8)
local function Target(id, side, lvl, en, ru)
    return { id = id, side = side, lvl = lvl, label = S(en, ru) }
end

local function Cond(id, param, lvl, en, enPre, enUnit, ru, ruPre, ruUnit, default, min, max)
    return {
        id = id, param = param, lvl = lvl,
        label = S(en, ru), prefix = S(enPre, ruPre), unit = S(enUnit, ruUnit),
        default = default, min = min, max = max,
    }
end

BT.FALLBACK_CAT = {
    targets = {
        Target("self", "own", 0, "Bot itself", "Сам бот"),
        Target("ally", "own", 0, "Ally", "Союзник"),
        Target("tank", "own", 0, "Tank", "Танк"),
        Target("healer", "own", 10, "Healer", "Лекарь"),
        Target("leader", "own", 0, "You (leader)", "Вы (лидер)"),
        Target("foe_cur", "foe", 0, "Current target", "Текущая цель"),
        Target("foe_near", "foe", 0, "Nearest foe", "Ближайший"),
        Target("foe_me", "foe", 0, "Attacking me", "Бьёт меня"),
        Target("foe_healer", "foe", 20, "Attacking healer", "Бьёт лекаря"),
        Target("foe_skull", "foe", 0, "Skull mark", "Метка «череп»"),
        Target("foe_moon", "foe", 30, "Moon mark", "Метка «луна»"),
        Target("foe_boss", "foe", 40, "Boss or elite", "Босс или элитный"),
    },
    conds = {
        Cond("any", "none", 0, "any", "", "", "любой", "", ""),
        Cond("hp_lt", "num", 0, "HP below...", "HP <", "%", "здоровье ниже...", "здоровье <", "%", "30", 1, 100),
        Cond("hp_ge", "num", 0, "HP at least...", "HP >=", "%", "здоровье не ниже...", "здоровье >=", "%", "90", 1, 100),
        Cond("lowest", "none", 0, "lowest HP", "", "", "самый раненый", "", ""),
        Cond("mp_lt", "num", 0, "mana below...", "mana <", "%", "мана ниже...", "мана <", "%", "20", 1, 100),
        Cond("dead", "none", 0, "dead", "", "", "мёртв", "", ""),
        Cond("no_aura", "spell", 0, "missing aura...", "no", "", "нет эффекта...", "нет", ""),
        Cond("has_aura", "spell", 20, "has aura...", "has", "", "есть эффект...", "есть", ""),
        Cond("dispel", "dispel", 0, "dispellable...", "dispel:", "", "можно снять...", "снять:", "", "magic"),
        Cond("casting", "none", 0, "casting (interruptible)", "", "", "читает заклинание", "", ""),
        Cond("dist_gt", "num", 20, "farther than...", "farther than", "yd", "дальше...", "дальше", "ярд.", "20", 1, 100),
        Cond("near_ge", "num", 30, "enemies nearby at least...", "enemies >=", "", "врагов рядом не меньше...", "врагов рядом >=", "", "3", 1, 20),
        Cond("combat_gt", "num", 40, "combat longer than...", "combat >", "s", "бой длится дольше...", "бой дольше", "с", "30", 1, 600),
    },
    specials = {
        { id = "attack", side = "foe", label = S("Attack (switch target)", "Атаковать (сменить цель)"),
          desc = S("Switch current target; the class AI keeps hitting it", "Сменить текущую цель, дальше её бьёт классовый ИИ") },
        { id = "behind", side = "any", label = S("Stand behind tank", "Встать за танка"),
          desc = S("Move behind the tank and stay there", "Отойти за спину танку и держаться там") },
        { id = "follow", side = "any", label = S("Follow leader", "Следовать за лидером"),
          desc = S("Drop everything and run to you", "Бросить всё и бежать к вам") },
        { id = "wait", side = "any", label = S("Wait", "Ждать"),
          desc = S("Do nothing: blocks the rules below while true", "Ничего не делать: блокирует правила ниже, пока условие верно") },
    },
    itemcats = {
        { id = "potion", label = S("Potions", "Зелья") },
        { id = "elixir", label = S("Elixirs & flasks", "Эликсиры и настои") },
        { id = "food", label = S("Food, drink, bandages", "Еда, питьё, бинты") },
        { id = "enh", label = S("Oils, poisons, stones", "Масла, яды, точила") },
        { id = "misc", label = S("Other", "Прочее") },
    },
    dispels = {
        { id = "magic", label = S("Magic", "Магия") },
        { id = "curse", label = S("Curse", "Проклятие") },
        { id = "disease", label = S("Disease", "Болезнь") },
        { id = "poison", label = S("Poison", "Яд") },
    },
}

-- Icons for special actions and item categories (client side only; unknown ids get a question mark)
BT.SPECIAL_ICONS = {
    attack = "Interface\\Icons\\Ability_SteelMelee",
    behind = "Interface\\Icons\\Ability_Rogue_Ambush",
    follow = "Interface\\Icons\\Ability_Tracking",
    wait = "Interface\\Icons\\INV_Misc_PocketWatch_01",
    -- basic actions (abilities-mirroring-spec 2.3)
    melee = "Interface\\Icons\\INV_Sword_04",
    shoot = "Interface\\Icons\\Ability_Marksmanship",
    stop_attack = "Interface\\Icons\\Ability_Rogue_Feint",
    move_to = "Interface\\Icons\\Ability_Warrior_Charge",
    move_away = "Interface\\Icons\\Ability_Rogue_Sprint",
    stay = "Interface\\Icons\\Spell_Nature_Slow",
    cancel = "Interface\\Icons\\Spell_Holy_DispelMagic",
    pet_attack = "Interface\\Icons\\Ability_GhoulFrenzy",
    pet_follow = "Interface\\Icons\\Ability_Tracking",
    pet_stay = "Interface\\Icons\\Spell_Nature_TimeStop",
    drink = "Interface\\Icons\\INV_Drink_07",
    eat = "Interface\\Icons\\INV_Misc_Food_15",
}
BT.ITEMCAT_ICONS = {
    potion = "Interface\\Icons\\INV_Potion_54",
    elixir = "Interface\\Icons\\INV_Potion_97",
    food = "Interface\\Icons\\INV_Misc_Food_15",
    enh = "Interface\\Icons\\INV_Stone_WeightStone_07",
    misc = "Interface\\Icons\\INV_Misc_Bag_10",
}
BT.ICON_UNKNOWN = "Interface\\Icons\\INV_Misc_QuestionMark"
BT.ICON_ALL = "Interface\\Icons\\INV_Misc_Book_09"
BT.ICON_SPECIALS = "Interface\\Icons\\Ability_SteelMelee"
BT.ICON_LAUNCHER = "Interface\\Icons\\Ability_Warrior_BattleShout"
