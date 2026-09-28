-- AI intent heal_priority (ai-layer-spec 6, healers only): the tank below its watch threshold, else the
-- lowest ally. Strong heal (or a guard cooldown on the tank) when the target is low, else cheap spells.
-- The healer walks to its tank (reach = true); allies out of range are skipped (reach = false).
-- Round 2: rank-down of heals when mana runs low and the target is safe (tactics-round2-spec 1.3); a member
-- that called for help (coordination flag) is more urgent, and healing it answers the call (2.4).

local config = wow.include("config.lua")
local common = wow.include("ai/common.lua")
local kit = wow.include("ai/kit.lua")
local profile = wow.include("profile.lua")
local coord = wow.include("ai/coord.lua")

local I = { id = "heal_priority", level = config.AI_INTENT_LEVEL.heal_priority, category = "heal" }

local ALLY_FACTOR = 0.85
local HELP_BONUS = 0.2

function I.urgency(env, st)
    local p = env.profile
    local tank = env:tank()
    local uT, uA = 0, 0
    if tank then uT = common.hpUrgency(st, "ht", tank:hpPct(), p.watch.tank, p) end
    -- lowest ally in heal range (common.nearby), excluding the bot unless it is the lowest
    local group = common.nearby(env)
    local low, lowH, selfH = nil, nil, env.hp
    for i = 1, #group do
        local m = group[i]
        if m:isAlive() and m:guid() ~= env.guid then
            local h = m:hpPct()
            if h and (not lowH or h < lowH) then low, lowH = m, h end
        end
    end
    if selfH and (not lowH or selfH < lowH) then low, lowH = env.bot, selfH end
    if low then uA = common.hpUrgency(st, "ha", lowH, p.watch.ally, p) * ALLY_FACTOR end
    -- tank first; an ally in a worse state than the tank wins (its factor already favours the tank)
    local u, target, isTank
    if uT > 0 and uT >= uA then u, target, isTank = uT, tank, true
    elseif uA > 0 then u, target, isTank = uA, low, tank ~= nil and low:guid() == tank:guid()
    else
        env._healTarget = nil
        return 0
    end
    local mf = 1
    if env.mana then mf = 0.7 + 0.3 * common.clamp((env.mana - env.reserve) / 40, 0, 1) end
    u = u * mf
    if env.trendBad then u = u * 1.2 end
    -- "Помогите!" heard from the target
    env._healHelp = false
    if coord.enabled(p) and coord.flagged(env, "help", target:guid(), env.now) then
        env._healHelp = true
        u = math.min(1, u + HELP_BONUS)
    end
    env._healTarget, env._healIsTank = target, isTank
    local h = target:hpPct() or 100
    env._healExempt = isTank or h < 30
    return u
end

local function pick(env, u, guid, list, accept, cond)
    for _, e in ipairs(list) do
        if (not cond or cond(e)) and common.allowed(env, e.rank, guid) and common.castable(env, e, u, accept) then
            return e
        end
    end
    return nil
end

-- Rank-down (1.3): below RANKDOWN_PCT mana a safe target gets a lower rank of the chosen heal, index
-- k = clamp(round(n * (100 - h) / 60), 1, n) of the n known ranks. Vetoes were checked on the entry's rank.
function I.rankFor(env, e, h, emergency)
    local ranks = e.ranks
    if emergency or not env.mana or not ranks or #ranks < 2 then return e.rank end
    if env.mana >= profile.cfg(env.profile, "RANKDOWN_PCT") then return e.rank end
    local n = #ranks
    local k = common.clamp(math.floor(n * (100 - h) / 60 + 0.5), 1, n)
    return ranks[k].id
end

function I.build(env, st)
    local bot, u = env.bot, env._healTarget
    if not u or bot:isDead() or not u:valid() or not u:isAlive() then return nil end
    local k = env.kit
    local guid = u:guid()
    local isTank = env._healIsTank
    local accept = isTank and common.OK_MOVING_RANGE or common.OK_MOVING
    local h = u:hpPct() or 100
    local emergency = (isTank and h < env.profile.watch.tank - 10) or h < 40
    local e, direct
    if h < 50 then
        if isTank and h < 30 then e = pick(env, u, guid, k.guard, isTank and common.OK_MOVING_RANGE or common.OK) end
        if not e then
            -- strongest direct heal: highest cost first, cast time <= 3 s
            for i = #k.healDirect, 1, -1 do
                local c = k.healDirect[i]
                if c.castTime <= 3000 and common.allowed(env, c.rank, guid) and common.castable(env, c, u, accept) then
                    e, direct = c, true
                    break
                end
            end
        end
    else
        e = pick(env, u, guid, k.shield, accept, function(c)
            local block = kit.SHIELD_BLOCK[c.first]
            return not c.selfOnly and not u:hasAura(c.first) and not (block and u:hasAura(block))
        end)
        e = e or pick(env, u, guid, k.healHot, accept, function(c) return not u:hasAura(c.first) end)
        if not e then
            e = pick(env, u, guid, k.healDirect, accept)
            direct = e ~= nil
        end
    end
    if not e then return nil end
    local spell = e.rank
    -- the cheap branch always ranks down; the strong branch only outside an emergency
    if direct then spell = I.rankFor(env, e, h, h < 50 and emergency) end
    return { verb = "cast", spell = spell, target = guid, reach = isTank and true or false }
end

-- A heal landed on a member that called for help: answer ("Лечу: X") and take the flag down.
function I.onOk(env, low, d)
    if not d or not d.target or not coord.enabled(env.profile) then return end
    if coord.flagged(env, "help", d.target, env.now) then
        local u = wow.unit(d.target)
        coord.say(env, "heal_ack", { target = u and u:valid() and u:name() or nil }, env.now)
        coord.clear(env, "help", d.target, env.now)
    end
end

return I
