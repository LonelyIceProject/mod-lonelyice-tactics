-- Bot tactics / party window: account bots, login/logout, chat commands, group settings
-- (party-window-spec 5.8, 5.2, 4.1). Messages: BOTS, LOGIN, LOGOUT, CMD, CMDALL, GROUP; HELLO also gets
-- BOTS (cached), GROUPSET and PULLSET. Role-scoped orders and the pull card (multibot-gap "Протокол
-- (реализация)" P4, P5): CMDROLE, PULL, PULLSET.

local util = wow.include("util.lua")
local config = wow.include("config.lua")
local catalog = wow.include("catalog.lua")
local protocol = wow.include("protocol.lua")
local store = wow.include("store.lua")

local bots = {}
local handlers = protocol.handlers
local send = protocol.send

-- ----------------------------------------------------------------------------- BOTS cache (vars)
-- Rows "guid,nameEsc,class,level,state" as C++ reported them (state 0/1/2), cached per player in vars
-- (<= 1024 bytes each): bots_at (ms of the query), bots_cache_n (chunk count), bots_cache_1..N.

local CHUNK = 1000
local MAX_CHUNKS = 8

local function cacheGet(low, now)
    local at = wow.getVar(low, "bots_at")
    if not at then return nil end
    local dt = now - at
    if dt < 0 or dt >= config.BOTS_CACHE_MS then return nil end
    local n = wow.getVar(low, "bots_cache_n")
    if not n then return nil end
    local parts = {}
    for i = 1, n do
        local p = wow.getVar(low, "bots_cache_" .. i)
        if not p then return nil end
        parts[i] = p
    end
    return table.concat(parts)
end

local function cacheSet(low, now, text)
    local n = math.ceil(#text / CHUNK)
    wow.setVar(low, "bots_at", now)
    if n > MAX_CHUNKS then   -- too large to cache: the next call queries again
        wow.setVar(low, "bots_cache_n", nil)
        return
    end
    for i = 1, n do wow.setVar(low, "bots_cache_" .. i, text:sub((i - 1) * CHUNK + 1, i * CHUNK)) end
    wow.setVar(low, "bots_cache_n", n)
end

-- Forget the cache (after LOGIN / LOGOUT the addon polls BOTS and must see the change).
function bots.invalidate(low)
    wow.setVar(low, "bots_at", nil)
end

local function queryRows(low)
    local rows = {}
    for _, b in ipairs(wow.accountBots(low) or {}) do
        rows[#rows + 1] = table.concat({ tostring(math.floor(b.guid or 0)), util.esc(b.name or ""),
            tostring(b.class or 0), tostring(b.level or 0), tostring(b.state or 0) }, ",")
    end
    return table.concat(rows, ";")
end

-- BOTS <entries>: state 3 = online and in this player's party (owned); fresh on every send.
function bots.send(req)
    local now = wow.now()
    local text = cacheGet(req.low, now)
    if not text then
        text = queryRows(req.low)
        cacheSet(req.low, now, text)
    end
    local out = {}
    for _, row in ipairs(util.split(text, ";")) do
        if row ~= "" then
            local guid, rest, state = row:match("^(%d+)(,.*,)(%d)$")
            if guid then
                if state == "1" then
                    local b = wow.bot(tonumber(guid))
                    if b and b:ownerLow() == req.low then state = "3" end
                end
                out[#out + 1] = guid .. rest .. state
            end
        end
    end
    send(req.low, "BOTS", table.concat(out, ";"))
end

handlers.BOTS = function(req, f)
    bots.send(req)
end

-- Bot guid field of LOGIN / LOGOUT: decimal low guid (as BOTS sends it) or 16 hex digits (spec 4.1).
function bots.guidField(field)
    local hex = protocol.guidHex(field)
    if hex then
        local n = tonumber(hex:sub(9), 16)
        return (n and n > 0) and n or nil
    end
    return util.toid(field)
end

-- LOGIN <guid> / LOGOUT <guid>: pass-through; C++ checks account / master rules.
handlers.LOGIN = function(req, f)
    local op = "LOGIN"
    local low = bots.guidField(f[2])
    if not low then return protocol.ack(req, "0", op, "bad_bot") end
    local ok, reason = wow.botLogin(req.low, low)
    bots.invalidate(req.low)
    if ok then return protocol.ackText(req, low, op, true, "pending", "pending") end
    protocol.ackReason(req, low, op, false, reason)
end

handlers.LOGOUT = function(req, f)
    local op = "LOGOUT"
    local low = bots.guidField(f[2])
    if not low then return protocol.ack(req, "0", op, "bad_bot") end
    local ok, reason = wow.botLogout(req.low, low)
    bots.invalidate(req.low)
    protocol.ackReason(req, low, op, ok, reason)
end

-- ----------------------------------------------------------------------------- chat commands

-- "reset botAI" (party window "Reset AI") runs playerbots' ResetAiAction -> ResetStrategies: the role /
-- toggles / pull of this leader (style.ensure) must be applied again. The command is queued by playerbots
-- (HandleCommand), so the re-apply waits STYLE_RESET_DELAY_MS ("style_due_<leader>", style.ensure) instead of
-- running before the reset and being wiped by it. Vars are written here directly: style.lua includes this file.
local STYLE_RESET_DELAY_MS = 3000

local function userCommand(req, bot, cmd)
    local ok, code = protocol.runCommand(bot, cmd)
    if ok and cmd == "reset botAI" and req.low and req.low > 0 then
        local low, leader = bot:lowGuid(), string.format("%d", req.low)
        wow.setVar(low, "style_applied_" .. leader, nil)
        wow.setVar(low, "style_due_" .. leader, wow.now() + STYLE_RESET_DELAY_MS)
    end
    return ok, code
end

-- CMD <bot> <cmdEsc>
handlers.CMD = function(req, f)
    local op = "CMD"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local ok, code = userCommand(req, bot, util.unesc(f[3] or ""))
    protocol.ackReason(req, low, op, ok, code)
end

-- Run a whitelisted command on every owned bot in the group. Returns the number of bots that took it,
-- or nil, "bad_cmd".
function bots.commandAll(req, cmd)
    if not protocol.commandAllowed(cmd) then return nil, "bad_cmd" end
    local n = 0
    for _, bot in ipairs(protocol.ownedBots(req)) do
        if userCommand(req, bot, cmd) then n = n + 1 end
    end
    return n
end

-- CMDALL <cmdEsc> -> ACK 0 CMDALL (text = count)
handlers.CMDALL = function(req, f)
    local n, code = bots.commandAll(req, util.unesc(f[2] or ""))
    if not n then return protocol.ack(req, "0", "CMDALL", code) end
    protocol.ackText(req, "0", "CMDALL", true, "ok", "cmd_sent", n)
end

-- ----------------------------------------------------------------------------- role scopes (multibot-gap P4)

local SCOPE_TEST = {
    all = function() return true end,
    tank = function(b) return b:isTank() == true end,
    heal = function(b) return b:isHealer() == true end,
    dps = function(b) return not b:isTank() and not b:isHealer() end,
    melee = function(b) return b:isMelee() == true end,
    ranged = function(b) return b:isRanged() == true end,
}

-- Owned group bots in a role scope; nil for an unknown scope.
function bots.inScope(req, scope)
    local test = catalog.roleScopeById[scope or ""] and SCOPE_TEST[scope]
    if not test then return nil end
    return util.filter(protocol.ownedBots(req), test)
end

-- CMDROLE <scope> <cmdEsc> -> ACK 0 CMDROLE (text = count); err bad_cmd / bad_role / no_bots
handlers.CMDROLE = function(req, f)
    local op = "CMDROLE"
    local cmd = util.unesc(f[3] or "")
    if not protocol.commandAllowed(cmd) then return protocol.ack(req, "0", op, "bad_cmd") end
    local list = bots.inScope(req, f[2])
    if not list then return protocol.ack(req, "0", op, "bad_role") end
    if #list == 0 then return protocol.ack(req, "0", op, "no_bots") end
    local n = 0
    for _, bot in ipairs(list) do
        if userCommand(req, bot, cmd) then n = n + 1 end
    end
    protocol.ackText(req, "0", op, true, "ok", "cmd_sent", n)
end

-- ----------------------------------------------------------------------------- pull card (multibot-gap P5)
-- Store key "pull" on the player guid: "scope,preset,wait" (preset empty after a plain "wait").

local function pullStored(low)
    local s = wow.storeGet(low, "pull") or ""
    local scope, preset, wait = s:match("^(%l*),(%l*),(%d*)$")
    return scope or "", preset or "", wait or ""
end

local function sendPullSet(req)
    local scope, preset, wait = pullStored(req.low)
    local presets, scopes = {}, {}
    for i, p in ipairs(catalog.pull.presets) do
        presets[i] = table.concat({ p.id, util.esc(util.L(p.label, req.lang)), util.esc(util.L(p.hint, req.lang)),
            tostring(p.wait) }, ",")
    end
    for i, s in ipairs(catalog.roleScopes) do scopes[i] = s.id .. "," .. util.esc(util.L(s.label, req.lang)) end
    send(req.low, "PULLSET", scope, preset, wait, table.concat(presets, ";"), table.concat(scopes, ";"))
end
bots.sendPullSet = sendPullSet

-- Whether a preset's "assist" group goes to this bot. Same rule as the card's target buttons (addon
-- Party.lua AssistScope): tanks keep "tank assist" (so scopes tank and melee get none); scope "all" means
-- the damage bots, so healers are left alone unless their own scope (heal, ranged) was picked.
local function pullAssists(bot, scope)
    if scope == "tank" or scope == "melee" or bot:isTank() then return false end
    if scope == "all" and bot:isHealer() then return false end
    return true
end

-- Commands of a pull setting for one bot: "wait for attack time n", then one "co" list.
function bots.pullCommands(bot, wait, preset, scope)
    local parts = { (wait > 0 and "+" or "-") .. "wait for attack" }
    if preset then
        parts[#parts + 1] = (preset.focus and "+" or "-") .. "focus"
        if preset.assist and pullAssists(bot, scope) then parts[#parts + 1] = "+" .. preset.assist end
    end
    return { "wait for attack time " .. wait, "co " .. table.concat(parts, ",") }
end

-- ----------------------------------------------------------------------------- pull setting per bot
-- Store key "pull" per (bot, leader) (tactics-round2-spec 4.4): "wait=<n>;focus=<1|0>;assist=<strategy|->"
-- (focus absent = never set). Written by PULL for every bot in scope; style.ensure re-applies it after a
-- relog / talent change. The player-level "pull" key above only drives the card display.

local ASSIST = {}   -- strategy names of the "assist" radio group
for _, e in ipairs(catalog.style) do
    if e.group == "assist" then ASSIST[e.strategy] = true end
end

-- { wait = n, focus = bool|nil, assist = strategy|nil } or nil when absent / unusable.
function bots.parsePull(text)
    if type(text) ~= "string" or text == "" then return nil end
    local r = {}
    for _, part in ipairs(util.split(text, ";")) do
        local k, v = part:match("^(%l+)=(.*)$")
        if k == "wait" then
            local n = util.toint(v)
            if n and n >= 0 and n <= catalog.pull.waitMax then r.wait = n end
        elseif k == "focus" then
            if v == "1" then r.focus = true elseif v == "0" then r.focus = false end
        elseif k == "assist" then
            if ASSIST[v] then r.assist = v end
        end
    end
    if r.wait == nil then return nil end
    return r
end

function bots.serializePull(r)
    local parts = { "wait=" .. r.wait }
    if r.focus ~= nil then parts[#parts + 1] = "focus=" .. (r.focus and "1" or "0") end
    parts[#parts + 1] = "assist=" .. (r.assist or "-")
    return table.concat(parts, ";")
end

function bots.loadPull(low, leader)
    return bots.parsePull(store.get(low, "pull", leader))
end

-- The same state the PULL commands of this bot set (merged into what was stored before).
local function savePull(bot, leader, wait, preset, scope)
    local low = bot:lowGuid()
    local r = bots.loadPull(low, leader) or {}
    r.wait = wait
    if preset then
        r.focus = preset.focus and true or false
        if preset.assist and pullAssists(bot, scope) then r.assist = preset.assist end
    end
    return store.set(low, "pull", bots.serializePull(r), leader)
end

-- Commands that restore a stored per-bot pull record (style.ensure).
function bots.pullCommandsStored(r)
    local parts = { (r.wait > 0 and "+" or "-") .. "wait for attack" }
    if r.focus ~= nil then parts[#parts + 1] = (r.focus and "+" or "-") .. "focus" end
    if r.assist then parts[#parts + 1] = "+" .. r.assist end
    return { "wait for attack time " .. r.wait, "co " .. table.concat(parts, ",") }
end

-- PULL <scope> wait <n> | PULL <scope> preset <id> -> ACK 0 PULL (text = count), PULLSET
handlers.PULL = function(req, f)
    local op = "PULL"
    local scope, mode, value = f[2] or "", f[3] or "", f[4] or ""
    local list = bots.inScope(req, scope)
    if not list then return protocol.ack(req, "0", op, "bad_role") end
    local wait, preset
    if mode == "wait" then
        wait = util.toint(value)
        if not wait or wait < 0 or wait > catalog.pull.waitMax then return protocol.ack(req, "0", op, "bad_arg") end
    elseif mode == "preset" then
        preset = catalog.pullPresetById[value]
        if not preset then return protocol.ack(req, "0", op, "bad_arg") end
        wait = preset.wait
    else
        return protocol.ack(req, "0", op, "bad_arg")
    end
    if #list == 0 then return protocol.ack(req, "0", op, "no_bots") end
    local n = 0
    for _, bot in ipairs(list) do
        local ok = true
        for _, cmd in ipairs(bots.pullCommands(bot, wait, preset, scope)) do
            ok = protocol.runCommand(bot, cmd) and ok
        end
        if ok then
            n = n + 1
            savePull(bot, req.low, wait, preset, scope)
        end
    end
    wow.storeSet(req.low, "pull", scope .. "," .. (preset and preset.id or "") .. "," .. wait)
    protocol.ackText(req, "0", op, true, "ok", "cmd_sent", n)
    sendPullSet(req)
end

handlers.PULLSET = function(req, f)
    sendPullSet(req)
end

-- ----------------------------------------------------------------------------- group settings
-- Store keys on the PLAYER guid: formation (name), rti (raid icon id 0..8, 0 = none).

-- "3" / "diamond" -> 3, "diamond"; "0" / "none" -> 0, "none"; else nil.
function bots.rtiValue(v)
    local names = catalog.commands.rti
    local n = util.toint(v)
    if n then
        if n == 0 then return 0, "none" end
        if names[n] then return n, names[n] end
        return nil
    end
    if v == "none" then return 0, "none" end
    for i = 1, #names do
        if names[i] == v then return i, v end
    end
    return nil
end

local function sendGroupSet(req)
    send(req.low, "GROUPSET", wow.storeGet(req.low, "formation") or "", wow.storeGet(req.low, "rti") or "")
end

-- GROUP <key> <value>: formation <name> | rti <icon id or name>
handlers.GROUP = function(req, f)
    local op = "GROUP"
    local key, value = f[2], f[3] or ""
    local cmd, stored
    if key == "formation" then
        if not util.set(catalog.commands.formations)[value] then return protocol.ack(req, "0", op, "bad_cmd") end
        cmd, stored = "formation " .. value, value
    elseif key == "rti" then
        local id, name = bots.rtiValue(value)
        if not id then return protocol.ack(req, "0", op, "bad_cmd") end
        cmd, stored = "rti " .. name, tostring(id)
    else
        return protocol.ack(req, "0", op, "bad_op")
    end
    if not wow.storeSet(req.low, key, stored) then return protocol.ack(req, "0", op, "store_failed") end
    local n = bots.commandAll(req, cmd)
    protocol.ackText(req, "0", op, true, "ok", "cmd_sent", n or 0)
    protocol.sendParty(req)
end

-- HELLO reply order: CAT, PARTY (protocol.lua), BOTS, GROUPSET, PULLSET.
protocol.helloHooks[#protocol.helloHooks + 1] = function(req)
    bots.send(req)
    sendGroupSet(req)
    sendPullSet(req)
end

return bots
