-- AI intent dispel (ai-layer-spec 6): remove a harmful aura the kit can dispel from a group member.
-- Coordination (tactics-round2-spec 2.4): a member someone else is dispelling (heard / seen claim) is worth
-- less; the chosen dispel is claimed ("Снимаю яд: Элара").

local config = wow.include("config.lua")
local common = wow.include("ai/common.lua")
local coord = wow.include("ai/coord.lua")

local I = { id = "dispel", level = config.AI_INTENT_LEVEL.dispel, category = "heal" }

local MAGIC = 1

function I.urgency(env, st)
    local types = env.kit.dispelTypes
    if not next(types) then return 0 end
    local p = env.profile
    local near = common.nearby(env)
    local bestU, bestUnit, bestType = 0, nil, nil
    local now = env.now
    -- auras() allocates a table per aura: read at most AI_DISPEL_SCAN_MAX members per tick, the bot, tanks
    -- and healers first (pass 1), then the others in group order (pass 2)
    local budget = config.AI_DISPEL_SCAN_MAX
    for pass = 1, 2 do
        for i = 1, #near do
            if budget <= 0 then break end
            local m = near[i]
            local important = m:guid() == env.guid or m:isTank() or m:isHealer()
            if important == (pass == 1) then
                budget = budget - 1
                local auras = m:auras()
                if auras then
                    local mBest, mType = 0, nil
                    for j = 1, #auras do
                        local a = auras[j]
                        local t = a.dispel
                        if t and types[t] and not a.positive then
                            local v = 0.6
                            if important then v = v + 0.2 end
                            if p.dispelTypes[t] then v = v + 0.1 end
                            if t == MAGIC and ((a.remaining or 0) > 8000 or a.remaining == -1) then v = v + 0.1 end
                            if v > mBest then mBest, mType = v, t end
                        end
                    end
                    if mBest > bestU then
                        -- one factor per member (the claim is on the member, whatever the aura)
                        mBest = mBest * coord.factor(env, "dsp", m:guid(), now)
                        if mBest > bestU then bestU, bestUnit, bestType = mBest, m, mType end
                    end
                end
            end
        end
    end
    env._dispUnit, env._dispType = bestUnit, bestType
    return bestU
end

function I.build(env, st)
    local bot, u, t = env.bot, env._dispUnit, env._dispType
    if not u or bot:isDead() or not u:valid() then return nil end
    local guid = u:guid()
    for _, e in ipairs(env.kit.dispelFriend) do
        if e.types[t] and common.allowed(env, e.rank, guid) and common.castable(env, e, u, common.OK) then
            return { verb = "cast", spell = e.rank, target = guid, reach = false }
        end
    end
    return nil
end

function I.onPick(env, st, d, now)
    local u = env._dispUnit
    if not d.target or not coord.claim(env, "dsp", d.target, now, "dsp_claim",
        { target = u and u:name(), type = env._dispType }) then
        return nil
    end
    return { kind = "dsp", target = d.target }
end

return I
