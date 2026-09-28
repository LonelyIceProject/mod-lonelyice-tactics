-- Bot tactics / AI layer: small helpers shared by utility.lua and the intents (ai-layer-spec 5, 6).
-- No game policy here beyond the hysteresis / urgency curve every hp-driven intent uses.

local config = wow.include("config.lua")
local profile = wow.include("profile.lua")

local common = {}
local cfg = profile.cfg

function common.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Urgency of an hp-driven intent (ai-layer-spec 5.4). Below the watch threshold: 0.5 + 0.5 * deficit
-- (deficit = (w - h) / w), so crossing the engage point is worth more than the slider-2 threshold and the
-- slider-1 threshold (0.6) needs a 20% deeper drop. Inside the hysteresis band (w <= h < w + AI_HYST) an
-- armed intent keeps AI_ARMED_URGENCY (continues with cheap spells at sliders 2-3). `key` is the armed flag
-- in the state table. Returns 0 when not armed. `p` = the profile (AI_HYST / AI_ARMED_URGENCY overrides).
function common.hpUrgency(st, key, h, w, p)
    if not h then
        st[key] = nil
        return 0
    end
    if h < w then
        st[key] = 1
        return 0.5 + 0.5 * common.clamp((w - h) / w, 0, 1)
    end
    if st[key] == 1 and h < w + cfg(p, "HYST") then
        return cfg(p, "ARMED_URGENCY")
    end
    st[key] = nil
    return 0
end

-- Is the decision's spell allowed by the player's vetoes (ai-layer-spec 5.7)?
function common.allowed(env, spell, targetHex)
    if not spell then return true end
    return not env.veto.check(env.low, spell, targetHex)
end

-- canCast of a kit entry on a unit with the accepted reasons (set). Returns true when castable.
function common.castable(env, entry, u, accept)
    if not entry.rank or entry.rank == 0 then return false end
    local ok, reason = env.bot:canCast(entry.rank, u)
    if not ok then return false end
    return accept[reason or "ok"] == true
end

common.OK = { ok = true }
common.OK_MOVING = { ok = true, moving = true }
common.OK_MOVING_RANGE = { ok = true, moving = true, range = true }

-- Cooldown class rule of the budget (ai-layer-spec 5.8): big only on a boss, an elite fought for 8 s, or
-- when the fight goes badly; medium on 3+ attackers, elites and bosses; small always.
function common.cdAllowed(env, class)
    if class == "big" then
        return env.boss or (env.elite and (env.fightMs or 0) >= 8000) or env.trendBad or false
    end
    if class == "medium" then
        return env.nAttackers >= 3 or env.elite or env.boss or false
    end
    return true
end

-- Alive group members within config.AI_SCAN_RANGE of the bot (the bot itself included), cached on env for
-- the tick. Unit:group() is the whole raid; heals and dispels beyond that range cannot land anyway (AI casts
-- on non-tank members never walk: reach = false), so dispel / heal_priority scan only this list.
function common.nearby(env)
    local list = env._near
    if list then return list end
    list = {}
    local bot, group, range = env.bot, env:group(), config.AI_SCAN_RANGE
    for i = 1, #group do
        local m = group[i]
        if m:isAlive() then
            if m:guid() == env.guid then
                list[#list + 1] = m
            else
                local d = bot:distance(m)
                if d and d <= range then list[#list + 1] = m end
            end
        end
    end
    env._near = list
    return list
end

-- The healer of the group near the bot (round 2, 1.2): the bot itself when it heals (profile role), else
-- the first alive member with isHealer() within AI_SCAN_RANGE. Cached on env for the tick; nil when none.
function common.groupHealer(env)
    local h = env._healer
    if h ~= nil then return h or nil end
    h = false
    if env.profile and env.profile.healer then
        h = env.bot
    else
        local near = common.nearby(env)
        for i = 1, #near do
            local m = near[i]
            if m:isHealer() then
                h = m
                break
            end
        end
    end
    env._healer = h
    return h or nil
end

-- Mean hp of the alive group members (the whole group, not only those in range); nil when none.
function common.groupAvgHp(env)
    local group = env:group()
    local sum, n = 0, 0
    for i = 1, #group do
        local m = group[i]
        if m:isAlive() then sum, n = sum + (m:hpPct() or 0), n + 1 end
    end
    if n == 0 then return nil end
    return sum / n
end

-- Failure backoff key of a decision (utility.lua): spell, item or a move verb; nil for the others.
function common.decisionKey(d)
    if d.spell then return "s" .. tostring(d.spell) end
    if d.item then return "i" .. tostring(d.item) end
    if d.verb == "move" or d.verb == "follow" then return "v" .. d.verb end
    return nil
end

-- Is this decision still in its failure backoff (env.badUntil = the bot's backoff table, set by decide)?
-- Lets an intent fall through to its next option instead of losing the tick.
function common.backedOff(env, d)
    local bad = env.badUntil
    if not bad then return false end
    local key = common.decisionKey(d)
    local t = key and bad[key]
    local now = env.now or 0
    return t ~= nil and now < t and t - now <= (config.AI_FAIL_BACKOFF_MS or 8000)
end

-- Squared 2D distance between two positions.
function common.dist2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return dx * dx + dy * dy
end

return common
