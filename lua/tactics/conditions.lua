-- Bot tactics: conditions (spec section 8, "Conditions").
-- Each entry:
--   check(env, u, v) -> bool   u = candidate unit handle, v = parsed rule value:
--                               param "num"    -> number
--                               param "spell"  -> spell id (first rank)
--                               param "spellid"-> spell id (first rank; any spell, e.g. an enemy cast)
--                               param "dispel" -> DispelType number (1 magic, 2 curse, 3 disease, 4 poison)
--                               param "none"   -> nil
--   sort(env, list)  optional   reorders the candidate list before checks (sort modifier)
--   allowDead        optional   true = the candidate does not have to be alive
-- Labels, parameter kind, limits and level gate live in catalog.lua.

local util = wow.include("util.lua")
local config = wow.include("config.lua")

local conditions = {}

conditions.any = {
    check = function(env, u, v) return true end,
}

conditions.hp_lt = {
    check = function(env, u, v)
        local p = u:hpPct()
        return p ~= nil and p < v
    end,
}

conditions.hp_ge = {
    check = function(env, u, v)
        local p = u:hpPct()
        return p ~= nil and p >= v
    end,
}

-- Sort modifier: candidates by HP percent ascending; always true.
conditions.lowest = {
    check = function(env, u, v) return true end,
    sort = function(env, list)
        return util.sortBy(list, function(u) return u:hpPct() end)
    end,
}

conditions.mp_lt = {
    check = function(env, u, v)
        local p = u:manaPct()
        return p ~= nil and p < v
    end,
}

conditions.dead = {
    allowDead = true,
    check = function(env, u, v) return u:isDead() end,
}

conditions.no_aura = {
    check = function(env, u, v) return not u:hasAura(v) end,
}

conditions.has_aura = {
    check = function(env, u, v) return u:hasAura(v) == true end,
}

-- Some aura of that dispel type that is worth removing: negative on friends, positive on foes.
conditions.dispel = {
    check = function(env, u, v)
        local friendly = (u:guid() == env.guid) or u:isFriendlyTo(env.bot)
        local auras = u:auras()
        if not auras then return false end
        for i = 1, #auras do
            local a = auras[i]
            if a.dispel == v and (a.positive and true or false) ~= friendly then
                return true
            end
        end
        return false
    end,
}

-- Class shown on the unit frame (UnitClass works on NPCs too).
conditions.class_is = {
    check = function(env, u, v) return u:class() == v end,
}

-- Has a mana bar: what a player sees to tell casters apart.
conditions.caster = {
    check = function(env, u, v)
        local m = u:maxPower(0)
        return m ~= nil and m > 0
    end,
}

-- UnitCreatureType. Needs the creatureType binding (server build of 2026-09-25 evening or later).
conditions.ctype_is = {
    check = function(env, u, v)
        local ok, t = pcall(function() return u:creatureType() end)
        return ok and t == v
    end,
}

conditions.casting = {
    check = function(env, u, v)
        local id, interruptible = u:casting()
        return id ~= nil and id ~= 0 and interruptible == true
    end,
}

conditions.dist_gt = {
    check = function(env, u, v)
        if u:guid() == env.guid then return false end
        local d = env.bot:distance(u)
        return d ~= nil and d > v
    end,
}

-- Attackers within NEAR_RADIUS yards of the unit.
conditions.near_ge = {
    check = function(env, u, v)
        local attackers = env:attackers()
        local n = 0
        for i = 1, #attackers do
            local a = attackers[i]
            if a:isAlive() then
                local d = u:distance(a)
                if d ~= nil and d <= config.NEAR_RADIUS then
                    n = n + 1
                    if n >= v then return true end
                end
            end
        end
        return false
    end,
}

conditions.combat_gt = {
    check = function(env, u, v)
        return (env.ctx.combatMs or 0) > v * 1000
    end,
}

-- ----------------------------------------------------------------------------- round 2 (tactics-round2-spec 3)
-- "env-level" conditions look at the party / the bot itself and ignore the candidate unit (it still has to
-- be alive unless the condition sets allowDead).

-- First alive healer of the group (the bot itself counts) has mana below v %; false without a healer.
conditions.healer_mp_lt = {
    check = function(env, u, v)
        local g = env:group()
        for i = 1, #g do
            local m = g[i]
            if m:isAlive() and m:isHealer() then
                local p = m:manaPct()
                return p ~= nil and p < v
            end
        end
        return false
    end,
}

-- The tank (main tank first, Env:tank) has HP below v %.
conditions.tank_hp_lt = {
    check = function(env, u, v)
        local t = env:tank()
        if not t then return false end
        local p = t:hpPct()
        return p ~= nil and p < v
    end,
}

conditions.my_hp_lt = {
    check = function(env, u, v)
        local p = env.bot:hpPct()
        return p ~= nil and p < v
    end,
}

-- false for bots without a mana bar (manaPct nil)
conditions.my_mp_lt = {
    check = function(env, u, v)
        local p = env.bot:manaPct()
        return p ~= nil and p < v
    end,
}

conditions.me_aura = {
    check = function(env, u, v) return env.bot:hasAura(v) == true end,
}

conditions.me_no_aura = {
    check = function(env, u, v) return not env.bot:hasAura(v) end,
}

-- The candidate lacks the bot's own aura of that spell (any rank): my HoT / DoT is missing.
conditions.no_aura_mine = {
    check = function(env, u, v) return not u:hasAura(v, true, env.guid) end,
}

-- First rank of a spell id (static, cached per state; enemy spells without a chain map to themselves).
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

-- The candidate is casting (or channeling) that spell, any rank; v = first rank (validateList normalizes).
conditions.casting_spell = {
    check = function(env, u, v)
        local id = u:casting()
        return id ~= nil and id ~= 0 and firstOf(id) == v
    end,
}

-- Casting anything, interruptible or not.
conditions.casting_any = {
    check = function(env, u, v)
        local id = u:casting()
        return id ~= nil and id ~= 0
    end,
}

conditions.moving = {
    check = function(env, u, v) return u:isMoving() == true end,
}

-- Alive enemies in the fight (the bot's attackers list, no radius) at least v.
conditions.foes_ge = {
    check = function(env, u, v)
        local attackers = env:attackers()
        local n = 0
        for i = 1, #attackers do
            if attackers[i]:isAlive() then
                n = n + 1
                if n >= v then return true end
            end
        end
        return false
    end,
}

-- ----------------------------------------------------------------------------- manual rotations
-- abilities-mirroring-spec 2.3 (catalogue entries: basics.lua). attacking / in_melee look at the candidate;
-- the others at the bot itself (the candidate only has to be alive).
local basics = wow.include("basics.lua")

conditions.attacking = {
    check = function(env, u, v) return basics.isAttacking(env.bot, u) end,
}

conditions.in_melee = {
    check = function(env, u, v)
        if u:guid() == env.guid or not basics.has(env.bot, "inMeleeRange") then return false end
        return env.bot:inMeleeRange(u) == true
    end,
}

conditions.has_pet = {
    check = function(env, u, v) return basics.pet(env.bot) ~= nil end,
}

conditions.pet_hp_lt = {
    check = function(env, u, v)
        local pet = basics.pet(env.bot)
        local p = pet and pet:hpPct()
        return p ~= nil and p < v
    end,
}

-- Own resource in percent (rage / energy / mana / runic power: the bot's power type).
local function powerPct(bot)
    local max = bot:maxPower()
    if not max or max <= 0 then return nil end
    return 100 * (bot:power() or 0) / max
end

conditions.power_ge = {
    check = function(env, u, v)
        local p = powerPct(env.bot)
        return p ~= nil and p >= v
    end,
}

conditions.power_lt = {
    check = function(env, u, v)
        local p = powerPct(env.bot)
        return p ~= nil and p < v
    end,
}

-- The bot knows the spell (any rank) and its highest rank is off cooldown.
conditions.cd_ready = {
    check = function(env, u, v)
        local rank = env.bot:highestRank(v)
        if not rank or rank == 0 then return false end
        return (env.bot:cooldown(rank) or 0) == 0
    end,
}

-- Stance / form / presence / aspect: an aura of the bot (same test as me_aura).
conditions.stance_is = {
    check = function(env, u, v) return env.bot:hasAura(v) == true end,
}

conditions.autoshooting = {
    check = function(env, u, v) return basics.autoRepeat(env.bot) ~= 0 end,
}

return conditions
