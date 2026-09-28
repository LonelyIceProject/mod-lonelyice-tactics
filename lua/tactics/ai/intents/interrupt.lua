-- AI intent interrupt (ai-layer-spec 6): stop an interruptible cast of an attacker. Stun entries of the kit
-- are used on non-elite, non-boss casters only. No walking into range (reach = false).
-- Coordination (tactics-round2-spec 2.4): a caster someone else claimed (heard / seen) is worth less, so a
-- deferred bot picks another caster when there is one; the chosen kick is claimed ("Прерываю: X!").

local config = wow.include("config.lua")
local common = wow.include("ai/common.lua")
local coord = wow.include("ai/coord.lua")

local I = { id = "interrupt", level = config.AI_INTENT_LEVEL.interrupt, category = "offense" }

function I.urgency(env, st)
    if #env.kit.interrupt == 0 then return 0 end
    local p = env.profile
    local att = env:attackers()
    local best, bestU = nil, 0
    local now = env.now
    for i = 1, #att do
        local u = att[i]
        if u:isAlive() then
            local id, interruptible, remaining, target = u:casting()
            if id and id ~= 0 and interruptible then
                local v = 0.7
                if target and target ~= "" then
                    if target == env.guid then
                        v = v + 0.2
                    else
                        local t = wow.unit(target)
                        if t and t:isHealer() then v = v + 0.2 end
                    end
                end
                if remaining and remaining < 1500 then v = v + 0.1 end
                -- without an interrupt rule 0.9 (spec 0.8): 0.63 still clears the slider-1 threshold 0.60
                -- for a plain cast on a dps; the 0.8 of the spec left it at 0.56 (never before the last 1.5 s)
                v = v * (p.interruptJob and 1 or 0.9)
                v = v * coord.factor(env, "int", u:guid(), now)
                if v > bestU then best, bestU = u, v end
            end
        end
    end
    env._intTarget = best
    return bestU
end

function I.build(env, st)
    local bot, u = env.bot, env._intTarget
    if not u or bot:isDead() or not u:valid() then return nil end
    local guid = u:guid()
    local tough = u:isElite() or u:isBoss()
    for _, e in ipairs(env.kit.interrupt) do
        if not (e.stun and tough) and common.allowed(env, e.rank, guid) and common.castable(env, e, u, common.OK) then
            return { verb = "cast", spell = e.rank, target = guid, reach = false }
        end
    end
    return nil
end

-- The decision is emitted this tick: claim the caster; a failed kick releases it ("Не успел прервать!").
function I.onPick(env, st, d, now)
    local u = env._intTarget
    if not d.target or not coord.claim(env, "int", d.target, now, "int_claim", { target = u and u:name() }) then
        return nil
    end
    return { kind = "int", target = d.target, fail = "int_fail" }
end

return I
