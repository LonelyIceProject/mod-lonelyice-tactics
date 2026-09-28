-- Bot tactics / AI layer: AISTAT (ai-layer-spec 8) and the access to the AI core APIs used by the
-- protocol modules (style.lua, trace.lua): profile.lua (slider, section 3.4) and ai/trace.lua (AI trace
-- and stats, section 7.3). Both are resolved lazily at call time (profile.lua does not include style.lua,
-- so there is no cycle; the lazy lookup only keeps the stand-ins below usable). When a file is missing
-- (older script set) a small stand-in keeps the protocol working (slider stored, no AI stats).
--
-- AISTAT <bot> -> AISTAT <bot> <ai> <role> <threshold100> <reserve> <fires> <last> <fight>
--   fires = intentId:n;...   last = intentId,score100,agoMs   fight = fights,switches,silentPct

local util = wow.include("util.lua")
local config = wow.include("config.lua")
local catalog = wow.include("catalog.lua")
local protocol = wow.include("protocol.lua")
local store = wow.include("store.lua")

local aistat = {}
local handlers = protocol.handlers

-- pcall (first result only) that never swallows the instruction limit of the host.
local function try(fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then
        local err = tostring(res)
        if err:find("instruction limit", 1, true) then error(err, 0) end
        return false, err
    end
    return true, res
end
aistat.try = try

-- ----------------------------------------------------------------------------- stand-ins

local LVL2 = config.AI_LVL_PARTNER or 20
local LVL3 = config.AI_LVL_OWN or 40
local THRESHOLD = config.AI_THRESHOLD or { [1] = 0.60, [2] = 0.40, [3] = 0.25 }

local stubProfile = { stub = true }

function stubProfile.aiMax(level)
    level = level or 0
    if level < (config.AI_LVL_PARTNER or 20) then return 1 end
    if level < (config.AI_LVL_OWN or 40) then return 2 end
    return 3
end

function stubProfile.parseAi(text)
    local n, bang = tostring(text or ""):match("^(%d)(!?)$")
    n = tonumber(n)
    if not n or n > 3 then return config.AI_DEFAULT or 2, false end
    return n, bang == "!"
end

function stubProfile.effectiveAi(bot, low)
    low = low or bot:lowGuid()
    local leader = store.leaderOf(bot)   -- per (bot, leader) keys, tactics-round2-spec 4
    local stored, gateOff = stubProfile.parseAi(store.get(low, "ai", leader))
    local max = stubProfile.aiMax(bot:level())
    local ai = gateOff and stored or math.min(stored, max)
    if store.get(low, "enabled", leader) == "0" then ai = 0 end
    return ai, stored, max, gateOff
end

function stubProfile.setAi(bot, low, value)
    value = tonumber(value)
    if not value or value ~= math.floor(value) or value < 0 or value > 3 then return false, "bad_value" end
    if value > stubProfile.aiMax(bot:level()) then return false, "locked_ai" end
    if not store.set(low, "ai", tostring(value), store.leaderOf(bot)) then return false, "store_failed" end
    return true, "ok"
end

function stubProfile.syncWake(bot, low) end

local stubTrace = { stub = true }
function stubTrace.entries(low, now) return {} end
function stubTrace.stats(low) return nil end

-- ----------------------------------------------------------------------------- resolution

local resolved = {}

local function resolve(path, stub)
    local m = resolved[path]
    if m then return m end
    local ok, mod = try(wow.include, path)
    if ok and type(mod) == "table" then
        m = mod
    else
        wow.warn("AI layer: " .. path .. " not available, using a stand-in (" .. tostring(mod):sub(1, 120) .. ")")
        m = stub
    end
    resolved[path] = m
    return m
end

function aistat.profile()
    return resolve("profile.lua", stubProfile)
end

function aistat.aitrace()
    return resolve("ai/trace.lua", stubTrace)
end

-- Level at which slider position `value` (0..3) becomes available.
function aistat.levelOf(value)
    if value == 3 then return LVL3 end
    if value == 2 then return LVL2 end
    return 0
end

-- "<ai>,<aiStored>,<aiMax>,<lvl2>,<lvl3>" and "0:label:hint;1:...;..." (STYLE fields 6-7).
function aistat.styleFields(bot, low, lang)
    local ai, stored, max = aistat.profile().effectiveAi(bot, low)
    local names = {}
    for i = 0, 3 do
        local e = catalog.aiPositions[i]
        names[#names + 1] = i .. ":" .. util.esc(util.L(e.label, lang)) .. ":" .. util.esc(util.L(e.hint, lang))
    end
    return table.concat({ ai or 0, stored or 0, max or 1, LVL2, LVL3 }, ","), table.concat(names, ";")
end

-- Score as an integer x100 ("" when absent). Scores are ~0..2; values above 10 are already x100.
local function score100(s)
    s = tonumber(s)
    if not s then return "" end
    if s <= 10 then s = s * 100 end
    return tostring(math.floor(s + 0.5))
end
aistat.score100 = score100

-- ----------------------------------------------------------------------------- AISTAT

local function roleOf(bot, prof)
    if prof and (prof.role == "tank" or prof.role == "heal" or prof.role == "dps") then return prof.role end
    if bot:isTank() then return "tank" end
    if bot:isHealer() then return "heal" end
    return "dps"
end

-- The cached profile when profile.lua can build one outside evaluate (nil otherwise).
local function profileOf(profile, bot, low)
    if not profile.get then return nil end
    local ok, p = try(profile.get, bot, { bot = bot, low = low, level = bot:level() or 0 })
    if ok and type(p) == "table" then return p end
    return nil
end

function aistat.build(bot, low, now)
    local profile = aistat.profile()
    local ai = profile.effectiveAi(bot, low) or 0
    local prof = profileOf(profile, bot, low)
    local threshold = 0
    if ai > 0 then
        threshold = (prof and prof.threshold) or THRESHOLD[ai] or 0
    end
    -- mana reserve on trash (5.8), without the per-tick trend
    local reserve = 0
    if ai > 0 then
        reserve = (config.AI_RESERVE_TRASH or 35) + ((prof and prof.reserveBonus) or 0) - (ai == 3 and 10 or 0)
        reserve = math.max(5, math.min(60, reserve))
    end

    local st = aistat.aitrace().stats(low) or {}
    local fires = {}
    -- fires of this fight (in combat: stats.current) or of the last fight; totals when neither is known
    local counts = (st.current and st.current.fires) or st.lastFight or st.fires or {}
    for _, it in ipairs(catalog.intents) do
        local n = tonumber(counts[it.id]) or 0
        if n > 0 then fires[#fires + 1] = it.id .. ":" .. math.floor(n) end
    end
    local last = ""
    local l = st.last
    if type(l) == "table" then
        local id = l.intentId or l.intent or l.id or l[1]
        local at = tonumber(l.at or l[3])
        if id and id ~= "" and id ~= 0 then
            if type(id) == "number" then id = catalog.intents[id] and catalog.intents[id].id or tostring(id) end
            local ago = at and math.max(0, math.floor(now - at)) or ""
            last = table.concat({ util.esc(id), score100(l.score or l[2]), ago }, ",")
        end
    end
    local ticks = tonumber(st.ticks) or 0
    local silentPct = ticks > 0 and math.floor((tonumber(st.silent) or 0) * 100 / ticks + 0.5) or 0
    local fight = table.concat({ math.floor(tonumber(st.fights) or 0), math.floor(tonumber(st.switches) or 0),
        silentPct }, ",")
    return table.concat({ "AISTAT", low, ai, roleOf(bot, prof), math.floor(threshold * 100 + 0.5), reserve,
        table.concat(fires, ";"), last, fight }, "\t")
end

handlers.AISTAT = function(req, f)
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), "AISTAT", "bad_bot") end
    protocol.send(req.low, aistat.build(bot, low, wow.now()))
end

return aistat
