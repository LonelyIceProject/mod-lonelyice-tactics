-- Bot tactics: "like a single-player RPG" - the bots mirror what their leader does
--.
--
-- C++ (TacticsMirror.cpp) watches the real leader and calls tactics.on_mirror(event, player, payload) on the
-- world thread, the same context as on_message (bot:questAccept / questReward / summonToOwner ... need it).
-- This file decides what the bots do:
--   quest_accept   bots take the same quest (playerbots' "accept quest" often did it already: "already" is fine)
--   quest_reward   bots that have the quest turn it in too: turnin_force completes the objectives first; the
--                  bot gives the required items it carries (fewer or none is fine, the quest still closes);
--                  the reward = best for the bot (reward=best) or the player's index (same)
--   quest_abandon  bots drop it
--   taxi_start     nothing (playerbots' TaxiAction flies the bots near the flight master); one bot says so
--   taxi_done      bots that stayed behind (far away / other map) are summoned (bot:summonToOwner)
--   teleport_done  hearthstone / portal / waystone: bots are summoned
--   vendor         bots near the vendor sell grey items and repair ("repair" chat command)
--   repair         bots near repair
--   trainer        bots near learn what their trainer (if it is theirs) teaches
--   gossip         option "talk": bots near talk to the NPC ("talk")
-- Every bot action goes to the leader's feed (addon: MIRRORED; ring of the last 20 in vars: MIRRORLOG) and a
-- few become party chat lines of the bots (bot:sayParty, one voice per event, errors per bot).
--
-- Settings (store): player key "mirror" on the LEADER guid = the player-level switches ("k=v;..." of the
-- keys below, only the ones that differ from the defaults are stored); per bot and leader
-- "l<leader>_mirror" (store.key) = the bot's opt-outs "k=0;..." (only =0 overrides, the reward mode is
-- player-level only).
-- Messages: MIRROR -> MIRRORSET; SETMIRROR <bot|0> <key> <0|1|best|same> -> ACK, MIRRORSET;
-- MIRRORLOG [<n>] -> MIRRORLOG. HELLO also gets MIRRORSET (protocol.helloHooks).
--   MIRRORSET <player kv k=v;...> <bots: bot,k=0,k=0;...> <server: enable=0|1,radius=N>
--   MIRRORED  <bot|0> <event> <0|1> <textEsc>          (bot 0 = the whole party)
--   MIRRORLOG <age_s,bot,event,0|1,textEsc;...>        (oldest first)
--
-- Two opt-outs need playerbots' own behaviour switched: quest=0 removes the non-combat strategy "quest"
-- (accepting / talk to quest giver), taxi=0 sets bot:setTaxiMirror(false) (C++ zeroes the "taxi" actions).
-- Both are re-applied on SETMIRROR, HELLO / PARTY and every mirror event (the taxi flag is not persistent).

local util = wow.include("util.lua")
local protocol = wow.include("protocol.lua")
local store = wow.include("store.lua")

local mirror = {}
local handlers = protocol.handlers
local send = protocol.send

-- ----------------------------------------------------------------------------- settings

-- Order = MIRRORSET order. bool = "0"/"1"; reward = "best"/"same". perBot = may be opted out per bot.
mirror.KEYS = {
    { id = "quest",        def = "1" },
    { id = "turnin",       def = "1" },
    { id = "turnin_force", def = "1" },
    { id = "abandon",      def = "1" },
    { id = "taxi",         def = "1" },
    { id = "taxi_learn",   def = "1" },   -- stored only: learning nodes is playerbots' "taxi" cheat (no binding)
    { id = "hearth",       def = "1" },
    { id = "vendor",       def = "1" },
    { id = "train",        def = "1" },
    { id = "talk",         def = "0" },
    { id = "chat",         def = "1" },
    { id = "reward",       def = "best", values = { best = true, same = true } },
}
local KEY = {}
for _, k in ipairs(mirror.KEYS) do
    KEY[k.id] = k
    if not k.values then
        k.values = { ["0"] = true, ["1"] = true }
        k.perBot = true
    end
end

mirror.LOG_MAX = 20            -- feed entries kept per leader (vars mirror_log_1..N)
mirror.LOG_TEXT_MAX = 160      -- bytes of one feed text (before escaping)
mirror.CHAT_VOICES = 1         -- bots that say the "good news" line of one event (errors: every bot, once)
mirror.RADIUS = 30             -- yards, when wow.mirrorConfig() is missing
mirror.REPAIR_GAP_MS = 10000   -- vendor + repair events of one visit: one "repair" per bot
mirror.QUEST_CMD_GAP_MS = 5000 -- "nc -quest" / "nc +quest" at most this often per bot (the command is queued)

local PLAYER_KEY = "mirror"

-- "k=v;k=v" -> { k = v } (known keys and values only)
function mirror.parseKv(text, sep)
    local t = {}
    if type(text) ~= "string" then return t end
    for part in text:gmatch("[^" .. (sep or ";") .. "]+") do
        local k, v = part:match("^([%l_]+)=([%w]+)$")
        local def = k and KEY[k]
        if def and def.values[v] then t[k] = v end
    end
    return t
end

-- Player-level settings (every key present).
function mirror.playerSettings(low)
    local stored = mirror.parseKv(wow.storeGet(low, PLAYER_KEY))
    local out = {}
    for _, k in ipairs(mirror.KEYS) do out[k.id] = stored[k.id] or k.def end
    return out
end

local function serializePlayer(s)
    local parts = {}
    for _, k in ipairs(mirror.KEYS) do
        if s[k.id] and s[k.id] ~= k.def then parts[#parts + 1] = k.id .. "=" .. s[k.id] end
    end
    return table.concat(parts, ";")
end

local function botStoreName(leader)
    return store.key(PLAYER_KEY, leader)
end

-- Opt-outs of a bot for one leader: { key = true } (only per-bot keys stored as =0).
function mirror.botOverrides(botLow, leader)
    local out = {}
    if not leader or leader <= 0 then return out end
    for k, v in pairs(mirror.parseKv(wow.storeGet(botLow, botStoreName(leader)))) do
        if v == "0" and KEY[k].perBot then out[k] = true end
    end
    return out
end

-- The row also carries "qoff=1": this module removed playerbots' "quest" strategy for the leader
-- (ensureBot); persistent so "nc +quest" comes back after a relog too. parseKv ignores it (not in KEYS).
local QOFF = "qoff=1"

function mirror.questOff(botLow, leader)
    if not leader or leader <= 0 then return false end
    local row = wow.storeGet(botLow, botStoreName(leader))
    if type(row) ~= "string" then return false end
    for part in row:gmatch("[^;]+") do
        if part == QOFF then return true end
    end
    return false
end

local function serializeOverrides(o, qoff)
    local parts = {}
    for _, k in ipairs(mirror.KEYS) do
        if o[k.id] then parts[#parts + 1] = k.id .. "=0" end
    end
    if qoff then parts[#parts + 1] = QOFF end
    return table.concat(parts, ";")
end

-- Writes the bot's row (opt-outs + qoff); erases it when empty. Returns true when stored.
local function writeBotRow(botLow, leader, o, qoff)
    local name = botStoreName(leader)
    local data = serializeOverrides(o, qoff)
    if data == "" then
        return wow.storeErase(botLow, name) or wow.storeGet(botLow, name) == nil
    end
    return wow.storeSet(botLow, name, data)
end

-- Is `key` on for the bot under this leader? (player switch on and no opt-out of the bot)
function mirror.opt(botLow, ownerLow, key)
    local s = mirror.playerSettings(ownerLow)
    if s[key] ~= "1" then return false end
    return not mirror.botOverrides(botLow, ownerLow)[key]
end

local function radius()
    local cfg = wow.mirrorConfig and wow.mirrorConfig()
    local r = type(cfg) == "table" and tonumber(cfg.radius)
    return (r and r > 0) and r or mirror.RADIUS
end

-- ----------------------------------------------------------------------------- texts

local TEXT = {
    took          = { en = "Took the quest: %s", ru = "Взял задание: %s" },
    took_fail     = { en = "Could not take %s: %s", ru = "Не взял %s: %s" },
    turned        = { en = "Turned in: %s", ru = "Сдал задание: %s" },
    turned_reward = { en = "Turned in: %s, reward %s", ru = "Сдал задание: %s, награда %s" },
    turn_fail     = { en = "Could not turn in %s: %s", ru = "Не сдал %s: %s" },
    not_complete  = { en = "Objectives not done: %s", ru = "Цели не выполнены: %s" },
    dropped       = { en = "Abandoned: %s", ru = "Бросил задание: %s" },
    flew          = { en = "Joined you after the flight", ru = "Догнал вас после перелёта" },
    came          = { en = "Came to you", ru = "Перенёсся к вам" },
    move_fail     = { en = "Did not follow: %s", ru = "Не последовал за вами: %s" },
    party_flies   = { en = "The party flies after you (%s)", ru = "Отряд летит за вами (%s)" },
    sold          = { en = "Sold junk: %s", ru = "Продал хлам: %s" },
    learned       = { en = "Learned at the trainer: %s", ru = "Выучил у наставника: %s" },
    sell_fail     = { en = "Did not sell junk: %s", ru = "Не продал хлам: %s" },
    no_vendor     = { en = "too far from the vendor", ru = "далеко от торговца" },
    -- reasons
    cannot_take   = { en = "not for this bot (level, class or chain)", ru = "не подходит (уровень, класс или цепочка)" },
    full_log      = { en = "quest log full", ru = "журнал заданий полон" },
    full          = { en = "bags full", ru = "сумки полны" },
    bags          = { en = "bags full", ru = "сумки полны" },
    bad_choice    = { en = "no such reward", ru = "нет такой награды" },
    not_taken     = { en = "not in the log", ru = "нет в журнале" },
    combat        = { en = "in combat", ru = "в бою" },
    dead          = { en = "dead", ru = "мёртв" },
    instance      = { en = "cannot enter the instance", ru = "нет доступа в подземелье" },
    owner_busy    = { en = "you are travelling", ru = "вы в пути" },
    failed        = { en = "failed", ru = "не получилось" },
    -- party chat lines of the bots (sayParty: no "|", <= 200 bytes)
    say_took      = { en = "Took the quest \"%s\".", ru = "Взял задание «%s»." },
    say_turned    = { en = "Turned in \"%s\".", ru = "Сдал «%s»." },
    say_full      = { en = "My bags are full, I can't take the reward for \"%s\".", ru = "Сумки полны, награду за «%s» не взять." },
    say_full_log  = { en = "My quest log is full.", ru = "Журнал заданий полон." },
    say_taxi      = { en = "Flying after you.", ru = "Лечу за вами." },
    say_came      = { en = "Right behind you.", ru = "Я с вами." },
    money_g       = { en = "g", ru = "з" },
    money_s       = { en = "s", ru = "с" },
    money_c       = { en = "c", ru = "м" },
}
mirror.TEXT = TEXT

local function fmt(code, lang, ...)
    local s = util.L(TEXT[code] or code, lang)
    local args = { ... }
    local i = 0
    return (s:gsub("%%s", function()
        i = i + 1
        return tostring(args[i] == nil and "?" or args[i])
    end))
end

local function reasonText(reason, lang)
    if TEXT[reason] then return util.L(TEXT[reason], lang) end
    return tostring(reason or "?")
end

function mirror.money(copper, lang)
    copper = math.floor(tonumber(copper) or 0)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. util.L(TEXT.money_g, lang) end
    if s > 0 then parts[#parts + 1] = s .. util.L(TEXT.money_s, lang) end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. util.L(TEXT.money_c, lang) end
    return table.concat(parts, " ")
end

-- Cut at a UTF-8 character boundary.
local function cut(s, max)
    s = tostring(s or "")
    if #s <= max then return s end
    local i = max
    while i > 0 do
        local b = s:byte(i + 1)
        if not b or b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    return s:sub(1, i)
end
mirror.cut = cut

-- ----------------------------------------------------------------------------- feed (MIRRORED / MIRRORLOG)

local function elapsed(at, now)
    local d = now - at
    if d < 0 then d = d + 4294967296 end
    return d
end

-- Appends to the leader's ring and sends MIRRORED. bot = low guid (0 = the party).
function mirror.record(owner, botLow, event, ok, text)
    text = cut(text, mirror.LOG_TEXT_MAX)
    local head = (tonumber(wow.getVar(owner, "mirror_log_head")) or 0) % mirror.LOG_MAX + 1
    local n = math.min(mirror.LOG_MAX, (tonumber(wow.getVar(owner, "mirror_log_n")) or 0) + 1)
    wow.setVar(owner, "mirror_log_" .. head, table.concat({ string.format("%d", wow.now()), string.format("%d", botLow or 0),
        event, ok and "1" or "0", util.esc(text) }, ","))
    wow.setVar(owner, "mirror_log_head", head)
    wow.setVar(owner, "mirror_log_n", n)
    send(owner, "MIRRORED", string.format("%d", botLow or 0), event, ok and "1" or "0", util.esc(text))
end

-- Entries oldest first: { at, bot, event, ok, textEsc } (at = wow.now() of the record).
function mirror.logEntries(owner)
    local out = {}
    local head = tonumber(wow.getVar(owner, "mirror_log_head")) or 0
    local n = tonumber(wow.getVar(owner, "mirror_log_n")) or 0
    for i = n - 1, 0, -1 do
        local idx = (head - 1 - i) % mirror.LOG_MAX + 1
        local e = wow.getVar(owner, "mirror_log_" .. idx)
        local at, bot, event, ok, textEsc = tostring(e or ""):match("^(%d+),(%d+),([%l_]+),([01]),(.*)$")
        if at then out[#out + 1] = { at = tonumber(at), bot = bot, event = event, ok = ok, textEsc = textEsc } end
    end
    return out
end

-- ----------------------------------------------------------------------------- per-event context

-- Owned bots of the leader, never the leader itself (a selfbot leader - the headless sim - is a bot too).
-- ownerLow() is the group leader for every bot of the group, so the alt bots of another real player of the
-- group (their master = that player) are skipped (spec 10.4: filter by masterLow).
local function botsOf(req)
    local out = {}
    local owned = protocol.ownedBots(req)
    if #owned == 0 then return out end
    local real = {}
    local members = req.player.group and req.player:group() or {}
    for i = 1, #members do
        local m = members[i]
        if not m:isBot() then real[m:lowGuid()] = true end
    end
    for _, bot in ipairs(owned) do
        local low = bot:lowGuid()
        local master = type(bot.masterLow) == "function" and tonumber(bot:masterLow()) or 0
        local other = master ~= 0 and master ~= req.low and real[master]
        if low ~= req.low and not other then out[#out + 1] = bot end
    end
    return out
end
mirror.botsOf = botsOf

local function newCtx(player)
    local locale = player:locale()
    local req = { player = player, low = player:lowGuid(), locale = locale, lang = util.lang(locale) }
    local ctx = { req = req, lang = req.lang, owner = req.low, settings = mirror.playerSettings(req.low),
                  radius = radius(), overrides = {}, voices = 0, now = wow.now() }
    ctx.bots = botsOf(req)
    return ctx
end

local function overridesOf(ctx, bot)
    local low = bot:lowGuid()
    local o = ctx.overrides[low]
    if not o then
        o = mirror.botOverrides(low, ctx.owner)
        ctx.overrides[low] = o
    end
    return o
end

local function on(ctx, bot, key)
    if ctx.settings[key] ~= "1" then return false end
    return not overridesOf(ctx, bot)[key]
end
mirror.on = on

local function near(ctx, bot)
    local d = bot:distance(ctx.req.player)
    return type(d) == "number" and d <= ctx.radius
end

-- One chat line of a bot. voice = true: "good news" of the event, only CHAT_VOICES bots say it.
local function say(ctx, bot, voice, code, arg)
    if not on(ctx, bot, "chat") or type(bot.sayParty) ~= "function" then return end
    if voice then
        if ctx.voices >= mirror.CHAT_VOICES then return end
        ctx.voices = ctx.voices + 1
    end
    local text = fmt(code, ctx.lang, arg and tostring(arg):gsub("|", "") or nil)
    bot:sayParty(cut(text, 200))
end

local function record(ctx, bot, event, ok, text)
    mirror.record(ctx.owner, bot and bot:lowGuid() or 0, event, ok, text)
end

local function status(bot, q)
    if type(bot.questStatus) ~= "function" then return nil end
    return bot:questStatus(q)
end

local function titleOf(bot, q)
    for _, e in ipairs(bot:quests() or {}) do
        if e.id == q and type(e.title) == "string" and e.title ~= "" then return e.title end
    end
    return "#" .. q
end

local function taken(st) return st == "incomplete" or st == "complete" end

-- per bot var: the bot had quest q in its log while mirrored (a later "rewarded" is this turn-in)
local function seenVar(q) return "mq_" .. string.format("%d", q) end

-- ----------------------------------------------------------------------------- reward choice (5.2)

local USAGE_RANK = { equip = 3, replace = 3, use = 2, bad_equip = 1 }

-- 0-based choice index of quest q for the bot: the player's index for mode "same" (when valid), else the
-- best: item usage (equip / replace > use > bad equip > rest), fits an equipment slot, item level, lowest index. 0 when the quest has no choice.
function mirror.reward(bot, q, mode, playerChoice)
    if type(wow.questRewards) ~= "function" then return 0 end
    local rewards, count = wow.questRewards(q)
    if type(rewards) ~= "table" or (tonumber(count) or 0) == 0 then return 0 end
    local choices = {}
    for _, r in ipairs(rewards) do
        if r.choice then choices[#choices + 1] = r end
    end
    if #choices == 0 then return 0 end
    playerChoice = tonumber(playerChoice)
    if mode == "same" and playerChoice and playerChoice >= 0 then
        for _, r in ipairs(choices) do
            if r.index == playerChoice then return playerChoice end
        end
    end
    local best, bestKey
    for i, r in ipairs(choices) do
        local entry = r.entry or r[1]
        local usage = type(bot.itemUsage) == "function" and bot:itemUsage(entry) or nil
        local fits = type(bot.itemFits) == "function" and bot:itemFits(entry) and 1 or 0
        local it = wow.item and wow.item(entry) or nil
        -- sell price would be the next key, but wow.item exports none (TacticsLuaApi ItemRaw)
        local key = { USAGE_RANK[usage or ""] or 0, fits, tonumber(it and it.itemLevel) or 0, -(r.index or (i - 1)) }
        local better = not bestKey
        if not better then
            for k = 1, #key do
                if key[k] ~= bestKey[k] then
                    better = key[k] > bestKey[k]
                    break
                end
            end
        end
        if better then best, bestKey = r, key end
    end
    return best.index or 0
end

local function itemName(entry, locale)
    local it = entry and wow.item and wow.item(entry, locale)
    if type(it) == "table" and type(it.name) == "string" and it.name ~= "" then return it.name end
    return entry and ("#" .. entry) or nil
end

local function rewardEntry(q, choice)
    if type(wow.questRewards) ~= "function" then return nil end
    local rewards, count = wow.questRewards(q)
    if type(rewards) ~= "table" or (tonumber(count) or 0) == 0 then return nil end
    for _, r in ipairs(rewards) do
        if r.choice and r.index == choice then return r.entry or r[1] end
    end
    return nil
end

-- ----------------------------------------------------------------------------- playerbots switches

-- quest=0 -> "nc -quest"; back to "nc +quest" only when this module removed it (or `force`, SETMIRROR).
-- taxi -> bot:setTaxiMirror (runtime flag, not persistent).
function mirror.ensureBot(ctx, bot, force)
    local low = bot:lowGuid()
    if type(bot.setTaxiMirror) == "function" then bot:setTaxiMirror(on(ctx, bot, "taxi")) end
    if type(bot.strategies) ~= "function" then return end
    local list = bot:strategies("nc")
    if type(list) ~= "table" then return end
    local has = false
    for i = 1, #list do
        if list[i] == "quest" then has = true break end
    end
    local want = on(ctx, bot, "quest")
    if has == want then return end
    local qoff = mirror.questOff(low, ctx.owner)   -- persistent marker in the bot's row (survives a relog)
    if want and not force and not qoff then return end
    local at = wow.getVar(low, "mirror_qcmd_at")
    if at and wow.getVar(low, "mirror_qcmd") == (want and 1 or 0) and elapsed(at, ctx.now) < mirror.QUEST_CMD_GAP_MS then
        return
    end
    local ok = bot:command(want and "nc +quest" or "nc -quest")
    if ok then
        wow.setVar(low, "mirror_qcmd", want and 1 or 0)
        wow.setVar(low, "mirror_qcmd_at", ctx.now)
        if qoff ~= (not want) then writeBotRow(low, ctx.owner, overridesOf(ctx, bot), not want) end
    end
end

local function ensureAll(ctx, force)
    for _, bot in ipairs(ctx.bots) do mirror.ensureBot(ctx, bot, force) end
end

-- ----------------------------------------------------------------------------- events

local EVENTS = {}
mirror.EVENTS = EVENTS

local function giverOf(p) return protocol.guidHex(p.giver) end

EVENTS.quest_accept = function(ctx, p)
    local q = util.toid(p.quest)
    if not q then return end
    for _, bot in ipairs(ctx.bots) do
        if on(ctx, bot, "quest") then
            local st = status(bot, q)
            local ok, reason
            if taken(st) then
                ok = true
            elseif st == "rewarded" or st == nil then
                ok = nil   -- done long ago / no binding: nothing to say
            else
                -- a failed copy is still in the log (questAccept would answer "already"): drop it, take it anew
                local fresh = true
                if st == "failed" then
                    fresh = type(bot.dropQuest) == "function" and bot:dropQuest(q) and true or false
                end
                if fresh then
                    ok, reason = bot:questAccept(q, giverOf(p))
                    if not ok and reason == "already" then ok = taken(status(bot, q)) or st ~= "failed" or nil end
                end
            end
            if ok then
                local title = titleOf(bot, q)
                wow.setVar(bot:lowGuid(), seenVar(q), cut(title, 120))   -- the title for a later "turned in"
                record(ctx, bot, "quest_accept", true, fmt("took", ctx.lang, title))
                say(ctx, bot, true, "say_took", title)
            elseif ok == false then
                record(ctx, bot, "quest_accept", false, fmt("took_fail", ctx.lang, "#" .. q, reasonText(reason, ctx.lang)))
                if reason == "full_log" then say(ctx, bot, false, "say_full_log") end
            end
        end
    end
end

EVENTS.quest_reward = function(ctx, p)
    local q = util.toid(p.quest)
    if not q then return end
    local playerChoice = tonumber(p.choice)
    for _, bot in ipairs(ctx.bots) do
        if on(ctx, bot, "turnin") then
            local low = bot:lowGuid()
            local st = status(bot, q)
            local seen = wow.getVar(low, seenVar(q))
            local title = taken(st) and titleOf(bot, q) or (type(seen) == "string" and seen) or ("#" .. q)
            local proceed = taken(st)
            if st == "rewarded" and seen then
                -- playerbots' "turn in query quest" was faster (spec 10.5)
                record(ctx, bot, "quest_reward", true, fmt("turned", ctx.lang, title))
                say(ctx, bot, true, "say_turned", title)
                wow.setVar(low, seenVar(q), nil)
            elseif st == "incomplete" then
                if on(ctx, bot, "turnin_force") then
                    local ok, reason = bot:questComplete(q)
                    if not ok and reason ~= "already" then
                        proceed = false
                        record(ctx, bot, "quest_reward", false, fmt("turn_fail", ctx.lang, title, reasonText(reason, ctx.lang)))
                    end
                else
                    proceed = false
                    record(ctx, bot, "quest_reward", false, fmt("not_complete", ctx.lang, title))
                end
            end
            if proceed then
                local choice = mirror.reward(bot, q, ctx.settings.reward, playerChoice)
                local ok, reason = bot:questReward(q, giverOf(p), choice)
                if ok or reason == "already" then
                    wow.setVar(low, seenVar(q), nil)
                    local entry = ok and rewardEntry(q, choice) or nil
                    if entry then
                        record(ctx, bot, "quest_reward", true, fmt("turned_reward", ctx.lang, title, itemName(entry, ctx.req.locale)))
                    else
                        record(ctx, bot, "quest_reward", true, fmt("turned", ctx.lang, title))
                    end
                    say(ctx, bot, true, "say_turned", title)
                else
                    record(ctx, bot, "quest_reward", false, fmt("turn_fail", ctx.lang, title, reasonText(reason, ctx.lang)))
                    if reason == "full" then say(ctx, bot, false, "say_full", title) end
                end
            end
        end
    end
end

EVENTS.quest_abandon = function(ctx, p)
    local q = util.toid(p.quest)
    if not q then return end
    for _, bot in ipairs(ctx.bots) do
        if on(ctx, bot, "abandon") then
            local st = status(bot, q)
            if taken(st) or st == "failed" then
                local title = titleOf(bot, q)
                local ok, reason = bot:dropQuest(q)
                wow.setVar(bot:lowGuid(), seenVar(q), nil)
                if ok then
                    record(ctx, bot, "quest_abandon", true, fmt("dropped", ctx.lang, title))
                else
                    record(ctx, bot, "quest_abandon", false, fmt("turn_fail", ctx.lang, title, reasonText(reason, ctx.lang)))
                end
            end
        end
    end
end

EVENTS.taxi_start = function(ctx, p)
    local n, speaker = 0, nil
    for _, bot in ipairs(ctx.bots) do
        if on(ctx, bot, "taxi") and near(ctx, bot) then
            n = n + 1
            speaker = speaker or bot
        end
    end
    if n > 0 then
        record(ctx, nil, "taxi_start", true, fmt("party_flies", ctx.lang, n))
        say(ctx, speaker, true, "say_taxi")
    end
end

-- Bots with `key` on that are far from the leader (or on another map) are summoned.
local function follow(ctx, key, event, okCode)
    for _, bot in ipairs(ctx.bots) do
        if on(ctx, bot, key) and not near(ctx, bot) then
            local ok, reason = bot:summonToOwner()
            if ok then
                record(ctx, bot, event, true, fmt(okCode, ctx.lang))
                say(ctx, bot, true, "say_came")
            elseif reason ~= "already" and reason ~= "flight" then
                record(ctx, bot, event, false, fmt("move_fail", ctx.lang, reasonText(reason, ctx.lang)))
            end
        end
    end
end

EVENTS.taxi_done = function(ctx, p) follow(ctx, "taxi", "taxi_done", "flew") end
EVENTS.teleport_done = function(ctx, p) follow(ctx, "hearth", "teleport_done", "came") end

local function repair(ctx, bot)
    local low = bot:lowGuid()
    local at = wow.getVar(low, "mirror_repair_at")
    if at and elapsed(at, ctx.now) < mirror.REPAIR_GAP_MS then return end
    wow.setVar(low, "mirror_repair_at", ctx.now)
    protocol.runCommand(bot, "repair")
end

EVENTS.vendor = function(ctx, p)
    for _, bot in ipairs(ctx.bots) do
        if on(ctx, bot, "vendor") and near(ctx, bot) then
            -- the bot must stand at the vendor itself (FindVendor: interaction distance); a bot in the radius
            -- but farther away gets a feed line instead of a silent nothing
            local ok, why, count, money = bot:sellGrey()
            count = tonumber(count) or 0
            if ok and count > 0 then
                record(ctx, bot, "vendor", true, fmt("sold", ctx.lang, count .. ", +" .. mirror.money(money, ctx.lang)))
            elseif not ok and why and why ~= "" then
                record(ctx, bot, "vendor", false, fmt("sell_fail", ctx.lang, reasonText(why, ctx.lang)))
            end
            repair(ctx, bot)
        end
    end
end

EVENTS.repair = function(ctx, p)
    for _, bot in ipairs(ctx.bots) do
        if on(ctx, bot, "vendor") and near(ctx, bot) then repair(ctx, bot) end
    end
end

EVENTS.trainer = function(ctx, p)
    for _, bot in ipairs(ctx.bots) do
        if on(ctx, bot, "train") and near(ctx, bot) then
            local ok, _, learned, spent = bot:trainerLearnAll()
            learned = tonumber(learned) or 0
            if ok and learned > 0 then
                record(ctx, bot, "trainer", true, fmt("learned", ctx.lang, learned .. ", -" .. mirror.money(spent, ctx.lang)))
            end
        end
    end
end

EVENTS.gossip = function(ctx, p)
    for _, bot in ipairs(ctx.bots) do
        if on(ctx, bot, "talk") and near(ctx, bot) then protocol.runCommand(bot, "talk") end
    end
end

-- "k=v;..." payload of C++ (values are numbers / GUID text, never escaped).
function mirror.parsePayload(s)
    local t = {}
    for part in tostring(s or ""):gmatch("[^;]+") do
        local k, v = part:match("^([%l_]+)=(.*)$")
        if k then t[k] = v end
    end
    return t
end

-- tactics.on_mirror(event, player, payload): world thread.
function mirror.on_event(event, player, payload)
    local h = type(event) == "string" and EVENTS[event]
    if not h or not player then return end
    local ok, err = pcall(function()
        local ctx = newCtx(player)
        if #ctx.bots == 0 then return end
        ensureAll(ctx, false)
        h(ctx, mirror.parsePayload(payload))
    end)
    if not ok then
        err = tostring(err)
        if err:find("instruction limit", 1, true) then error(err, 0) end
        wow.error("mirror " .. event .. ": " .. err)
    end
end

-- ----------------------------------------------------------------------------- messages

local function sendSet(req)
    local s = mirror.playerSettings(req.low)
    local kv = {}
    for _, k in ipairs(mirror.KEYS) do kv[#kv + 1] = k.id .. "=" .. s[k.id] end
    local botsOut = {}
    for _, bot in ipairs(botsOf(req)) do
        local low = bot:lowGuid()
        local o = mirror.botOverrides(low, req.low)
        local row = { string.format("%d", low) }
        for _, k in ipairs(mirror.KEYS) do
            if o[k.id] then row[#row + 1] = k.id .. "=0" end
        end
        if #row > 1 then botsOut[#botsOut + 1] = table.concat(row, ",") end
    end
    local cfg = wow.mirrorConfig and wow.mirrorConfig() or nil
    local enable = (type(cfg) ~= "table" or cfg.enable ~= false) and "1" or "0"
    send(req.low, "MIRRORSET", table.concat(kv, ";"), table.concat(botsOut, ";"),
        "enable=" .. enable .. ",radius=" .. string.format("%d", radius()))
end
mirror.sendSet = sendSet

-- ctx for the playerbots switches from a message request
local function reqCtx(req)
    return { req = req, lang = req.lang, owner = req.low, settings = mirror.playerSettings(req.low), radius = radius(),
             overrides = {}, voices = 0, now = wow.now(), bots = botsOf(req) }
end

handlers.MIRROR = function(req, f)
    sendSet(req)
end

-- SETMIRROR <bot|0> <key> <value>
handlers.SETMIRROR = function(req, f)
    local op = "SETMIRROR"
    local key, value = f[3] or "", f[4] or ""
    local def = KEY[key]
    if f[2] == "0" then
        if not def then return protocol.ack(req, "0", op, "bad_op") end
        if not def.values[value] then return protocol.ack(req, "0", op, "bad_value", 0) end
        local s = mirror.playerSettings(req.low)
        s[key] = value
        local data = serializePlayer(s)
        local okStore
        if data == "" then
            okStore = wow.storeErase(req.low, PLAYER_KEY) or wow.storeGet(req.low, PLAYER_KEY) == nil
        else
            okStore = wow.storeSet(req.low, PLAYER_KEY, data)
        end
        if not okStore then return protocol.ack(req, "0", op, "store_failed") end
        protocol.ack(req, "0", op, "ok")
        ensureAll(reqCtx(req), true)
        return sendSet(req)
    end
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    if not def or not def.perBot then return protocol.ack(req, low, op, "bad_op") end
    if value ~= "0" and value ~= "1" then return protocol.ack(req, low, op, "bad_value", 0) end
    local o = mirror.botOverrides(low, req.low)
    o[key] = (value == "0") or nil
    if not writeBotRow(low, req.low, o, mirror.questOff(low, req.low)) then return protocol.ack(req, low, op, "store_failed") end
    protocol.ack(req, low, op, "ok")
    mirror.ensureBot(reqCtx(req), bot, true)
    sendSet(req)
end

-- MIRRORLOG [<n>] -> MIRRORLOG <age_s,bot,event,ok,textEsc;...> (the last n, oldest first)
handlers.MIRRORLOG = function(req, f)
    local n = util.toint(f[2]) or mirror.LOG_MAX
    n = math.max(0, math.min(n, mirror.LOG_MAX))
    local entries = mirror.logEntries(req.low)
    local now = wow.now()
    local out = {}
    for i = math.max(1, #entries - n + 1), #entries do
        local e = entries[i]
        out[#out + 1] = table.concat({ string.format("%d", math.floor(elapsed(e.at, now) / 1000)), e.bot, e.event, e.ok,
            e.textEsc }, ",")
    end
    send(req.low, "MIRRORLOG", table.concat(out, ";"))
end

-- HELLO: MIRRORSET after the other party window data; HELLO / PARTY: the playerbots switches.
protocol.helloHooks[#protocol.helloHooks + 1] = function(req)
    sendSet(req)
    ensureAll(reqCtx(req), false)
end
protocol.partyHooks[#protocol.partyHooks + 1] = function(req)
    ensureAll(reqCtx(req), false)
end

if type(tactics) == "table" then tactics.on_mirror = mirror.on_event end

return mirror
