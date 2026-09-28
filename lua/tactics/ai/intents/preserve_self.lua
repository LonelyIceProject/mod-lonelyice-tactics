-- AI intent preserve_self (ai-layer-spec 6): potion, defensive cooldown, own shield, a healer heals itself.
-- Never shadowed by rules; ignores the mana reserve.

-- Coordination (tactics-round2-spec 2.4): below 25% hp while something hits it the bot asks for help (a flag
-- the healer hears: "Помогите, бьют меня!", at most once per 10 s); when the healer said "out of mana" the
-- others get careful (weight x1.3).

local config = wow.include("config.lua")
local common = wow.include("ai/common.lua")
local kit = wow.include("ai/kit.lua")
local coord = wow.include("ai/coord.lua")

local I = { id = "preserve_self", level = config.AI_INTENT_LEVEL.preserve_self, category = "heal",
            noShadow = true }

local HELP_HP = 25
local HELP_EVERY_MS = 10000
local OOM_CAREFUL = 1.3

function I.urgency(env, st)
    local p = env.profile
    local now = env.now
    if env.hp and env.hp < HELP_HP and env.targetedMe and coord.enabled(p) then
        local dt = st.hp1 and now - st.hp1
        if not dt or dt < 0 or dt >= HELP_EVERY_MS then
            st.hp1 = now
            coord.flag(env, "help", now, "help")
        end
    end
    local u = common.hpUrgency(st, "a1", env.hp, p.watch.self, p)
    if u <= 0 then return 0 end
    u = u * (1 + p.caution)
    if u > 1 then u = 1 end
    if env.targetedMe then u = u + 0.2 end
    if coord.enabled(p) and coord.healerOom(env, now) then u = u * OOM_CAREFUL end
    return u
end

local function castSelf(env, e)
    return { verb = "cast", spell = e.rank, target = env.guid, reach = false }
end

function I.build(env, st)
    local bot, k, h = env.bot, env.kit, env.hp or 100
    if bot:isDead() then return nil end
    if h < 50 then
        for _, pot in ipairs(k.potion) do
            local ok, reason = bot:canUse(pot.entry, bot)
            if ok and (reason or "ok") == "ok" then
                return { verb = "use", item = pot.entry, target = env.guid, reach = false }
            end
        end
    end
    local isTank = env.profile.role == "tank"
    for _, e in ipairs(k.defensive) do
        if not (isTank and kit.TANK_UNSAFE[e.first])
            and (kit.cdClass(e.recovery) ~= "big" or h < 25) and common.allowed(env, e.rank, env.guid)
            and common.castable(env, e, bot, common.OK) then
            return castSelf(env, e)
        end
    end
    for _, e in ipairs(k.shield) do
        local block = kit.SHIELD_BLOCK[e.first]
        if not bot:hasAura(e.first) and not (block and bot:hasAura(block))
            and common.allowed(env, e.rank, env.guid) and common.castable(env, e, bot, common.OK) then
            return castSelf(env, e)
        end
    end
    if env.profile.healer and h < 40 then
        for _, e in ipairs(k.healDirect) do
            if (not env.mana or env.mana >= e.cost) and common.allowed(env, e.rank, env.guid)
                and common.castable(env, e, bot, common.OK_MOVING) then
                return castSelf(env, e)
            end
        end
    end
    return nil
end

return I
