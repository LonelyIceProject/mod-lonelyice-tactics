-- Bot tactics: target selectors (spec section 8, "Targets").
-- Each selector is  function(env) -> array of unit handles in preference order.
-- env (built by the interpreter once per evaluate call):
--   env.bot       the evaluating Bot handle
--   env.ctx       the evaluate ctx table
--   env.guid      bot:guid() (cached)
--   env:group()   bot:group() (cached per call)
--   env:attackers() bot:attackers() (cached per call)
-- Selectors must return a NEW table (the interpreter may sort it in place).
-- Labels, side and level gate live in catalog.lua.

local util = wow.include("util.lua")

local targets = {}

local function alive(list)
    return util.filter(list, function(u) return u:isAlive() end)
end

targets.self = function(env)
    return { env.bot }
end

-- Whole group incl. self and the leader, dead members included (for resurrection rules).
targets.ally = function(env)
    return util.copy(env:group())
end

targets.tank = function(env)
    local list = util.filter(env:group(), function(u) return u:isTank() end)
    -- main tank first
    return util.sortBy(list, function(u) return u:isMainTank() and 0 or 1 end)
end

targets.healer = function(env)
    return util.filter(env:group(), function(u) return u:isHealer() end)
end

targets.leader = function(env)
    local o = env.bot:owner()
    if o then return { o } end
    return {}
end

targets.foe_cur = function(env)
    local t = env.bot:currentTarget()
    if t then return { t } end
    return {}
end

-- A unit's target if it is a live enemy of the bot: what it attacks, else what it has selected.
local function hostileTargetOf(env, u)
    if not u then return {} end
    local t = u:victim() or u:selection()
    if t and t:isAlive() and t:isHostileTo(env.bot) then return { t } end
    return {}
end

targets.foe_leader_tgt = function(env)
    return hostileTargetOf(env, env.bot:owner() or env.bot:leader())
end

targets.foe_tank_tgt = function(env)
    local tanks = targets.tank(env)
    for i = 1, #tanks do
        local list = hostileTargetOf(env, tanks[i])
        if #list > 0 then return list end
    end
    return {}
end

targets.foe_near = function(env)
    local bot = env.bot
    local list = alive(env:attackers())
    return util.sortBy(list, function(u) return bot:distance(u) end)
end

targets.foe_me = function(env)
    local me = env.guid
    return util.filter(env:attackers(), function(u)
        local v = u:victim()
        return v ~= nil and v:guid() == me
    end)
end

targets.foe_healer = function(env)
    return util.filter(env:attackers(), function(u)
        local v = u:victim()
        return v ~= nil and v:isHealer()
    end)
end

targets.foe_skull = function(env)
    local m = env.bot:mark(7)
    if m then return { m } end
    return {}
end

targets.foe_moon = function(env)
    local m = env.bot:mark(4)
    if m then return { m } end
    return {}
end

-- Bosses first, then elites.
targets.foe_boss = function(env)
    local list = util.filter(env:attackers(), function(u) return u:isBoss() or u:isElite() end)
    return util.sortBy(list, function(u) return u:isBoss() and 0 or 1 end)
end

return targets
