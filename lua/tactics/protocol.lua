-- Bot tactics: addon protocol (spec section 5). C++ only moves reassembled payload strings; message
-- types, fields and replies are defined here. To add a message: add a function to `handlers` below
-- (client -> server) and teach the addon about it.
--
-- Payload = TYPE "\t" field "\t" field ...; text fields escaped with util.esc (spec 5.2).
--
-- Party window modules (inventory.lua, bots.lua, ...; party-window-spec 5.9) include this file and add
-- their own `protocol.handlers.X`; they share the helpers exported below (ack, ownedBot, ownedBots,
-- sendParty, runCommand, ...). This file must not include them (no include cycles).

local util = wow.include("util.lua")
local config = wow.include("config.lua")
local catalog = wow.include("catalog.lua")
local rules = wow.include("rules.lua")
local spellbook = wow.include("spellbook.lua")
local store = wow.include("store.lua")

local protocol = {}
local handlers = {}
protocol.handlers = handlers

-- Implemented ids (for CAT). Loaded lazily to avoid an include cycle with interpreter.lua.
local impl

local function implementations()
    if not impl then
        impl = {
            targets = wow.include("targets.lua"),
            conditions = wow.include("conditions.lua"),
            actions = wow.include("actions.lua"),
        }
    end
    return impl
end

-- ----------------------------------------------------------------------------- helpers

local function send(playerLow, ...)
    local payload = table.concat({ ... }, "\t")
    if not wow.send(playerLow, payload) then
        wow.warn("send failed (" .. #payload .. " bytes): " .. payload:sub(1, 40))
    end
end
protocol.send = send

-- Format a localized text; every %d / %s placeholder takes tostring(arg) ("?" when missing).
local function text(code, lang, arg)
    local s = util.L(catalog.text[code] or code, lang)
    s = s:gsub("%%d", "%%s")
    if s:find("%%s") then
        return (s:gsub("%%s", (tostring(arg or "?"):gsub("%%", "%%%%"))))
    end
    return s
end

protocol.text = text

local function ack(req, botField, op, code, arg)
    -- show labels instead of ids for level-gate errors
    local entry = (code == "locked_target" and catalog.targetById[arg or ""])
        or (code == "locked_condition" and catalog.conditionById[arg or ""])
    if entry then arg = util.L(entry.label, req.lang) end
    local status = (code == "ok") and "ok" or "err"
    send(req.low, "ACK", botField, op, status, code, util.esc(text(code, req.lang, arg)))
end
protocol.ack = ack

-- ACK with an explicit status and a text taken from another catalog.text entry,
-- e.g. ackText(req, low, "SELLGREY", true, "ok", "sold", "3, +1g") or (..., true, "pending", "pending").
function protocol.ackText(req, botField, op, ok, code, textCode, arg)
    send(req.low, "ACK", botField, op, ok and "ok" or "err", code, util.esc(text(textCode or code, req.lang, arg)))
end

-- ACK for a C++ primitive result: reason "ok" -> ok (text `okText`, default "done"); a reason listed in
-- catalog.text -> err with that code; anything else -> err "failed" with the raw reason in the text.
function protocol.ackReason(req, botField, op, ok, reason, okText, arg)
    reason = reason or (ok and "ok" or "failed")
    if ok then
        return protocol.ackText(req, botField, op, true, "ok", okText or "done", arg)
    end
    if reason ~= "ok" and catalog.text[reason] then
        return protocol.ackText(req, botField, op, false, reason, reason, arg)
    end
    protocol.ackText(req, botField, op, false, "failed", "unknown_reason", tostring(reason))
end

-- Resolve a <bot> field to a Bot handle owned by the requesting player. The player is the bot's leader for
-- the per (bot, leader) store keys (store.lua): legacy keys move to them on first contact.
local function ownedBot(req, field)
    local low = util.toid(field)
    if not low then return nil end
    local bot = wow.bot(low)
    if not bot or bot:ownerLow() ~= req.low then return nil end
    store.migrate(low, req.low)
    return bot, low
end
protocol.ownedBot = ownedBot

-- Safe <bot> echo for ACKs (digits only).
local function botEcho(field)
    local low = util.toid(field)
    return low and tostring(low) or "0"
end
protocol.botEcho = botEcho

-- "0123456789ABCDEF" unit GUID text (16 upper-case hex digits), else nil.
function protocol.guidHex(field)
    if type(field) == "string" and #field == 16 and field:match("^[0-9A-F]+$") then return field end
    return nil
end

-- ----------------------------------------------------------------------------- bot chat commands (5.2)

local cmdSets   -- built lazily: exact texts, co / nc strategy names, formations, rti names

local function commandSets()
    if cmdSets then return cmdSets end
    local c = catalog.commands
    local s = { exact = util.set(c.exact), formation = util.set(c.formations), rti = util.set(c.rti),
                co = {}, nc = {} }
    s.rti.none = true
    for _, e in ipairs(catalog.style) do
        s[e.list][e.strategy] = true
        if e.also then s[e.also][e.strategy] = true end
    end
    for list, names in pairs(c.strategies or {}) do
        for i = 1, #names do s[list][names[i]] = true end
    end
    for _, roles in pairs(catalog.roleStrategies) do
        for _, names in pairs(roles) do
            for i = 1, #names do s.co[names[i]] = true end
            for _, alt in pairs(names.byTab or {}) do
                for i = 1, #alt do s.co[alt[i]] = true end
            end
        end
    end
    cmdSets = s
    return s
end

local ITEM_LINK = "^|Hitem:%d+:[%d:]*|h%[x%]|h|r"

-- "ll [-]<link><link>..." with links "|Hitem:<entry>:<digits and colons>|h[x]|h|r" (as built by loot.lua).
local function lootLinksAllowed(rest)
    if rest:sub(1, 1) == "-" then rest = rest:sub(2) end
    if rest == "" then return false end
    local pos = 1
    while pos <= #rest do
        local a, b = rest:find(ITEM_LINK, pos)
        if not a then return false end
        pos = b + 1
    end
    return true
end

-- Prefix rules of multibot-gap P6: disperse set N, tame rename / name, roll <one item link>.
local function prefixAllowed(cmd)
    local c = catalog.commands
    local n = cmd:match("^disperse set (%d%d?)$")
    if n then
        n = tonumber(n)
        return n >= 1 and n <= (c.disperseMax or 30)
    end
    local pet = cmd:match("^tame rename (%a+)$")
    if pet then return #pet <= (c.petNameMax or 12) end
    local creature = cmd:match("^tame name (%a[%a '%-]*)$")
    if creature then return #creature >= 2 and #creature <= (c.tameNameMax or 40) end
    local link = cmd:match("^roll (.+)$")
    if link then
        local a, b = link:find(ITEM_LINK)
        return a == 1 and b == #link
    end
    return false
end

-- Is a chat command text allowed (party-window-spec 5.2)? Anything else -> "bad_cmd".
function protocol.commandAllowed(cmd)
    if type(cmd) ~= "string" or cmd == "" or #cmd > config.CMD_MAX then return false end
    if cmd:find("[%z\1-\31\127\\]") then return false end
    local s = commandSets()
    if s.exact[cmd] then return true end
    local list, rest = cmd:match("^(%l%l) ([+-].*)$")
    if list == "co" or list == "nc" then
        for _, part in ipairs(util.split(rest, ",")) do
            local name = part:match("^[+-](.+)$")
            if not name or not s[list][name] then return false end
        end
        return true
    end
    local f = cmd:match("^formation (%l+)$")
    if f then return s.formation[f] == true end
    local r = cmd:match("^rti (%l+)$")
    if r then return s.rti[r] == true end
    local n = cmd:match("^wait for attack time (%d%d?)$")
    if n then return tonumber(n) <= catalog.commands.waitAttackMax end
    local links = cmd:match("^ll (.+)$")
    if links then return lootLinksAllowed(links) end
    return prefixAllowed(cmd)
end

-- Whitelist + bot:command. Returns ok, code.
function protocol.runCommand(bot, cmd)
    if not protocol.commandAllowed(cmd) then return false, "bad_cmd" end
    local ok, reason = bot:command(cmd)
    if ok then return true, "ok" end
    return false, reason or "failed"
end

-- ----------------------------------------------------------------------------- outgoing messages

local catCache = {}   -- lang -> CAT payload (static per state)

local function buildCat(lang)
    if catCache[lang] then return catCache[lang] end
    local I = implementations()
    local L = function(t) return util.esc(util.L(t, lang)) end

    local t = {}
    for _, e in ipairs(catalog.targets) do
        if I.targets[e.id] then t[#t + 1] = table.concat({ e.id, e.side, e.lvl or 0, L(e.label) }, ",") end
    end
    local c = {}
    for _, e in ipairs(catalog.conditions) do
        if I.conditions[e.id] then
            c[#c + 1] = table.concat({ e.id, e.param, e.lvl or 0, L(e.label), L(e.prefix or e.label),
                L(e.unit or ""), e.default ~= nil and tostring(e.default) or "",
                e.min ~= nil and tostring(e.min) or "", e.max ~= nil and tostring(e.max) or "", e.enum or "" }, ",")
        end
    end
    local s = {}
    for _, e in ipairs(catalog.specials) do
        if I.actions[e.id] then s[#s + 1] = table.concat({ e.id, e.side, L(e.label), L(e.desc) }, ",") end
    end
    local ic = {}
    for _, e in ipairs(catalog.itemcats) do ic[#ic + 1] = e.id .. "," .. L(e.label) end
    local d = {}
    for _, e in ipairs(catalog.dispels) do d[#d + 1] = e.id .. "," .. L(e.label) end
    local en = {}
    for list, opts in pairs(catalog.enums) do
        for _, o in ipairs(opts) do en[#en + 1] = list .. "," .. o.id .. "," .. L(o.label) end
    end

    local payload = table.concat({ "CAT", config.CAT_VERSION, table.concat(t, ";"), table.concat(c, ";"),
        table.concat(s, ";"), table.concat(ic, ";"), table.concat(d, ";"), table.concat(en, ";") }, "\t")
    catCache[lang] = payload
    return payload
end

-- Bots of the player's group controlled by this player.
local function ownedBots(req)
    local out = {}
    local members = req.player:group() or {}
    for i = 1, #members do
        local m = members[i]
        if m:isBot() then
            local bot = wow.bot(m:lowGuid())
            if bot and bot:ownerLow() == req.low then out[#out + 1] = bot end
        end
    end
    return out
end
protocol.ownedBots = ownedBots

-- Role shown in the roster (party-window-spec 5.9): playerbots' own tank / healer test, else dps.
local function partyRole(bot)
    if bot:isTank() then return "tank" end
    if bot:isHealer() then return "heal" end
    return "dps"
end

local function sendParty(req)
    local entries = {}
    local unlock = config.unlockList()
    for _, bot in ipairs(ownedBots(req)) do
        local low = bot:lowGuid()
        store.migrate(low, req.low)   -- HELLO / PARTY: the window shows the moved rules at once
        local presets, _, all = rules.loadPresets(low, req.low)
        local level = bot:level() or 0
        entries[#entries + 1] = table.concat({
            low, util.esc(bot:name() or ""), level, bot:class() or 0,
            rules.isEnabled(all) and "1" or "0",
            rules.activeIndex(presets, all),
            config.slots(level), config.COND2_LEVEL, unlock,
            partyRole(bot), math.floor((bot:hpPct() or 0) + 0.5), bot:isAlive() and "1" or "0" }, ",")
    end
    send(req.low, "PARTY", table.concat(entries, ";"))
end
protocol.sendParty = sendParty

-- Functions(req) run after CAT and PARTY on a successful HELLO, in registration order (bots.lua adds
-- BOTS and GROUPSET, party-window-spec 4.1).
protocol.helloHooks = {}
-- Functions(req) run after PARTY (the addon re-sends it on group changes); style.lua adds the AI wake sync
-- (ai-layer-spec 2.4).
protocol.partyHooks = {}

local function sendPresets(req, low)
    local presets, count, all = rules.loadPresets(low, req.low)
    send(req.low, "PRESETS", low, rules.activeIndex(presets, all), math.max(count, 1), config.MAX_PRESETS)
end

local function sendPreset(req, low, idx, p)
    send(req.low, "PRESET", low, idx, p.nameEsc, p.co, p.nc)
end

-- ----------------------------------------------------------------------------- client -> server

handlers.HELLO = function(req, f)
    if f[2] ~= config.PROTO then
        send(req.low, "ERR", util.esc(text("proto", req.lang)))
        return
    end
    send(req.low, buildCat(req.lang))
    sendParty(req)
    for _, hook in ipairs(protocol.helloHooks) do hook(req) end
end

handlers.PARTY = function(req, f)
    sendParty(req)
    for _, hook in ipairs(protocol.partyHooks) do hook(req) end
end

handlers.GET = function(req, f)
    local bot, low = ownedBot(req, f[2])
    if not bot then return ack(req, botEcho(f[2]), "GET", "bad_bot") end
    local presets, count = rules.loadPresets(low, req.low)
    if count == 0 then
        sendPreset(req, low, 1, { nameEsc = util.esc(rules.defaultName(1, req.lang)), co = "", nc = "" })
    else
        for idx = 1, config.MAX_PRESETS do
            if presets[idx] then sendPreset(req, low, idx, presets[idx]) end
        end
    end
    sendPresets(req, low)
end

handlers.BOOK = function(req, f)
    local bot = ownedBot(req, f[2])
    if not bot then return ack(req, botEcho(f[2]), "BOOK", "bad_bot") end
    send(req.low, spellbook.build(bot, req.locale))
end

-- PUT <bot> <idx> <nameEsc> <co> <nc>
handlers.PUT = function(req, f)
    local op = "PUT"
    local bot, low = ownedBot(req, f[2])
    if not bot then return ack(req, botEcho(f[2]), op, "bad_bot") end
    local idx = util.toint(f[3])
    if not idx or idx < 1 or idx > config.MAX_PRESETS then return ack(req, low, op, "bad_preset") end
    local name = util.unesc(f[4] or "")
    if not rules.validName(name) then return ack(req, low, op, "bad_name") end
    local level = bot:level() or 0
    local co, code, arg = rules.validateList(f[5] or "", level, bot)
    if not co then return ack(req, low, op, code, arg) end
    local nc
    nc, code, arg = rules.validateList(f[6] or "", level, bot)
    if not nc then return ack(req, low, op, code, arg) end

    local p = { nameEsc = util.esc(name), co = rules.serializeList(co), nc = rules.serializeList(nc) }
    if not store.set(low, "p" .. idx, rules.presetData(p.nameEsc, p.co, p.nc), req.low) then
        return ack(req, low, op, "store_failed")
    end
    ack(req, low, op, "ok")
    sendPreset(req, low, idx, p)
    sendPresets(req, low)
end

-- ACT <bot> <idx>   (allowed in combat: evaluate picks up the new store revision next tick)
handlers.ACT = function(req, f)
    local op = "ACT"
    local bot, low = ownedBot(req, f[2])
    if not bot then return ack(req, botEcho(f[2]), op, "bad_bot") end
    local idx = util.toint(f[3])
    local presets, count = rules.loadPresets(low, req.low)
    if not idx or not (presets[idx] or (count == 0 and idx == 1)) then
        return ack(req, low, op, "bad_preset")
    end
    store.set(low, "active", tostring(idx), req.low)
    ack(req, low, op, "ok")
    sendPresets(req, low)
end

-- DEL <bot> <idx>
handlers.DEL = function(req, f)
    local op = "DEL"
    local bot, low = ownedBot(req, f[2])
    if not bot then return ack(req, botEcho(f[2]), op, "bad_bot") end
    local idx = util.toint(f[3])
    local presets, count, all = rules.loadPresets(low, req.low)
    if not idx or not presets[idx] then return ack(req, low, op, "bad_preset") end
    if count <= 1 then return ack(req, low, op, "last_preset") end
    local wasActive = rules.activeIndex(presets, all) == idx
    store.erase(low, "p" .. idx, req.low)
    if wasActive then
        presets[idx] = nil
        store.set(low, "active", tostring(rules.activeIndex(presets, nil)), req.low)
    end
    ack(req, low, op, "ok")
    sendPresets(req, low)
end

-- ENABLE <bot> <0/1>
handlers.ENABLE = function(req, f)
    local op = "ENABLE"
    local bot, low = ownedBot(req, f[2])
    if not bot then return ack(req, botEcho(f[2]), op, "bad_bot") end
    if f[3] ~= "0" and f[3] ~= "1" then return ack(req, low, op, "bad_value", 0) end
    store.set(low, "enabled", f[3], req.low)
    ack(req, low, op, "ok")
    sendParty(req)
end

-- WATCH <0/1>: FIRED notifications for this player
handlers.WATCH = function(req, f)
    wow.setVar(req.low, "watch", (f[2] == "1") and 1 or nil)
end

-- ----------------------------------------------------------------------------- entry points

function protocol.on_message(player, payload)
    if type(payload) ~= "string" or payload == "" then return end
    local f = util.split(payload, "\t")
    local handler = handlers[f[1]]
    if not handler then
        wow.warn("unknown client message " .. tostring(f[1]):sub(1, 16))
        return
    end
    local locale = player:locale()
    local req = { player = player, low = player:lowGuid(), locale = locale, lang = util.lang(locale) }
    local ok, err = pcall(handler, req, f)
    if not ok then
        err = tostring(err)
        if err:find("instruction limit", 1, true) then error(err, 0) end
        wow.error("message " .. f[1] .. ": " .. err)
        send(req.low, "ERR", util.esc(text("internal", req.lang)))
    end
end

-- Optional lifecycle events ("login" | "logout") of real players. Add handlers to protocol.events.
protocol.events = {}

function protocol.on_event(event, player)
    local h = protocol.events[event]
    if h then h(player) end
end

-- ----------------------------------------------------------------------------- FIRED (spec 5.4)

-- Called by the interpreter with ctx.last (outcome of the previous tick). Map thread; per-bot and
-- per-owner memory lives in wow vars (a bot may be evaluated by different Lua states).
-- FIRED <bot> <list> <slot> [<intent>]: the AI layer's decision (slot config.AI_SLOT, ai-layer-spec 8)
-- carries the intent id ai.onLast stored in last.intent.
function protocol.onLast(bot, last, now)
    -- notify only real executions; "reach" (moved into range / stopped to cast) is not a firing
    if not last.ok or last.reason ~= "ok" or not last.slot or not last.list then return end
    if last.slot == config.ORDER_SLOT then return end   -- orders report through ORDER (orders.lua)
    local owner = bot:ownerLow()
    if not owner or owner == 0 or not wow.getVar(owner, "watch") then return end

    local low = bot:lowGuid()
    -- the AI slot is keyed per intent: heal then interrupt within FIRED_SAME_SLOT_MS both reach the owner
    local key = last.list .. ":" .. last.slot
    if last.slot == (config.AI_SLOT or 98) then key = key .. ":" .. (last.intent or "") end
    local prevAt = wow.getVar(low, "fired_at")
    if prevAt and wow.getVar(low, "fired_key") == key then
        local dt = now - prevAt
        if dt >= 0 and dt < config.FIRED_SAME_SLOT_MS then return end
    end

    local winStart = wow.getVar(owner, "fired_win")
    local cnt = wow.getVar(owner, "fired_cnt") or 0
    local dt = winStart and (now - winStart) or -1
    if not winStart or dt < 0 or dt >= config.FIRED_OWNER_WINDOW_MS then
        winStart, cnt = now, 0
    end
    if cnt >= config.FIRED_OWNER_MAX then return end
    wow.setVar(owner, "fired_win", winStart)
    wow.setVar(owner, "fired_cnt", cnt + 1)
    wow.setVar(low, "fired_at", now)
    wow.setVar(low, "fired_key", key)
    if last.slot == (config.AI_SLOT or 98) then
        send(owner, "FIRED", low, last.list, last.slot, util.esc(last.intent or ""))
    else
        send(owner, "FIRED", low, last.list, last.slot)
    end
end

return protocol
