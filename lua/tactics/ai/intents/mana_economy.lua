-- AI intent mana_economy (tactics-round2-spec 1.2): a caster (above all the healer) manages its mana like a
-- player: a mana potion / gem when low, the class mana cooldown (Shadowfiend, Mana Tide Totem, Divine Plea,
-- Divine Illumination), a mana channel (Evocation, Hymn of Hope) when nothing hits it and the group is
-- safe, Innervate on the group's healer, and one "Нет маны!" callout per fight. Out of combat it drinks
-- between pulls (noncombat, called by ai.decideNoncombat). Enabled for healers from slider 1, for the
-- others from slider 2 (profile.lua). Never shadowed, outside the mana budget (5.8).

local config = wow.include("config.lua")
local profile = wow.include("profile.lua")
local common = wow.include("ai/common.lua")
local coord = wow.include("ai/coord.lua")
local protocol = wow.include("protocol.lua")

local I = { id = "mana_economy", level = config.AI_INTENT_LEVEL.mana_economy or 10, category = "mana",
            noShadow = true, noBudget = true }

local cfg = profile.cfg

local CD_FIGHT_MS = 4000       -- a mana cooldown not in the first seconds of a pull
local CD_ANY_BELOW = 30        -- ... on any fight below this mana
local CHANNEL_BELOW = 35       -- a channel only this low
local CHANNEL_GROUP_HP = 70    -- ... while the group's average hp is at least this
local INNERVATE_BELOW = 30     -- the healer's mana
local INNERVATE_OOM = 1.2      -- the healer said "out of mana"
local DRINK_RADIUS = 30        -- no hostile this close
local DRINK_SCAN_MS = 2000     -- hostile scan at most this often while waiting to drink

local function metric(low, key)
    local m = wow.metrics
    if m and m.active() then m.add(low, key, 1) end
end

-- Group hp for the channel: the newest trend sample (level >= 60, utility.lua) or a direct mean.
local function groupHp(env, st)
    local n = st.tAvg and #st.tAvg or 0
    if n > 0 then return st.tAvg[n] end
    return common.groupAvgHp(env)
end

function I.urgency(env, st)
    env._manaCands = nil
    local m = env.mana
    if not m then return 0 end
    local p, k, now = env.profile, env.kit, env.now
    local H = p.healer
    -- "out of mana" (no decision): a flag the party hears, once per fight
    if m < cfg(p, "MANA_OOM_PCT") and not st.om then
        st.om = 1
        coord.flag(env, "oom", now, "oom")
    end
    local cands, best = nil, 0
    local function add(u, sub, unit)
        cands = cands or {}
        cands[#cands + 1] = { u = u, sub = sub, unit = unit }
        if u > best then best = u end
    end
    if m < cfg(p, "MANA_POT_PCT") and #k.manaPotion > 0 then add(H and 0.85 or 0.5, "pot") end
    local cdOk = m < cfg(p, "MANA_CD_PCT") and (env.fightMs or 0) >= CD_FIGHT_MS
        and (env.boss or env.elite or env.nAttackers >= 2 or m < CD_ANY_BELOW)
    if cdOk and #k.manaCd > 0 then add(H and 0.7 or 0.45, "cd") end
    if cdOk and #k.manaChannel > 0 and m < CHANNEL_BELOW and not env.targetedMe then
        local avg = groupHp(env, st)
        if avg and avg >= CHANNEL_GROUP_HP then add(H and 0.65 or 0.4, "chan") end
    end
    if #k.manaCdFriend > 0 then
        local h = common.groupHealer(env)
        if h and h:isAlive() then
            local hm = (h:guid() == env.guid) and m or h:manaPct()
            if hm and hm < INNERVATE_BELOW then
                local v = 0.75
                if h:guid() ~= env.guid and coord.enabled(p) and coord.healerOom(env, now) then
                    v = v * INNERVATE_OOM
                end
                add(v, "inn", h)
            end
        end
    end
    if not cands then return 0 end
    table.sort(cands, function(a, b) return a.u > b.u end)
    env._manaCands = cands
    return best
end

local function castSelf(env, list, sub)
    for _, e in ipairs(list) do
        if common.allowed(env, e.rank, env.guid) and common.castable(env, e, env.bot, common.OK) then
            local d = { verb = "cast", spell = e.rank, target = env.guid, reach = false, _sub = sub }
            if not common.backedOff(env, d) then return d end
        end
    end
    return nil
end

-- The most urgent sub-action that can run now (a potion on cooldown falls through to the class cooldown).
function I.build(env, st)
    local bot, cands = env.bot, env._manaCands
    if not cands or bot:isDead() then return nil end
    local k = env.kit
    for _, c in ipairs(cands) do
        local d
        if c.sub == "pot" then
            for _, pot in ipairs(k.manaPotion) do
                local ok, reason = bot:canUse(pot.entry, bot)
                if ok and (reason or "ok") == "ok" then
                    d = { verb = "use", item = pot.entry, target = env.guid, reach = false, _sub = "pot" }
                    if not common.backedOff(env, d) then break end
                    d = nil
                end
            end
        elseif c.sub == "cd" then
            d = castSelf(env, k.manaCd, "cd")
        elseif c.sub == "chan" then
            d = castSelf(env, k.manaChannel, "chan")
        elseif c.sub == "inn" and c.unit and c.unit:valid() then
            local guid = c.unit:guid()
            for _, e in ipairs(k.manaCdFriend) do
                if common.allowed(env, e.rank, guid) and common.castable(env, e, c.unit, common.OK) then
                    d = { verb = "cast", spell = e.rank, target = guid, reach = false, _sub = "inn" }
                    if not common.backedOff(env, d) then break end
                    d = nil
                end
            end
        end
        if d then return d end
    end
    return nil
end

-- Executed ok: counters (mana_pot / mana_cd) and the callouts ("Пью зелье маны", "Озарение: X").
function I.onOk(env, low, d)
    local sub = d and d._sub
    if sub == "pot" then
        metric(low, "mana_pot")
        coord.say(env, "pot", nil, env.now)
    elseif sub == "cd" or sub == "chan" or sub == "inn" then
        metric(low, "mana_cd")
        if sub == "inn" and d.target ~= env.guid then
            local u = wow.unit(d.target)
            coord.say(env, "innervate", { target = u and u:valid() and u:name() or nil }, env.now)
        end
    end
end

-- ----------------------------------------------------------------------------- drink between pulls (1.4)

local scanAt = {}   -- low -> last hostile scan while waiting to drink (per Lua state)

function I.noncombat(env, now)
    local p = env.profile
    if not p or (p.ai or 0) < 1 then return nil end
    local m = env.mana
    if not m or m >= cfg(p, "DRINK_PCT") then return nil end
    local low, bot = env.low, env.bot
    local at = tonumber(wow.getVar(low, "ai_drink_at"))
    if at and now - at >= 0 and now - at < cfg(p, "DRINK_MIN_MS") then return nil end
    if bot:isDead() or bot:isMoving() then return nil end
    local s = scanAt[low]
    if s and now - s >= 0 and now - s < DRINK_SCAN_MS then return nil end
    scanAt[low] = now
    local near = bot:hostilesNear(DRINK_RADIUS)
    if near and #near > 0 then return nil end
    wow.setVar(low, "ai_drink_at", now)
    if protocol.runCommand(bot, "drink") then
        metric(low, "ai_drink")
        coord.say(env, "drink", nil, now)
    end
    return nil
end

return I
