-- Bot tactics / party window: role and behaviour toggles (party-window-spec 5.4, 4.1).
-- Policy tables live in catalog.lua (catalog.roleStrategies, catalog.style); this file detects the current
-- state from bot:strategies() and turns changes into whitelisted "co"/"nc" chat commands.
-- Messages: STYLE, SETSTYLE (a successful change is saved per (bot, leader) in the store key "style" and
-- re-applied by style.ensure, tactics-round2-spec 4.4). AI slider (ai-layer-spec 2, 8): STYLE fields 6-7, SETSTYLE <bot> ai <0..3>,
-- the wake sync of owned bots on HELLO / PARTY. profile.lua is reached through aistat.profile() (lazy,
-- with a stand-in when the file is missing).

local util = wow.include("util.lua")
local config = wow.include("config.lua")
local catalog = wow.include("catalog.lua")
local protocol = wow.include("protocol.lua")
local talents = wow.include("talents.lua")
local aistat = wow.include("aistat.lua")
local bots = wow.include("bots.lua")
local store = wow.include("store.lua")

local style = {}
local handlers = protocol.handlers
local send = protocol.send

local ROLE_ORDER = { "tank", "heal", "dps" }

-- Every strategy name of a role (default array and all byTab arrays).
local function roleNames(role)
    local t = {}
    for i = 1, #role do t[role[i]] = true end
    for _, alt in pairs(role.byTab or {}) do
        for i = 1, #alt do t[alt[i]] = true end
    end
    return t
end

-- Combat strategy names that are Style entries of this class (totems, auras, tank assist, ...): a player can
-- set them on their own, so they never identify a role.
local function styleNamesCo(class)
    local t = {}
    for _, e in ipairs(catalog.style) do
        if catalog.styleFor(e, class) and (e.list == "co" or e.also == "co") then t[e.strategy] = true end
    end
    return t
end

-- Names that identify a role: its names minus those any other role of the class also uses and minus the
-- class' Style names.
local function ownNames(roles, id, class)
    local own = roleNames(roles[id])
    for other, def in pairs(roles) do
        if other ~= id then
            for name in pairs(roleNames(def)) do own[name] = nil end
        end
    end
    for name in pairs(styleNamesCo(class)) do own[name] = nil end
    return own
end

-- Style entries of a class, and the members of each group (in catalog order).
function style.entriesFor(class)
    local out, members = {}, {}
    for _, e in ipairs(catalog.style) do
        if catalog.styleFor(e, class) then
            out[#out + 1] = e
            if e.group then
                members[e.group] = members[e.group] or {}
                local m = members[e.group]
                m[#m + 1] = e
            end
        end
    end
    return out, members
end

-- Record in `pending` that `name` of `list` turns on/off; turning a group member on turns the other
-- members of its group (same list, same class) off: playerbots drops siblings on "+x" (Engine::addStrategy).
local function markPending(pending, class, list, name, on)
    pending[list][name] = on
    if not on then return end
    for _, e in ipairs(catalog.style) do
        if e.group and (e.list == list or e.also == list) and e.strategy == name and catalog.styleFor(e, class) then
            for _, o in ipairs(catalog.style) do
                if o.group == e.group and o.strategy ~= name and catalog.styleFor(o, class)
                    and (o.list == list or o.also == list) then
                    pending[list][o.strategy] = false
                end
            end
        end
    end
end

-- Role ids the class has, in ROLE_ORDER.
function style.classRoles(class)
    local roles = catalog.roleStrategies[class or 0] or {}
    local out = {}
    for _, id in ipairs(ROLE_ORDER) do
        if roles[id] then out[#out + 1] = id end
    end
    return out, roles
end

-- Current role from a set of active combat strategy names; "" when none matches.
function style.currentRole(class, active)
    local ids, roles = style.classRoles(class)
    if #ids == 1 then return ids[1] end
    for _, id in ipairs(ids) do
        for name in pairs(ownNames(roles, id, class)) do
            if active[name] then return id end
        end
    end
    return ""
end

-- Strategy array to use for a role given the bot's main talent tab (nil = default array).
function style.roleArray(role, tab)
    return (tab and role.byTab and role.byTab[tab]) or role
end

-- Chat commands that switch to role `id`: "co -<other roles' names>,+<this role's names>", split so that
-- no command exceeds CMD_MAX. Names already in the right state are skipped. Returns array of commands.
function style.roleCommands(class, id, active, tab)
    local _, roles = style.classRoles(class)
    local role = roles[id]
    if not role then return nil end
    local want = {}
    local arr = style.roleArray(role, tab)
    for i = 1, #arr do want[arr[i]] = true end

    -- remove: every active name of any role of the class (incl. this role's other specs) not wanted now
    local union = {}
    for _, def in pairs(roles) do
        for name in pairs(roleNames(def)) do union[name] = true end
    end
    local names = {}
    for name in pairs(union) do
        if not want[name] and active[name] then names[#names + 1] = name end
    end
    table.sort(names)
    local parts = {}
    for i, name in ipairs(names) do parts[i] = "-" .. name end
    for i = 1, #arr do
        if not active[arr[i]] then parts[#parts + 1] = "+" .. arr[i] end
    end

    local cmds, cur = {}, nil
    for _, p in ipairs(parts) do
        if cur and #cur + 1 + #p <= config.CMD_MAX then
            cur = cur .. "," .. p
        else
            if cur then cmds[#cmds + 1] = cur end
            cur = "co " .. p
        end
    end
    if cur then cmds[#cmds + 1] = cur end
    return cmds
end

local function activeSet(bot, list)
    return util.set(bot:strategies(list) or {})
end

-- STYLE <bot> <role> <roles> <toggles> <ai> <ainames> <groups> (multibot-gap P2).
-- `pending` = { co = {name = bool}, nc = {...} } overrides the strategies the bot reports (commands run on
-- the bot's next tick, after this reply is built). <toggles> = key,label,hint,on,list,group,cls (only the
-- entries of the bot's class; at most one "1" per group); <ai> = effective,stored,max,lvl2,lvl3;
-- <ainames> = 0:label:hint;1:...; <groups> = id,label,hint,none,cls,list of groups with members
-- (list "both" for a group with `also`, e.g. the mage armor: drawn without the "out of combat" tag).
function style.send(req, bot, low, pending)
    local lists = { co = activeSet(bot, "co"), nc = activeSet(bot, "nc") }
    for list, names in pairs(pending or {}) do
        for name, on in pairs(names) do lists[list][name] = on or nil end
    end
    local class = bot:class() or 0
    local ids = style.classRoles(class)
    local roles = {}
    for i, id in ipairs(ids) do roles[i] = id .. ":" .. util.esc(util.L(catalog.roleById[id].label, req.lang)) end
    local entries, members = style.entriesFor(class)
    local toggles, groupOn = {}, {}
    for i, e in ipairs(entries) do
        local on = lists[e.list][e.strategy] == true
        if on and e.group then
            if groupOn[e.group] then on = false else groupOn[e.group] = true end
        end
        toggles[i] = table.concat({ e.key, util.esc(util.L(e.label, req.lang)), util.esc(util.L(e.hint, req.lang)),
            on and "1" or "0", e.list, e.group or "", e.class and "1" or "0" }, ",")
    end
    local groups = {}
    for _, g in ipairs(catalog.styleGroups) do
        if members[g.id] then
            groups[#groups + 1] = table.concat({ g.id, util.esc(util.L(g.label, req.lang)),
                util.esc(util.L(g.hint, req.lang)), g.none and "1" or "0", g.cls and "1" or "0",
                g.also and "both" or g.list }, ",")
        end
    end
    local ai, aiNames = aistat.styleFields(bot, low, req.lang)
    send(req.low, "STYLE", low, style.currentRole(class, lists.co), table.concat(roles, ";"),
        table.concat(toggles, ";"), ai, aiNames, table.concat(groups, ";"),
        wow.include("manual.lua").styleField(bot, low, req.low))   -- field 9 manual mode (abilities-mirroring-spec 3.1)
end

-- Commands and pending state of SETSTYLE <key> <1/0> for a catalog.style entry. Returns cmds or nil, code.
function style.toggleCommands(bot, e, on, pending)
    local class = bot:class() or 0
    if not catalog.styleFor(e, class) then return nil, "bad_value" end
    local cmds = {}
    for _, list in ipairs({ e.list, e.also }) do
        local parts = {}
        if e.group then
            local g = catalog.styleGroupById[e.group]
            if not on and not (g and g.none) then return nil, "bad_value" end
            if on then
                -- drop the other active members explicitly (groups whose playerbots context has no siblings,
                -- e.g. the hunter rotation bm/mm/surv, rely on this)
                local active = activeSet(bot, list)
                local _, members = style.entriesFor(class)
                for _, o in ipairs(members[e.group] or {}) do
                    if o.strategy ~= e.strategy and active[o.strategy] then parts[#parts + 1] = "-" .. o.strategy end
                end
            end
        end
        parts[#parts + 1] = (on and "+" or "-") .. e.strategy
        cmds[#cmds + 1] = list .. " " .. table.concat(parts, ",")
        for _, p in ipairs(parts) do
            markPending(pending, class, list, p:sub(2), p:sub(1, 1) == "+")
        end
    end
    return cmds
end

-- ----------------------------------------------------------------------------- saved style (round2 4.4)
-- Store key "style" per (bot, leader): "role=<tank|heal|dps>;<key>=<1|0>;..." - only what the player set
-- through SETSTYLE (role and catalog.style keys, class radio groups included). style.ensure re-applies it,
-- with the per-bot pull record (bots.lua), once per var "style_applied_<leader>": after a relog (vars are
-- cleared), after TAPPLY / TSPEC / PRESPEC (talents.lua clears the var: C++ resets the strategies), after a
-- party-window "reset botAI" (bots.lua clears it, re-apply delayed by "style_due_<leader>") and when
-- the leader changes (another var name).

-- { role = id|nil, keys = { key = bool } }; unknown keys / values are dropped.
function style.parseSaved(text)
    local r = { keys = {} }
    for _, part in ipairs(util.split(text or "", ";")) do
        local k, v = part:match("^([%w_]+)=(%w*)$")
        if k == "role" then
            if catalog.roleById[v] then r.role = v end
        elseif k and catalog.styleByKey[k] and (v == "1" or v == "0") then
            r.keys[k] = v == "1"
        end
    end
    return r
end

function style.serializeSaved(r)
    local parts = {}
    if r.role then parts[1] = "role=" .. r.role end
    for _, e in ipairs(catalog.style) do
        local on = r.keys[e.key]
        if on ~= nil then parts[#parts + 1] = e.key .. "=" .. (on and "1" or "0") end
    end
    return table.concat(parts, ";")
end

function style.loadSaved(low, leader)
    return style.parseSaved(store.get(low, "style", leader))
end

-- Record a successful SETSTYLE <key> <value> (role or a catalog.style key). Turning a group member on drops
-- the other members of its group from the record (the command turned them off already).
function style.remember(low, leader, key, value)
    if not leader then return false end
    local r = style.loadSaved(low, leader)
    if key == "role" then
        r.role = value
    else
        local e = catalog.styleByKey[key]
        if not e then return false end
        local on = value == "1"
        if on and e.group then
            for k in pairs(r.keys) do
                local o = catalog.styleByKey[k]
                if k ~= key and o and o.group == e.group then r.keys[k] = nil end
            end
        end
        r.keys[key] = on
    end
    return store.set(low, "style", style.serializeSaved(r), leader)
end

-- Commands that bring a bot to its saved style and pull record (role first, then toggles, then pull).
function style.restoreCommands(bot, low, leader)
    local r = style.loadSaved(low, leader)
    local cmds = {}
    local class = bot:class() or 0
    if r.role then
        local _, roles = style.classRoles(class)
        if roles[r.role] then
            for _, c in ipairs(style.roleCommands(class, r.role, activeSet(bot, "co"), talents.mainTab(bot)) or {}) do
                cmds[#cmds + 1] = c
            end
        end
    end
    local pending = { co = {}, nc = {} }
    for _, e in ipairs(catalog.style) do
        local on = r.keys[e.key]
        if on ~= nil and catalog.styleFor(e, class) then
            for _, c in ipairs(style.toggleCommands(bot, e, on, pending) or {}) do cmds[#cmds + 1] = c end
        end
    end
    local pull = bots.loadPull(low, leader)
    if pull then
        for _, c in ipairs(bots.pullCommandsStored(pull)) do cmds[#cmds + 1] = c end
    end
    return cmds
end

-- Evaluate hook (map thread, interpreter.evaluate after loot.ensure). Only under a real player's ownership,
-- like loot.ensure: in a selfbot-led group the commands would come "from" the leader bot, and the var stays
-- unset so a later real owner still gets them.
function style.ensure(bot, low, leader)
    if not leader then return end
    local var = "style_applied_" .. leader
    if wow.getVar(low, var) then return end
    -- after a party-window "reset botAI" (bots.lua): wait until the queued reset has run
    local dueVar = "style_due_" .. leader
    local due = wow.getVar(low, dueVar)
    if due then
        if wow.now() < due then return end
        wow.setVar(low, dueVar, nil)
    end
    local owner = bot:owner()
    if not (owner and owner:isRealPlayer()) then return end
    wow.setVar(low, var, 1)
    for _, cmd in ipairs(style.restoreCommands(bot, low, leader)) do protocol.runCommand(bot, cmd) end
end

-- Force a re-apply on the next evaluate (talents.lua after a talent / spec change).
function style.forget(low, leader)
    if leader then wow.setVar(low, "style_applied_" .. leader, nil) end
end

-- Wake sync of every owned bot (ai-layer-spec 2.4): a bot with an empty store and slider > 0 must be
-- evaluated by the trigger.
function style.syncWakeAll(req)
    local profile = aistat.profile()
    for _, b in ipairs(protocol.ownedBots(req)) do profile.syncWake(b, b:lowGuid()) end
end
protocol.helloHooks[#protocol.helloHooks + 1] = style.syncWakeAll
protocol.partyHooks[#protocol.partyHooks + 1] = style.syncWakeAll

-- SETSTYLE <bot> ai <0..3>: slider position (store key "ai"), ACK then STYLE.
local function setAi(req, bot, low, value)
    local op = "SETSTYLE"
    local n = util.toint(value)
    if not n or n < 0 or n > 3 then
        protocol.ack(req, low, op, "bad_value", 0)
        return style.send(req, bot, low)
    end
    local ok, code = aistat.profile().setAi(bot, low, n)
    if ok then
        protocol.ack(req, low, op, "ok")
    elseif code == "locked_ai" then
        protocol.ack(req, low, op, code, aistat.levelOf(n))
    elseif code == "bad_value" then
        protocol.ack(req, low, op, code, 0)
    else
        protocol.ack(req, low, op, code or "store_failed")
    end
    style.send(req, bot, low)
end

handlers.STYLE = function(req, f)
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), "STYLE", "bad_bot") end
    style.send(req, bot, low)
end

-- SETSTYLE <bot> <key> <value>: role tank|heal|dps, or a catalog.style key with 1/0.
handlers.SETSTYLE = function(req, f)
    local op = "SETSTYLE"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local key, value = f[3] or "", f[4] or ""
    if key == "ai" then return setAi(req, bot, low, value) end
    if key == "manual" then return wow.include("manual.lua").handle(req, bot, low, value, f[5], style.send) end
    local pending = { co = {}, nc = {} }
    local cmds
    if key == "role" then
        local class = bot:class() or 0
        local _, roles = style.classRoles(class)
        if not roles[value] then return protocol.ack(req, low, op, "bad_value", 0) end
        local active = activeSet(bot, "co")
        local tab = talents.mainTab(bot)
        cmds = style.roleCommands(class, value, active, tab)
        for _, cmd in ipairs(cmds) do
            for _, p in ipairs(util.split(cmd:sub(4), ",")) do
                markPending(pending, class, "co", p:sub(2), p:sub(1, 1) == "+")
            end
        end
    else
        local e = catalog.styleByKey[key]
        if not e or (value ~= "1" and value ~= "0") then return protocol.ack(req, low, op, "bad_value", 0) end
        local code
        cmds, code = style.toggleCommands(bot, e, value == "1", pending)
        if not cmds then return protocol.ack(req, low, op, code, 0) end
    end
    for _, cmd in ipairs(cmds) do
        local ok, code = protocol.runCommand(bot, cmd)
        if not ok then
            protocol.ackReason(req, low, op, false, code)
            return style.send(req, bot, low)
        end
    end
    -- the player took over the aoe toggle: slider 3 stops switching it (ai-layer-spec 3.6)
    if key == "aoe" then wow.setVar(low, "style_touched_aoe", 1) end
    -- survives talents / relog (tactics-round2-spec 4.4); the leader is the requesting player
    style.remember(low, req.low, key, value)
    protocol.ack(req, low, op, "ok")
    style.send(req, bot, low, pending)
end

return style
