-- Bot tactics: the gambit interpreter, tactics.evaluate(bot, ctx) (spec 3.3 and section 8).
--
-- Rules are checked top-down. For every rule: take the target selector's candidates (after sort
-- modifiers such as "lowest"), and the first candidate that passes all conditions and yields an action
-- becomes a decision. C++ executes the first decision whose primitive succeeds; if none succeeds (or we
-- return nil) the class AI runs. A matching "wait" rule stops the list: nothing below it (and no class AI)
-- runs while its conditions hold. Dungeon/boss mechanics are guarded in C++ and always win.

local config = wow.include("config.lua")
local catalog = wow.include("catalog.lua")
local rules = wow.include("rules.lua")
local targets = wow.include("targets.lua")
local conditions = wow.include("conditions.lua")
local actions = wow.include("actions.lua")
local protocol = wow.include("protocol.lua")
local orders = wow.include("orders.lua")
local veto = wow.include("veto.lua")
local loot = wow.include("loot.lua")
local store = wow.include("store.lua")
local style = wow.include("style.lua")
local ai = wow.include("ai/utility.lua")   -- AI layer (ai-layer-spec 5); profile.lua via ai/utility.lua

local interpreter = {}

-- ----------------------------------------------------------------------------- per-state rule cache
-- botLow -> { rev, leader, enabled, co = {compiled rules}, nc = {...} }. Rebuilt when the store revision or
-- the leader changes (rules are stored per (bot, leader), tactics-round2-spec 4).
-- (Static parse result only; per-bot memory across ticks goes through wow.getVar/setVar.)
local cache = {}

local function loadBot(bot, low)
    local leader = store.leaderOf(bot)
    if leader then store.migrate(low, leader) end   -- once per (bot, leader) per state; before the revision
    local rev = wow.storeRev(low)
    local e = cache[low]
    if e and e.rev == rev and e.leader == leader then return e end
    local presets, _, all = rules.loadPresets(low, leader)
    local p = presets[rules.activeIndex(presets, all)]
    e = { rev = rev, leader = leader, enabled = rules.isEnabled(all), co = {}, nc = {} }
    if p then
        for _, name in ipairs({ "co", "nc" }) do
            local list = rules.parseList(p[name])
            for i = 1, #list do rules.compile(list[i]) end
            e[name] = list
        end
    end
    cache[low] = e
    return e
end

-- Drop cached rules of a bot (not required for correctness; revision checks already catch changes).
function interpreter.forget(low)
    cache[low] = nil
end

-- ----------------------------------------------------------------------------- evaluation environment

local Env = {}
Env.__index = Env

function Env:group()
    local g = self._group
    if not g then
        g = self.bot:group() or {}
        self._group = g
    end
    return g
end

function Env:attackers()
    local a = self._attackers
    if not a then
        a = self.bot:attackers() or {}
        self._attackers = a
    end
    return a
end

-- The tank: first alive group member with isTank(), a main tank wins (cached per call in env._tank; the
-- AI layer sets the same function on the instance, ai/utility.lua).
function Env:tank()
    local t = self._tank
    if t == nil then
        t = false
        local group = self:group()
        for i = 1, #group do
            local m = group[i]
            if m:isAlive() and m:isTank() then
                if not t or m:isMainTank() then t = m end
                if m:isMainTank() then break end
            end
        end
        self._tank = t
    end
    return t or nil
end

local function newEnv(bot, ctx)
    return setmetatable({ bot = bot, ctx = ctx, guid = bot:guid(), level = bot:level() or 0 }, Env)
end

-- ----------------------------------------------------------------------------- one rule

-- Is every id of the rule available at this level (and implemented)?
local function ruleUnlocked(r, level)
    if not rules.targetUnlocked(r.t, level) or not targets[r.t] then return false end
    if #r.c >= 2 and level < config.COND2_LEVEL then return false end
    for i = 1, #r.c do
        local id = r.c[i].id
        if not rules.conditionUnlocked(id, level) or not conditions[id] then return false end
    end
    return actions[r.a] ~= nil
end

local function passes(env, u, r)
    for i = 1, #r.c do
        local c = r.c[i]
        local impl = conditions[c.id]
        if not impl.allowDead and not u:isAlive() then return false end
        if not impl.check(env, u, c.value) then return false end
    end
    return true
end

-- First decision of a rule, or nil.
local function evaluateRule(env, r)
    local cands = targets[r.t](env)
    if not cands or #cands == 0 then return nil end
    for i = 1, #r.c do
        local impl = conditions[r.c[i].id]
        if impl.sort then cands = impl.sort(env, cands) or cands end
    end
    local build = actions[r.a]
    for i = 1, #cands do
        local u = cands[i]
        if u:valid() and passes(env, u, r) then
            local d = build(env, u, r)
            if d then return d end
        end
    end
    return nil
end

-- ----------------------------------------------------------------------------- entry point

-- Party window additions (party-window-spec 5.6-5.8), run before the rules on every tick, also for bots
-- with tactics disabled or empty lists: the outcome of the previous order, the class-AI veto refresh,
-- the once-per-login loot rules and the pending one-shot order (always the first decision, slot
-- ORDER_SLOT; rules follow as candidates 2..N).
-- Headless sim: outcome of the previous decision as counters
-- rule.<list>.<slot>.<reason> and rule_fires (rules executed "ok", orders excluded). No-op unless the
-- bot is watched by a running simulation (wow.metrics is absent until the C++ part is built).
local function countLast(low, last)
    local metrics = wow.metrics
    if not metrics or not metrics.active() then return end
    local reason = last.reason
    if not reason or reason == "" then reason = last.ok and "ok" or "failed" end
    metrics.add(low, "rule." .. tostring(last.list) .. "." .. tostring(last.slot) .. "." .. reason, 1)
    if last.slot == config.AI_SLOT then
        -- AI layer (ai-layer-spec 11): ai.<intent>.<reason>, ai_fires (ai_switches / ai_silent: ai/utility.lua)
        metrics.add(low, "ai." .. tostring(last.intent or "unknown") .. "." .. reason, 1)
        if last.ok and reason == "ok" then metrics.add(low, "ai_fires", 1) end
    elseif last.ok and reason == "ok" and last.slot ~= config.ORDER_SLOT then
        metrics.add(low, "rule_fires", 1)
    end
end

function interpreter.evaluate(bot, ctx)
    local now = ctx.now or wow.now()
    local low = bot:lowGuid()
    local e = loadBot(bot, low)
    if ctx.last then
        if ctx.last.slot == config.ORDER_SLOT then orders.onLast(bot, ctx.last) end
        ai.onLast(bot, low, ctx.last, now, e)   -- sets ctx.last.intent for slot AI_SLOT
        protocol.onLast(bot, ctx.last, now)
        countLast(low, ctx.last)
    end

    local listName = (ctx.state == "combat") and "co" or "nc"
    local env = newEnv(bot, ctx)
    env.low, env.cacheEntry, env.leader = low, e, e.leader
    veto.refresh(bot, env, now)
    loot.ensure(bot, low)
    style.ensure(bot, low, e.leader)   -- role / toggles / pull of this leader after a relog or talent change

    local out = {}
    local order = orders.decision(bot, listName, now)
    if order then out[1] = order end

    local list = e.enabled and e[listName] or {}
    local n = math.min(#list, config.slots(env.level))
    for i = 1, n do
        local r = list[i]
        if r.on and r.usable and ruleUnlocked(r, env.level) then
            local d = evaluateRule(env, r)
            if d then
                d.slot = i
                d.list = listName
                out[#out + 1] = d
                if d.verb == "wait" or #out >= config.MAX_CANDIDATES then break end
            end
        end
    end
    -- targets of this tick's rule candidates: a rule kick claims the unit it casts on (ai/utility.lua ruleKick)
    if ai.onRules then ai.onRules(env, out) end

    -- AI layer (ai-layer-spec 0): one extra candidate after the rules, combat only, never after a wait.
    if ctx.state == "combat" then
        if #out < config.MAX_CANDIDATES and (#out == 0 or out[#out].verb ~= "wait") then
            local d = ai.decide(env, listName, now)
            if d then out[#out + 1] = d end
        end
    else
        -- out of combat the AI may drink between waves (never a decision, tactics-round2-spec 1.4)
        if ai.decideNoncombat then ai.decideNoncombat(env, now) end
        ai.onNoncombat(low)
    end

    if config.DEBUG and #out > 0 then
        local parts = {}
        for i = 1, #out do
            parts[i] = out[i].list .. "#" .. out[i].slot .. ":" .. out[i].verb .. "(" .. (out[i].tag or "") .. ")"
        end
        wow.log(bot:name() .. " -> " .. table.concat(parts, " "))
    end

    if #out == 0 then return nil end
    return out
end

-- Self-check used by init.lua: catalogue ids without an implementation (they are hidden from CAT).
function interpreter.missingImplementations()
    local missing = {}
    for _, t in ipairs(catalog.targets) do
        if not targets[t.id] then missing[#missing + 1] = "target " .. t.id end
    end
    for _, c in ipairs(catalog.conditions) do
        if not conditions[c.id] then missing[#missing + 1] = "condition " .. c.id end
    end
    for _, s in ipairs(catalog.specials) do
        if not actions[s.id] then missing[#missing + 1] = "action " .. s.id end
    end
    return missing
end

return interpreter
