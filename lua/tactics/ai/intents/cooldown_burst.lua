-- AI intent cooldown_burst (ai-layer-spec 6): offensive cooldowns on bosses / elites / long fights.
-- The cooldown class rule of the budget (5.8) picks big before medium when allowed.
-- Round 2 (tactics-round2-spec 2.4): says "Жгу кулдауны" when it pops them; when the healer called
-- "out of mana" the others hold their cooldowns a little (x0.8).

local config = wow.include("config.lua")
local common = wow.include("ai/common.lua")
local coord = wow.include("ai/coord.lua")

local I = { id = "cooldown_burst", level = config.AI_INTENT_LEVEL.cooldown_burst, category = "offense" }

local OOM_HOLD = 0.8

function I.urgency(env, st)
    local k = env.kit
    if #k.burst == 0 and #k.burstMedium == 0 then return 0 end
    if not env.bot:currentTarget() then return 0 end
    local u = env.boss and 0.9 or (env.elite and 0.5 or 0.1)
    u = u * ((env.fightMs or 0) > 5000 and 1 or 0.3)
    if env.trendBad then u = u * 1.3 end
    if env.profile.style.aoe and env.nAttackers >= 3 then u = u * 1.2 end
    if coord.enabled(env.profile) and coord.healerOom(env, env.now) then u = u * OOM_HOLD end
    return u
end

function I.build(env, st)
    local bot, k = env.bot, env.kit
    if bot:isDead() then return nil end
    for _, pass in ipairs({ { list = k.burst, class = "big" }, { list = k.burstMedium, class = "medium" } }) do
        if common.cdAllowed(env, pass.class) then
            for _, e in ipairs(pass.list) do
                if common.allowed(env, e.rank, env.guid) and common.castable(env, e, bot, common.OK) then
                    return { verb = "cast", spell = e.rank, target = env.guid, reach = false, _cd = pass.class }
                end
            end
        end
    end
    return nil
end

function I.onPick(env, st, d, now)
    coord.say(env, "cd_burst", nil, now)
    return nil
end

return I
