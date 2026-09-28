-- AI intent focus_target (ai-layer-spec 6, role dps): switch to the skull mark, else (assist tank) to the
-- tank's victim. At most one switch per AI_FOCUS_MIN_MS (state key f, set when the attack executed).
-- Round 2 (tactics-round2-spec 2.4): without "assist tank", a loose caster hitting a non-tank is taken by
-- one dps who says so ("Беру дальнего: X"); the others hear it and defer. A fleeing target at low hp is
-- called out once per target and fight ("X убегает!").

local config = wow.include("config.lua")
local profile = wow.include("profile.lua")
local coord = wow.include("ai/coord.lua")

local I = { id = "focus_target", level = config.AI_INTENT_LEVEL.focus_target, category = "target" }

local FAR_URGENCY = 0.45
local FAR_RANGE = 30        -- yards: a loose caster this close to the bot
local FAR_FROM_VICTIM = 10  -- yards: "ranged" = standing this far from its victim (or casting)
local RUNNER_HP = 20

local function hostileAlive(env, u)
    return u ~= nil and u:isAlive() and u:isHostileTo(env.bot)
end

-- A caster attacking a non-tank that nobody tanks (not the tank's victim), nearest to the bot.
local function looseCaster(env)
    local bot = env.bot
    local att = env:attackers()
    local best, bestD
    for i = 1, #att do
        local u = att[i]
        if u:isAlive() then
            local v = u:victim()
            if v and not v:isTank() then
                local d = bot:distance(u)
                if d and d <= FAR_RANGE and (not bestD or d < bestD) then
                    local id = u:casting()
                    local dv = u:distance(v)
                    if (id and id ~= 0) or (dv and dv > FAR_FROM_VICTIM) then best, bestD = u, d end
                end
            end
        end
    end
    return best
end

-- Runner (2.4): the current target flees at low hp, away from the tank (distance grew since the last tick).
local function runner(env, st)
    local t = env.bot:currentTarget()
    if not t or (t:hpPct() or 100) >= RUNNER_HP or not t:isAlive() or not t:isMoving() then
        st.rd = nil
        return
    end
    local tank = env:tank()
    local d = tank and tank:distance(t)
    if not d then return end
    local d10 = math.floor(d * 10)
    local prev = st.rd
    st.rd = d10
    local low = t:lowGuid()
    if prev and d10 > prev and st.rn ~= low then
        st.rn = low
        coord.say(env, "runner", { target = t:name() }, env.now)
    end
end

function I.urgency(env, st)
    env._focus, env._focusFar = nil, nil
    local p, bot = env.profile, env.bot
    local coordOn = coord.enabled(p)
    if coordOn then runner(env, st) end
    if st.f then
        local dt = env.now - st.f
        if dt >= 0 and dt < profile.cfg(p, "FOCUS_MIN_MS") then return 0 end
    end
    local wanted, u = bot:mark(7), 0
    if hostileAlive(env, wanted) then
        u = p.marks and 0.8 or 0.5
    else
        wanted = nil
        if p.assistTank then
            local tank = env:tank()
            if tank and tank:guid() ~= env.guid then
                local v = tank:victim()
                if hostileAlive(env, v) then wanted, u = v, 0.6 end
            end
        elseif coordOn then
            local c = looseCaster(env)
            if c then
                wanted, u = c, FAR_URGENCY * coord.factor(env, "tgt", c:guid(), env.now)
                env._focusFar = true
            end
        end
    end
    if not wanted then return 0 end
    local cur = bot:currentTarget()
    if cur and cur:guid() == wanted:guid() then return 0 end
    env._focus = wanted
    return u
end

function I.build(env, st)
    local u = env._focus
    if not u or env.bot:isDead() or not u:valid() then return nil end
    return { verb = "attack", target = u:guid() }
end

function I.onPick(env, st, d, now)
    if not env._focusFar or not d.target then return nil end
    local u = env._focus
    if not coord.claim(env, "tgt", d.target, now, "tgt_far", { target = u and u:name() }) then return nil end
    return { kind = "tgt", target = d.target }
end

return I
