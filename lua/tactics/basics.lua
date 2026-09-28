-- Bot tactics: basic actions that let rules replace the class AI (abilities-mirroring-spec 2.3).
-- Registers its specials and the "manual rotation" conditions in the catalogue (catalog.extend) and
-- exports the builders (actions.lua merges basics.actions; the checks live in conditions.lua).
-- New C++ verbs (spec section 10.1): melee, shoot, stopattack, cancel, pet, petcast, command.
-- Two rule kinds carry a spell in x like "spell": a=cancel,x=<aura spell> and a=petspell,x=<pet spell>.
-- Leaf module: includes util / config / catalog only (actions.lua and conditions.lua include this file).
--
-- Every C++ query of this file goes through `has(obj, name)`: a server without the WP1 bindings makes the
-- rule not apply (nil) instead of raising in evaluate.

local config = wow.include("config.lua")
local catalog = wow.include("catalog.lua")

local basics = {}

basics.AWAY_DIST = config.AWAY_DIST or 12      -- move_away: yards from the unit
basics.MOVE_TO_DIST = 2                        -- move_to: stop this far from the unit
basics.MOVE_TO_SKIP = 3                        -- move_to: nothing to do closer than this
basics.CENTROID_PULL = 0.3                     -- move_away: pull towards the group (as the AI position intent)
basics.PET_NEAR = 8                            -- pet_follow: an idle pet this close is already "with me"
basics.DRINK_GAP_MS = 15000                    -- drink: one command per this long (the build has no feedback)

-- Auto-repeat spells of the "shoot" special, in preference order: Auto Shot (hunter), Shoot (wand),
-- Shoot (bow / gun / crossbow of warriors and rogues), Throw.
basics.SHOOT_SPELLS = { 75, 5019, 3018, 2764 }

local AURA_MOD_REGEN = 20                      -- food buff (SPELL_AURA_MOD_REGEN)
local FOOD_SUBCLASS = 5                        -- consumable "Food & Drink"

-- ----------------------------------------------------------------------------- catalogue

catalog.extend({
    specials = {
        { id = "attack", side = "foe",
          label = { en = "Switch target (AI / rules take over)", ru = "Сменить цель (дальше - ИИ/правила)" },
          desc = { en = "Only switches the current target; hitting it is up to the class AI or your rules",
                   ru = "Только меняет текущую цель; бить её будет классовый ИИ или ваши правила" } },
        { id = "melee", side = "foe",
          label = { en = "Melee attack", ru = "Бить в ближнем бою" },
          desc = { en = "Run to the target and keep auto-attacking it. Holds the tick while the rule is true: put it below your abilities",
                   ru = "Подойти к цели и бить автоатакой. Занимает ход, пока верно условие: ставьте ниже умений" } },
        { id = "shoot", side = "foe",
          label = { en = "Shoot (auto shot, wand)", ru = "Стрелять (автовыстрел, жезл)" },
          desc = { en = "Auto Shot, wand or thrown weapon on the target. Holds the tick while the rule is true: put it below your abilities",
                   ru = "Автовыстрел, жезл или метательное оружие по цели. Занимает ход, пока верно условие: ставьте ниже умений" } },
        { id = "stop_attack", side = "any",
          label = { en = "Stop attacking", ru = "Прекратить атаку" },
          desc = { en = "Stop auto-attack and shooting, clear the target",
                   ru = "Остановить автоатаку и стрельбу, сбросить цель" } },
        { id = "move_to", side = "any",
          label = { en = "Move to target", ru = "Подойти к цели" },
          desc = { en = "Walk up to the rule's target", ru = "Подойти вплотную к цели правила" } },
        { id = "move_away", side = "any",
          label = { en = "Move away", ru = "Отойти от цели" },
          desc = { en = "Step about 12 yards away from the target, towards the group",
                   ru = "Отойти примерно на 12 ярдов от цели, в сторону группы" } },
        { id = "stay", side = "any",
          label = { en = "Hold position", ru = "Стоять на месте" },
          desc = { en = "Stop moving", ru = "Остановиться" } },
        { id = "cancel", side = "own",
          label = { en = "Cancel own aura...", ru = "Снять с себя эффект…" },
          desc = { en = "Remove one of the bot's own effects (form, stance, buff)",
                   ru = "Снять с бота его эффект (облик, стойку, бафф)" } },
        { id = "pet_attack", side = "foe",
          label = { en = "Pet: attack", ru = "Питомец: атаковать" },
          desc = { en = "Send the pet at the target", ru = "Натравить питомца на цель" } },
        { id = "pet_follow", side = "any",
          label = { en = "Pet: follow", ru = "Питомец: ко мне" },
          desc = { en = "Call the pet back", ru = "Отозвать питомца к боту" } },
        { id = "pet_stay", side = "any",
          label = { en = "Pet: stay", ru = "Питомец: стоять" },
          desc = { en = "The pet stops where it is", ru = "Питомец останавливается на месте" } },
        { id = "drink", side = "own",
          label = { en = "Drink", ru = "Попить" },
          desc = { en = "Sit down and drink (out of combat)", ru = "Сесть и попить (вне боя)" } },
        { id = "eat", side = "own",
          label = { en = "Eat", ru = "Поесть" },
          desc = { en = "Eat the best food from the bags (out of combat)", ru = "Съесть лучшую еду из сумок (вне боя)" } },
    },
    conditions = {
        { id = "attacking", param = "none", lvl = 0,
          label = { en = "I'm hitting it (auto attack)", ru = "я бью её (автоатака)" },
          prefix = { en = "I hit it", ru = "бью её" } },
        { id = "in_melee", param = "none", lvl = 0,
          label = { en = "in my melee range", ru = "в зоне ближнего боя" },
          prefix = { en = "in melee", ru = "вплотную" } },
        { id = "has_pet", param = "none", lvl = 0,
          label = { en = "I have a pet", ru = "есть питомец" }, prefix = { en = "have pet", ru = "есть питомец" } },
        { id = "pet_hp_lt", param = "num", lvl = 0, default = 40, min = 1, max = 100,
          label = { en = "pet's HP below...", ru = "здоровье питомца ниже…" },
          prefix = { en = "pet HP <", ru = "питомец <" }, unit = { en = "%", ru = "%" } },
        { id = "power_ge", param = "num", lvl = 0, default = 50, min = 1, max = 100,
          label = { en = "my resource at least...", ru = "мой ресурс не ниже…" },
          prefix = { en = "resource ≥", ru = "ресурс ≥" }, unit = { en = "%", ru = "%" } },
        { id = "power_lt", param = "num", lvl = 0, default = 30, min = 1, max = 100,
          label = { en = "my resource below...", ru = "мой ресурс ниже…" },
          prefix = { en = "resource <", ru = "ресурс <" }, unit = { en = "%", ru = "%" } },
        { id = "cd_ready", param = "spell", lvl = 0,
          label = { en = "ability ready...", ru = "умение готово…" }, prefix = { en = "ready:", ru = "готово:" } },
        { id = "stance_is", param = "spell", lvl = 0,
          label = { en = "stance / form is...", ru = "стойка / облик…" }, prefix = { en = "in", ru = "в" } },
        { id = "autoshooting", param = "none", lvl = 0,
          label = { en = "I'm auto-shooting", ru = "веду автовыстрел" },
          prefix = { en = "auto-shooting", ru = "автовыстрел" } },
    },
})

-- ----------------------------------------------------------------------------- helpers

-- obj:name(...) when the binding exists (older servers: nil).
local function has(obj, name)
    return obj ~= nil and type(obj[name]) == "function"
end
basics.has = has

function basics.knows(bot, id)
    if has(bot, "knows") then return bot:knows(id) == true end
    return (bot:highestRank(id) or 0) > 0
end

-- The bot's pet handle when it exists and lives, else nil.
function basics.pet(bot)
    if not has(bot, "pet") then return nil end
    local pet = bot:pet()
    if pet and pet:valid() and pet:isAlive() then return pet end
    return nil
end

-- Hitting u with auto attack?
function basics.isAttacking(bot, u)
    return u ~= nil and has(bot, "isAttacking") and bot:isAttacking(u) == true
end

-- Running auto-repeat spell id (0 = none), target hex.
function basics.autoRepeat(bot)
    if not has(bot, "autoRepeat") then return 0 end
    local id, target = bot:autoRepeat()
    return id or 0, target
end

local function hostileTarget(env, u)
    return u:guid() ~= env.guid and u:isAlive() and u:isHostileTo(env.bot)
end

-- First rank of a spell (static, cached per state).
local firstRank = {}
function basics.firstOf(id)
    local f = firstRank[id]
    if f == nil then
        local s = wow.spell(id)
        f = (s and s.first and s.first > 0) and s.first or id
        firstRank[id] = f
    end
    return f
end

-- The pet's known rank of chain `first` (rule x), or nil. petSpells = { {id, active, autocast}, ... }.
function basics.petRank(bot, first)
    if not has(bot, "petSpells") then return nil end
    local list = bot:petSpells() or {}
    local best
    for i = 1, #list do
        local id = list[i].id
        if id and (id == first or basics.firstOf(id) == first) and (not best or id > best) then best = id end
    end
    return best
end

-- Auto-repeat spell for "shoot": the first known one the bot can cast now, else the first known one.
function basics.shootSpell(bot, u)
    local firstKnown
    for _, id in ipairs(basics.SHOOT_SPELLS) do
        if basics.knows(bot, id) then
            firstKnown = firstKnown or id
            if u and has(bot, "canCast") then
                local ok = bot:canCast(id, u)
                if ok then return id end
            end
        end
    end
    return firstKnown
end

-- Food from the bags (item class 0 subclass 5 whose use spell is a food buff), best item level first.
function basics.bestFood(bot)
    local level = bot:level() or 0
    local best, bestLevel
    local bag = bot:items() or {}
    for i = 1, #bag do
        local it = wow.item(bag[i].entry)
        if it and it.class == 0 and it.subclass == FOOD_SUBCLASS and (it.reqLevel or 0) <= level then
            local sid = it.useSpells and it.useSpells[1]
            local s = sid and wow.spell(sid)
            local food = false
            for k = 1, 3 do
                if s and s.auras and s.auras[k] == AURA_MOD_REGEN then food = true end
            end
            if food and not bot:hasAura(sid) then
                local lvl = it.itemLevel or 0
                if not best or lvl > bestLevel then best, bestLevel = it.entry, lvl end
            end
        end
    end
    return best
end

local function centroid(env)
    local group = env:group()
    local sx, sy, n = 0, 0, 0
    for i = 1, #group do
        local m = group[i]
        if m:isAlive() and m:guid() ~= env.guid then
            local x, y = m:position()
            if x then sx, sy, n = sx + x, sy + y, n + 1 end
        end
    end
    if n == 0 then return nil end
    return sx / n, sy / n
end

-- ----------------------------------------------------------------------------- builders

local A = {}
basics.actions = A

-- Hold auto attack on the target; C++ walks into melee range first ("reach") and reports "already" while
-- the bot keeps hitting it (a success: the rule holds the tick).
A.melee = function(env, u, rule)
    if not hostileTarget(env, u) then return nil end
    return { verb = "melee", target = u:guid(), tag = "melee" }
end

A.shoot = function(env, u, rule)
    if not hostileTarget(env, u) then return nil end
    local spell = basics.shootSpell(env.bot, u)
    if not spell then return nil end
    return { verb = "shoot", target = u:guid(), spell = spell, tag = "shoot" }
end

A.stop_attack = function(env, u, rule)
    local bot = env.bot
    local v = bot:victim()
    local attacking = v ~= nil and basics.isAttacking(bot, v)
    if not attacking and basics.autoRepeat(bot) == 0 then return nil end
    return { verb = "stopattack", tag = "stop_attack" }
end

A.move_to = function(env, u, rule)
    if u:guid() == env.guid then return nil end
    local bot = env.bot
    local d = bot:distance(u)
    if not d or d < basics.MOVE_TO_SKIP then return nil end
    local bx, by = bot:position()
    local ux, uy, uz = u:position()
    if not bx or not ux then return nil end
    local dx, dy = ux - bx, uy - by
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.1 then return nil end
    return { verb = "move", x = ux - dx / len * basics.MOVE_TO_DIST, y = uy - dy / len * basics.MOVE_TO_DIST, z = uz,
             tag = "move_to" }
end

A.move_away = function(env, u, rule)
    if u:guid() == env.guid then return nil end
    local bot = env.bot
    local d = bot:distance(u)
    if not d or d >= basics.AWAY_DIST then return nil end
    local bx, by, bz = bot:position()
    local ux, uy = u:position()
    if not bx or not ux then return nil end
    local dx, dy = bx - ux, by - uy
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.1 then
        local _, _, _, o = bot:position()
        dx, dy, len = -math.cos(o or 0), -math.sin(o or 0), 1
    end
    local px, py = ux + dx / len * basics.AWAY_DIST, uy + dy / len * basics.AWAY_DIST
    local cx, cy = centroid(env)
    if cx then px, py = px + (cx - px) * basics.CENTROID_PULL, py + (cy - py) * basics.CENTROID_PULL end
    return { verb = "move", x = px, y = py, z = bz, tag = "move_away" }
end

A.stay = function(env, u, rule)
    if not env.bot:isMoving() then return nil end
    return { verb = "stop", tag = "stay" }
end

-- a=cancel,x=<spell>: only while the bot has that aura (any rank).
A.cancel = function(env, u, rule)
    if not rule.x or not env.bot:hasAura(rule.x) then return nil end
    return { verb = "cancel", spell = rule.x, tag = "cancel:" .. rule.x }
end

A.pet_attack = function(env, u, rule)
    if not hostileTarget(env, u) then return nil end
    local pet = basics.pet(env.bot)
    if not pet then return nil end
    local v = pet:victim()
    if v and v:guid() == u:guid() then return nil end
    return { verb = "pet", cmd = "attack", target = u:guid(), tag = "pet_attack" }
end

A.pet_follow = function(env, u, rule)
    local bot = env.bot
    local pet = basics.pet(bot)
    if not pet then return nil end
    if not pet:victim() then
        local d = pet:distance(bot)
        if d and d <= basics.PET_NEAR then return nil end
    end
    return { verb = "pet", cmd = "follow", tag = "pet_follow" }
end

A.pet_stay = function(env, u, rule)
    local pet = basics.pet(env.bot)
    if not pet or (not pet:victim() and not pet:isMoving()) then return nil end
    return { verb = "pet", cmd = "stay", tag = "pet_stay" }
end

-- a=petspell,x=<first rank>: the pet's known rank on the rule unit.
A.petspell = function(env, u, rule)
    local bot = env.bot
    if not rule.x or not basics.pet(bot) then return nil end
    local rank = basics.petRank(bot, rule.x)
    if not rank then return nil end
    return { verb = "petcast", spell = rank, target = u:guid(), tag = "petspell:" .. rule.x }
end

-- "drink" chat command (playerbots DrinkAction). Rate-limited per bot by the outcome, not by the offer: the
-- gap starts when a "command" decision (only drink uses that verb) actually ran ok - ctx.last of the next
-- tick - so an offer that lost to a higher candidate or was refused is offered again at once.
A.drink = function(env, u, rule)
    local bot = env.bot
    if bot:manaPct() == nil then return nil end
    local low = env.low or bot:lowGuid()
    local ctx = env.ctx or {}
    local now = ctx.now or wow.now()
    local last = ctx.last
    if type(last) == "table" and last.verb == "command" and last.ok then
        wow.setVar(low, "bas_drink_at", tonumber(last.at) or now)
    end
    local at = tonumber(wow.getVar(low, "bas_drink_at"))
    if at and now - at >= 0 and now - at < basics.DRINK_GAP_MS then return nil end
    return { verb = "command", text = "drink", tag = "drink" }
end

-- playerbots has no "eat" command: use the best food of the bags.
A.eat = function(env, u, rule)
    local bot = env.bot
    local entry = basics.bestFood(bot)
    if not entry then return nil end
    local ok = bot:canUse(entry, bot)
    if not ok then return nil end
    return { verb = "use", item = entry, target = bot:guid(), tag = "eat" }
end

return basics
