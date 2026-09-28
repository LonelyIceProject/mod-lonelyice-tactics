-- Bot tactics / party window: per-spell rules for the class AI, "never" / "only on <target>"
-- (AI stage 1b, party-window-spec 5.7). Store key `veto` per (bot, leader) (store.lua): "spellFirstRank,mode,target;..."
-- (mode never|only; target = catalog target id, empty for never). C++ keeps the active set in the bot's
-- runtime (not persistent): it is pushed with bot:setVeto on change, after a store revision change and
-- every VETO_REFRESH_MS; `only` targets are refreshed every evaluate with bot:vetoTarget (C++ denies the
-- spell when the refresh is older than Tactics.VetoTargetTtlMs). Vetoes constrain the class AI only;
-- the player's own rules and orders are not affected. Messages: VETO, VETOS.

local util = wow.include("util.lua")
local config = wow.include("config.lua")
local catalog = wow.include("catalog.lua")
local protocol = wow.include("protocol.lua")
local targets = wow.include("targets.lua")
local store = wow.include("store.lua")

local veto = {}
local handlers = protocol.handlers
local send = protocol.send

-- ----------------------------------------------------------------------------- store format

-- Parse the store text -> array of { spell = first rank id, mode, target }. Bad entries are skipped.
function veto.parse(text)
    local out = {}
    for _, part in ipairs(util.split(text or "", ";")) do
        local spell, mode, target = part:match("^(%d+),(%l+),([%w_]*)$")
        spell = tonumber(spell)
        if spell and (mode == "never" or (mode == "only" and catalog.targetById[target])) then
            out[#out + 1] = { spell = spell, mode = mode, target = (mode == "only") and target or "" }
        end
    end
    return out
end

function veto.serialize(list)
    local t = {}
    for i, e in ipairs(list) do t[i] = e.spell .. "," .. e.mode .. "," .. (e.target or "") end
    return table.concat(t, ";")
end

-- Lower-case enGB spell name, the key C++ compares with CastSpellAction::getSpell() (cached per state).
local names = {}

function veto.spellName(id)
    local n = names[id]
    if n == nil then
        local s = wow.spell(id, "enGB")
        n = (s and s.name and s.name ~= "") and string.lower(s.name) or false
        names[id] = n
    end
    return n or nil
end

-- ----------------------------------------------------------------------------- C++ push

-- per-state parse cache: botLow -> { rev, leader, list }. The key is per (bot, leader) (store.lua): the
-- entry remembers the leader it was read for; veto.check (AI layer, low only) uses the leader of the last
-- refresh / message.
local cache = {}

local function load(low, leader)
    local rev = wow.storeRev(low)
    local e = cache[low]
    if leader == nil and e then leader = e.leader end
    if e and e.rev == rev and e.leader == leader then return e end
    e = { rev = rev, leader = leader, list = veto.parse(store.get(low, "veto", leader)), bySpell = {},
          onlyTarget = {} }
    for _, v in ipairs(e.list) do e.bySpell[v.spell] = v end
    cache[low] = e
    return e
end

-- First rank of a spell id (static, cached per state).
local firstRank = {}

local function firstOf(id)
    local f = firstRank[id]
    if f == nil then
        local s = wow.spell(id)
        f = (s and s.first and s.first > 0) and s.first or id
        firstRank[id] = f
    end
    return f
end

-- AI layer (ai-layer-spec 5.7): is casting spellId (any rank) on targetGuidHex forbidden for this bot?
-- never -> always forbidden; only -> forbidden unless the target is the one veto.refresh resolved for that
-- entry this tick (e.onlyTarget). Items are never vetoed (spellId nil).
function veto.check(low, spellId, targetGuidHex)
    if not spellId then return false end
    local e = load(low)
    if #e.list == 0 then return false end
    local v = e.bySpell[firstOf(spellId)]
    if not v then return false end
    if v.mode == "never" then return true end
    local only = e.onlyTarget[v.spell]
    return only == nil or only ~= targetGuidHex
end

-- Replace the C++ veto set of a bot with the stored list; remembers the revision in var veto_rev.
function veto.push(bot, low, now, leader)
    local e = load(low, leader)
    local list = {}
    for _, v in ipairs(e.list) do
        local name = veto.spellName(v.spell)
        if name then list[#list + 1] = { spell = name, only = v.mode == "only" } end
    end
    bot:setVeto(list)
    wow.setVar(low, "veto_rev", e.rev)
    wow.setVar(low, "veto_at", now)
    return e
end

-- Evaluate hook (map thread): push when the store changed / the refresh time passed, then refresh the
-- targets of `only` entries with the same selectors the rules use.
function veto.refresh(bot, env, now)
    local low = env.low or bot:lowGuid()
    local leader = env.leader
    if leader == nil then leader = store.leaderOf(bot) end
    local rev = wow.storeRev(low)
    local prev = cache[low]
    local e = load(low, leader)
    local at = wow.getVar(low, "veto_at")
    -- a leader change needs a push too (same revision, other key)
    if wow.getVar(low, "veto_rev") ~= rev or (prev and prev.leader ~= leader)
        or (#e.list > 0 and (not at or now - at >= config.VETO_REFRESH_MS or now < at)) then
        e = veto.push(bot, low, now, leader)
    end
    for _, v in ipairs(e.list) do
        if v.mode == "only" then
            local sel = targets[v.target]
            local list = sel and sel(env)
            local u = list and list[1]
            local name = veto.spellName(v.spell)
            e.onlyTarget[v.spell] = u and u:guid() or nil
            if u and name then bot:vetoTarget(name, u:guid()) end
        end
    end
end

-- ----------------------------------------------------------------------------- messages

local function sendVetos(req, low)
    local e = load(low, req.low)
    local t = {}
    for i, v in ipairs(e.list) do t[i] = v.spell .. "," .. v.mode .. "," .. v.target end
    send(req.low, "VETOS", low, table.concat(t, ";"))
end

-- VETO <bot> <spell> <ai|never|only> <target>
handlers.VETO = function(req, f)
    local op = "VETO"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local id = util.toid(f[3])
    local s = id and wow.spell(id)
    if not s or s.passive then return protocol.ack(req, low, op, "bad_spell") end
    local first = (s.first and s.first > 0) and s.first or id
    local mode, target = f[4], f[5] or ""
    if mode ~= "ai" and mode ~= "never" and mode ~= "only" then return protocol.ack(req, low, op, "bad_value", 0) end
    if mode == "only" and not (catalog.targetById[target] and targets[target]) then
        return protocol.ack(req, low, op, "bad_target")
    end
    if mode ~= "ai" and (bot:highestRank(first) or 0) == 0 then return protocol.ack(req, low, op, "bad_spell") end

    local list = {}
    for _, v in ipairs(load(low, req.low).list) do
        if v.spell ~= first then list[#list + 1] = v end
    end
    if mode ~= "ai" then
        if #list >= config.VETO_MAX then return protocol.ack(req, low, op, "too_many") end
        list[#list + 1] = { spell = first, mode = mode, target = (mode == "only") and target or "" }
    end
    local ok
    if #list == 0 then
        ok = store.erase(low, "veto", req.low) or store.get(low, "veto", req.low) == nil
    else
        ok = store.set(low, "veto", veto.serialize(list), req.low)
    end
    if not ok then return protocol.ack(req, low, op, "store_failed") end
    veto.push(bot, low, wow.now(), req.low)
    protocol.ack(req, low, op, "ok")
    sendVetos(req, low)
end

handlers.VETOS = function(req, f)
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), "VETOS", "bad_bot") end
    sendVetos(req, low)
end

return veto
