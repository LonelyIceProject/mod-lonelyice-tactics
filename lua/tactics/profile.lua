-- Bot tactics / AI layer: the per-bot slider (store key "ai") and the profile the free layer reads,
-- inferred from the player's rules and the bot's behaviour toggles (ai-layer-spec 2, 3).
--
-- Slider: store key ai = "0".."3", optionally "N!" (level gate off; written by the sim driver only).
-- Missing / invalid = config.AI_DEFAULT. Effective value = min(stored, aiMax(level)) unless "!", and 0 when
-- the tactics switch is off (store key enabled = "0").
-- Deliberately does not include style.lua (style.lua includes this file: no include cycles); the style
-- toggles are read from bot:strategies("co") with the names of catalog.style.

local util = wow.include("util.lua")
local config = wow.include("config.lua")
local catalog = wow.include("catalog.lua")
local rules = wow.include("rules.lua")
local kit = wow.include("ai/kit.lua")

local profile = {}

local INTENT_IDS = { "preserve_self", "interrupt", "dispel", "mana_economy", "heal_priority", "focus_target",
                     "cooldown_burst", "position" }
local SAFETY_NET = { preserve_self = true, interrupt = true, dispel = true }
local PASSIVE_KEEP = { preserve_self = true, dispel = true, heal_priority = true, mana_economy = true }
local FRIEND_TARGETS = { ally = true, healer = true, leader = true }
local HEAL_LISTS = { healDirect = true, healHot = true, shield = true }

-- Labels live in catalog.aiPositions (WP2); re-exported as { [0] = { en, ru }, ... }.
profile.names = {}
for i = 0, 3 do
    local e = catalog.aiPositions and catalog.aiPositions[i]
    local label = e and e.label or {}
    profile.names[i] = { en = label.en or tostring(i), ru = label.ru or label.en or tostring(i),
                         label.en or tostring(i), label.ru or label.en or tostring(i) }
end

-- ----------------------------------------------------------------------------- store (per bot, per leader)
-- tactics-round2-spec 4.2: the keys a player configures are namespaced per leader by store.lua (RULES).
-- Resolved lazily (store.lua may include modules that include this file); until it exists the plain
-- wow.storeGet/Set keys are used.

local storeMod   -- nil = not resolved yet, false = missing

local function storeApi()
    if storeMod == nil then
        local ok, m = pcall(wow.include, "store.lua")
        if not ok and tostring(m):find("instruction limit", 1, true) then error(m, 0) end
        storeMod = (ok and type(m) == "table" and m.get and m.set and m.leaderOf) and m or false
    end
    return storeMod or nil
end
profile.storeApi = storeApi

-- Leader of a bot for the namespaced keys (nil: no leader known / store.lua missing).
function profile.leaderOf(bot)
    local s = storeApi()
    return s and s.leaderOf(bot) or nil
end

function profile.storeGet(bot, low, key)
    local s = storeApi()
    if s then return s.get(low, key, s.leaderOf(bot)) end
    return wow.storeGet(low, key)
end

function profile.storeSet(bot, low, key, data)
    local s = storeApi()
    if s then return s.set(low, key, data, s.leaderOf(bot)) end
    return wow.storeSet(low, key, data)
end

-- ----------------------------------------------------------------------------- config overrides (1.6)

local OVER_MAX = 32
local cfgName = {}   -- key -> "AI_" .. key

-- Store key "aicfg" = "KEY=number;KEY_2=number;..." (written by the sim sweep) -> { KEY = number } | nil
function profile.parseOver(text)
    if type(text) ~= "string" or text == "" then return nil end
    local over, n = nil, 0
    for k, v in text:gmatch("([^;=]+)=([^;]*)") do
        local num = tonumber(v)
        if num and k:match("^[A-Z][A-Z0-9_]*$") and n < OVER_MAX then
            over = over or {}
            over[k] = num
            n = n + 1
        end
    end
    return over
end

-- A tunable of the AI layer: p.over[key] (p.over[key .. "_" .. idx] with idx), else config["AI_" .. key]
-- (indexed by idx when given). Every AI_* read inside ai/** goes through this (the sweep varies it).
function profile.cfg(p, key, idx)
    local over = p and p.over
    if over then
        local v
        if idx then v = over[key .. "_" .. idx] else v = over[key] end
        if v ~= nil then return v end
    end
    local name = cfgName[key]
    if not name then
        name = "AI_" .. key
        cfgName[key] = name
    end
    local c = config[name]
    if idx then
        if type(c) == "table" then return c[idx] end
        return nil
    end
    return c
end
local cfg = profile.cfg

-- ----------------------------------------------------------------------------- slider

function profile.aiMax(level)
    level = level or 0
    if level < config.AI_LVL_PARTNER then return 1 end
    if level < config.AI_LVL_OWN then return 2 end
    return 3
end

-- Level at which slider position `value` becomes available.
function profile.aiLevel(value)
    if value >= 3 then return config.AI_LVL_OWN end
    if value >= 2 then return config.AI_LVL_PARTNER end
    return 0
end

-- "2!" -> 2, true; "3" -> 3, false; nil / bad -> AI_DEFAULT, false
function profile.parseAi(text)
    if type(text) == "string" then
        local d, bang = text:match("^([0-3])(!?)$")
        if d then return tonumber(d), bang == "!" end
    end
    return config.AI_DEFAULT, false
end

-- ai (effective), stored, aiMax, gateOff
function profile.effectiveAi(bot, low)
    low = low or bot:lowGuid()
    local stored, gateOff = profile.parseAi(profile.storeGet(bot, low, "ai"))
    local aiMax = profile.aiMax(bot:level() or 0)
    local ai = stored
    if not gateOff and ai > aiMax then ai = aiMax end
    if profile.storeGet(bot, low, "enabled") == "0" then ai = 0 end
    if ai > 0 and wow.include("manual.lua").get(bot, low) then ai = 0 end   -- manual mode (abilities-mirroring-spec 3.3)
    return ai, stored, aiMax, gateOff
end

-- 2.4: keep the bot evaluated while it has an order, or while the default slider applies to an empty store.
function profile.syncWake(bot, low)
    low = low or bot:lowGuid()
    local orderPending = wow.getVar(low, "order_spell") ~= nil
    local ai = profile.effectiveAi(bot, low)
    bot:wake(orderPending or (ai > 0 and wow.storeRev(low) == 0))
end

-- ok, code [, unlockLevel]. Codes: ok, bad_value, locked_ai (arg = level of that position), store_failed.
function profile.setAi(bot, low, value)
    low = low or bot:lowGuid()
    local v = util.toint(value)
    if not v or v < 0 or v > 3 then return false, "bad_value" end
    if v > profile.aiMax(bot:level() or 0) then return false, "locked_ai", profile.aiLevel(v) end
    if not profile.storeSet(bot, low, "ai", tostring(v)) then return false, "store_failed" end
    profile.syncWake(bot, low)
    return true, "ok"
end

-- ----------------------------------------------------------------------------- profile

local function isHealSpell(first)
    local lists = first and kit.classify(first)
    if not lists then return false end
    for i = 1, #lists do
        if HEAL_LISTS[lists[i]] then return true end
    end
    return false
end

local function condValue(r, id)
    for i = 1, #r.c do
        if r.c[i].id == id then return r.c[i].value, true end
    end
    return nil, false
end

-- Compiled rule lists of the active preset: from the interpreter's cache entry, else loaded here.
local function ruleLists(bot, low, e)
    if e and e.co then return e.co, e.nc end
    local presets, _, all = rules.loadPresets(low, profile.leaderOf(bot))
    local p = presets[rules.activeIndex(presets, all)]
    local out = {}
    for _, name in ipairs({ "co", "nc" }) do
        local list = rules.parseList(p and p[name] or "")
        for i = 1, #list do rules.compile(list[i]) end
        out[name] = list
    end
    return out.co, out.nc
end

local function readStyle(bot)
    local active = util.set(bot:strategies("co") or {})
    local s = {}
    for _, e in ipairs(catalog.style) do
        if e.list == "co" then s[e.key] = active[e.strategy] == true end
    end
    return s
end

-- Evidence of section 3.2 from one compiled rule.
local function evidence(p, r)
    local t, a = r.t, r.a
    local hp, hasHp = condValue(r, "hp_lt")
    local anyBoss = false
    if t == "foe_boss" then anyBoss = true end
    if hasHp and hp and a == "spell" and isHealSpell(r.x) then
        if t == "tank" then
            p.healEvidence = true
            p.weight.heal_priority = p.weight.heal_priority * 1.2
            p.watch.tank = math.max(p.watch.tank, hp + 15)
        elseif FRIEND_TARGETS[t] then
            p.healEvidence = true
            p.watch.ally = math.max(p.watch.ally, hp + 15)
        end
    end
    if t == "self" and hasHp and hp and (a == "item" or a == "spell") then
        p.caution = math.min(1, p.caution + 0.3)
        p.watch.self = math.max(p.watch.self, hp + 15)
        p.weight.preserve_self = 1 + p.caution
    end
    local _, casting = condValue(r, "casting")
    if r.side == "foe" and casting and a == "spell" then
        p.interruptJob = true
        p.weight.interrupt = 1.3
    end
    local dtype, dispel = condValue(r, "dispel")
    if (t == "ally" or t == "tank" or t == "self") and dispel and dtype and a == "spell" then
        p.dispelJob = true
        p.dispelTypes[dtype] = true
        p.weight.dispel = 1.3
    end
    if (t == "foe_skull" or t == "foe_moon") and a == "attack" then
        p.marks = true
        p.weight.focus_target = 1.3
    end
    if t == "foe_tank_tgt" and a == "attack" then p.assistTank = true end
    local _, mp = condValue(r, "mp_lt")
    if t == "self" and mp and a == "wait" then p.reserveBonus = p.reserveBonus + 15 end
    return anyBoss
end

local function build(bot, low, level, e, now)
    local ai, stored, aiMax, gateOff = profile.effectiveAi(bot, low)
    local p = {
        rev = e and e.rev or wow.storeRev(low), level = level,
        ai = ai, aiStored = stored, aiMax = aiMax, gateOff = gateOff,
        over = profile.parseOver(profile.storeGet(bot, low, "aicfg")),
        enabled = {}, weight = {},
        watch = { tank = config.AI_WATCH.tank, ally = config.AI_WATCH.ally, self = config.AI_WATCH.self },
        caution = 0, reserveBonus = 0, marks = false, assistTank = false,
        interruptJob = false, dispelJob = false, dispelTypes = {},
        style = readStyle(bot), styleAt = now,
    }
    p.threshold, p.delayMs = cfg(p, "THRESHOLD", ai), cfg(p, "DELAY_MS", ai)
    for _, id in ipairs(INTENT_IDS) do p.weight[id] = 1.0 end

    local anyBoss = false
    local co, nc = ruleLists(bot, low, e)
    for _, list in ipairs({ co, nc }) do
        for i = 1, #(list or {}) do
            local r = list[i]
            if r.on and r.usable then
                if evidence(p, r) then anyBoss = true end
            end
        end
    end
    if anyBoss then p.weight.cooldown_burst = p.weight.cooldown_burst * 1.2 end

    -- role (3.5)
    if p.healEvidence then p.role = "heal"
    elseif bot:isTank() then p.role = "tank"
    elseif bot:isHealer() then p.role = "heal"
    else p.role = "dps" end
    p.healer = p.role == "heal"

    -- style toggles (3.3)
    local s = p.style
    if s.save_mana then p.reserveBonus = p.reserveBonus + 15 end
    if s.dps_assist then p.assistTank = true end
    if s.focus then p.weight.focus_target = p.weight.focus_target * 1.2 end

    -- foresight (ai 3, level >= 60); the ai-3 reserve -10 is applied by the budget (5.8)
    if ai == 3 and level >= config.AI_TREND_LEVEL then
        for k, v in pairs(p.watch) do p.watch[k] = math.min(config.AI_WATCH_CAP, v + config.AI_WATCH_FORESIGHT) end
    end

    -- enabled intents (2.2, 2.3, 3.5)
    for _, id in ipairs(INTENT_IDS) do
        local on = ai >= 2 or (ai == 1 and SAFETY_NET[id] == true)
        -- mana economy (round 2, 1.2): healers from slider 1, the others from slider 2
        if id == "mana_economy" then on = ai >= 2 or (ai == 1 and p.healer) end
        if level < (config.AI_INTENT_LEVEL[id] or 1) then on = false end
        if s.passive and not PASSIVE_KEEP[id] then on = false end
        if id == "heal_priority" and not p.healer then on = false end
        if id == "focus_target" and p.role ~= "dps" then on = false end
        p.enabled[id] = on
    end
    return p
end

-- The cached profile of a bot. env.cacheEntry = the interpreter's rule cache entry (profile stored as
-- e.profile, dropped with the entry on a store revision change); rebuilt when the level changed and every
-- AI_PROFILE_STYLE_MS for the style toggles. Without a cache entry the profile is built fresh.
function profile.get(bot, env)
    env = env or {}
    local low = env.low or bot:lowGuid()
    local level = env.level or bot:level() or 0
    local now = (env.ctx and env.ctx.now) or wow.now()
    local e = env.cacheEntry
    local p = e and e.profile
    if p then
        local dt = now - p.styleAt
        if p.level == level and p.rev == e.rev and dt >= 0 and dt < config.AI_PROFILE_STYLE_MS then return p end
    end
    p = build(bot, low, level, e, now)
    if e then e.profile = p end
    return p
end

return profile
