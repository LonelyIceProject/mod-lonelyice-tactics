-- Bot tactics / AI layer: party coordination, human-like and deliberately imperfect (tactics-round2-spec 2).
--
-- Bots SAY what they are about to do (party chat callouts), SEE a nearby teammate start doing it, and ASK for
-- things ("Нет маны!", "Помогите!"). The party board holds CLAIMS (I do X to target T) and FLAGS (my state
-- is S). A claim heard or seen by another bot only lowers that bot's urgency for the same job (DEFER factor):
-- nobody abstains, so two bots still double up sometimes, like people. Hearing and seeing take time and
-- sometimes fail; misses are deterministic per (reader, claim). Enabled at effective slider >= 2 only.
--
-- Board: var "pb" on the OWNER's low guid, "kind:targetHex:byLow:at:until:spoken;..." (<= 12 entries,
-- <= 1024 bytes); party chat rate window: var "pbc" = "w:<windowStartMs>:<n>". Per-bot memory in the AI
-- state (utility.lua STATE_KEYS): cl (last callout at), cn (callouts this fight), cc<i> (callout i last at).
-- Coordination changes urgencies only; it never makes a decision and never touches rules or C++.

local profile = wow.include("profile.lua")
local callouts = wow.include("ai/callouts.lua")
local common = wow.include("ai/common.lua")

local coord = {}
local cfg = profile.cfg

local VAR, RATE = "pb", "pbc"
local MAX_ENTRIES, MAX_BYTES = 12, 1024
local WINDOW_MS = 10000
local YOUNG_LEVEL = 40
local FUTURE_MS = 5000     -- an entry stamped this far ahead of `now` is stale (clock of another state)

local function metric(low, key)
    local m = wow.metrics
    if m and m.active() then m.add(low, key, 1) end
end

-- pcall that never swallows the host's instruction limit.
local function try(fn, ...)
    local ok, a, b = pcall(fn, ...)
    if not ok and tostring(a):find("instruction limit", 1, true) then error(a, 0) end
    return ok, a, b
end

-- Strength of the coordination: the effective slider clamped to the rows of the constants (2 or 3).
local function level(p)
    return (p.ai or 0) >= 3 and 3 or 2
end

function coord.enabled(p)
    return p ~= nil and (p.ai or 0) >= 2 and not (p.style and p.style.passive)
end

local function ownerLow(env)
    local o = env._owner
    if o == nil then
        o = env.bot:ownerLow() or 0
        env._owner = o
    end
    return o
end

-- ----------------------------------------------------------------------------- board

local function parse(raw, now)
    local list = {}
    if raw and raw ~= "" then
        for kind, target, by, at, untl, spoken in raw:gmatch("(%a+):(%x*):(%d+):(%-?%d+):(%-?%d+):([01])") do
            untl, at = tonumber(untl), tonumber(at)
            if untl >= now and at <= now + FUTURE_MS then
                list[#list + 1] = { kind = kind, target = target, by = tonumber(by), at = at, untl = untl,
                                    spoken = spoken == "1" }
            end
        end
    end
    return list
end

local function serialize(list)
    local parts = {}
    for i = 1, #list do
        local e = list[i]
        parts[i] = string.format("%s:%s:%d:%d:%d:%s", e.kind, e.target, e.by, e.at, e.untl, e.spoken and "1" or "0")
    end
    return table.concat(parts, ";")
end

-- The board of this tick (parsed once: one getVar + one gmatch), expired entries dropped. nil when the bot
-- has no owner (outside any owned group) or coordination is off.
function coord.load(env, now)
    local b = env._board
    if b ~= nil then return b or nil end
    if not coord.enabled(env.profile) then
        env._board = false
        return nil
    end
    local owner = ownerLow(env)
    if owner == 0 then
        env._board = false
        return nil
    end
    b = { owner = owner, list = parse(wow.getVar(owner, VAR), now) }
    env._board = b
    return b
end

local function write(env, b, now)
    local list = b.list
    table.sort(list, function(x, y) return x.at < y.at end)
    while #list > MAX_ENTRIES do table.remove(list, 1) end
    local s = serialize(list)
    while #s > MAX_BYTES and #list > 0 do
        table.remove(list, 1)
        s = serialize(list)
    end
    wow.setVar(b.owner, VAR, s ~= "" and s or nil)
end

-- ----------------------------------------------------------------------------- perception (2.1)

local function memberByLow(env, low)
    local group = env.group and env:group() or env.bot:group() or {}
    for i = 1, #group do
        local m = group[i]
        if m:lowGuid() == low then return m end
    end
    return nil
end

-- Did this bot hear / see the entry by now? Own entries: always. Spoken: after HEAR_MS, missed MISS_PCT of
-- the time. Unspoken: only within SEE_RANGE of the claimer, after SEE_MS, missed twice as often. Below
-- level 40 every latency is YOUNG_MS longer. Cached on the entry (the board is parsed per bot and tick).
local function perceives(env, e, now)
    if e.by == env.low then return true end
    local seen = e.seen
    if seen ~= nil then return seen end
    local p = env.profile
    local sl = level(p)
    local delay = e.spoken and cfg(p, "COORD_HEAR_MS", sl) or cfg(p, "COORD_SEE_MS")
    local miss = cfg(p, "COORD_MISS_PCT", sl) or 0
    if (env.level or 0) < YOUNG_LEVEL then delay = delay + (cfg(p, "COORD_YOUNG_MS") or 0) end
    seen = true
    if not e.spoken then
        miss = miss * 2
        local m = memberByLow(env, e.by)
        local d = m and env.bot:distance(m)
        if not d or d > cfg(p, "COORD_SEE_RANGE") then seen = false end
    end
    if seen and now - e.at < (delay or 0) then seen = false end
    if seen and (env.low * 7919 + e.at) % 100 < miss then seen = false end
    -- the time check changes with `now`: cache only the stable outcomes (a miss, out of sight)
    if not seen and now - e.at < (delay or 0) then return false end
    e.seen = seen
    return seen
end
coord.perceives = perceives

-- ----------------------------------------------------------------------------- API (2.3)

-- 1.0 when no live claim by another bot on (kind, target) is heard / seen; else the DEFER factor.
function coord.factor(env, kind, targetHex, now)
    local b = coord.load(env, now)
    if not b then return 1 end
    local list = b.list
    for i = 1, #list do
        local e = list[i]
        if e.kind == kind and e.target == targetHex and e.by ~= env.low and e.untl >= now and perceives(env, e, now) then
            metric(env.low, "coord_defers")
            return cfg(env.profile, "COORD_DEFER", level(env.profile)) or 1
        end
    end
    return 1
end

-- Deterministic "dice" for the say decision (no RNG in the sandbox): 0..99.
local function roll(low, now)
    return (low * 104729 + math.floor(now) * 31) % 100
end

local function add(env, b, kind, targetHex, now, untl, calloutId, args, alwaysSay)
    local list = b.list
    local mine, double = nil, false
    for i = 1, #list do
        local e = list[i]
        if e.kind == kind and e.target == targetHex and e.untl >= now then
            if e.by == env.low then mine = e else double = true end
        end
    end
    if mine then
        mine.untl = untl
        write(env, b, now)
        return true
    end
    if double then metric(env.low, "coord_doubles") end
    metric(env.low, "coord_claims")
    local spoken = false
    if calloutId then
        local p = env.profile
        if alwaysSay or roll(env.low, now) < (cfg(p, "COORD_SAY_PCT", level(p)) or 0) then
            -- a suppressed callout still writes the claim: silent claims are only "seen"
            spoken = coord.say(env, calloutId, args, now)
        end
    end
    list[#list + 1] = { kind = kind, target = targetHex, by = env.low, at = now, untl = untl, spoken = spoken }
    write(env, b, now)
    return true
end

-- I am doing `kind` to `targetHex` (until now + CLAIM_MS); maybe say the callout.
function coord.claim(env, kind, targetHex, now, calloutId, args)
    if not targetHex or targetHex == "" then return false end
    local b = coord.load(env, now)
    if not b then return false end
    return add(env, b, kind, targetHex, now, now + cfg(env.profile, "COORD_CLAIM_MS"), calloutId, args, false)
end

-- My claim failed: remove it; maybe say the fail callout.
function coord.release(env, kind, targetHex, now, calloutId, args)
    local b = coord.load(env, now)
    if not b then return false end
    local list, found = b.list, false
    for i = #list, 1, -1 do
        local e = list[i]
        if e.kind == kind and e.target == targetHex and e.by == env.low then
            table.remove(list, i)
            found = true
        end
    end
    if not found then return false end
    write(env, b, now)
    if calloutId then
        local p = env.profile
        if roll(env.low, now + 1) < (cfg(p, "COORD_SAY_PCT", level(p)) or 0) then coord.say(env, calloutId, args, now) end
    end
    return true
end

-- My state is `kind` (oom / help): a flag on myself until now + FLAG_MS; the callout is always tried (asking
-- for something is said aloud; the rate limits still apply).
function coord.flag(env, kind, now, calloutId, args)
    local b = coord.load(env, now)
    if not b then return false end
    return add(env, b, kind, env.guid, now, now + cfg(env.profile, "COORD_FLAG_MS"), calloutId, args, true)
end

-- A heard / seen live flag of that kind on that unit.
function coord.flagged(env, kind, targetHex, now)
    local b = coord.load(env, now)
    if not b then return false end
    local list = b.list
    for i = 1, #list do
        local e = list[i]
        if e.kind == kind and e.target == targetHex and e.untl >= now and perceives(env, e, now) then return true end
    end
    return false
end

-- Remove every entry of (kind, target), whoever wrote it (a help flag answered by a heal).
function coord.clear(env, kind, targetHex, now)
    local b = coord.load(env, now)
    if not b then return false end
    local list, found = b.list, false
    for i = #list, 1, -1 do
        if list[i].kind == kind and list[i].target == targetHex then
            table.remove(list, i)
            found = true
        end
    end
    if found then write(env, b, now) end
    return found
end

-- The group's healer (not the bot itself) flagged "out of mana" and this bot heard it (cached per tick).
function coord.healerOom(env, now)
    local v = env._hOom
    if v ~= nil then return v end
    v = false
    if coord.load(env, now) then
        local h = common.groupHealer(env)
        if h and h:guid() ~= env.guid then v = coord.flagged(env, "oom", h:guid(), now) end
    end
    env._hOom = v
    return v
end

-- ----------------------------------------------------------------------------- chat (2.5)

local function ownerLocale(env)
    local ok, o = try(env.bot.owner, env.bot)
    if not ok or not o then return nil end
    local ok2, loc = try(o.locale, o)
    return ok2 and loc or nil
end

-- Rate-limited party chat. false when suppressed (slider < 2, out of combat except "drink", per-bot gap,
-- per-fight cap, repeat guard, party window) or when the server has no bot:sayParty yet.
function coord.say(env, calloutId, args, now)
    local p = env.profile
    if not coord.enabled(p) then return false end
    local e = callouts.BY_ID[calloutId]
    if not e then return false end
    if env.noncombat and calloutId ~= "drink" then return false end
    now = now or env.now or wow.now()
    local st = env.state or {}
    local dt = st.cl and now - st.cl
    if dt and dt >= 0 and dt < cfg(p, "SAY_MIN_MS") then return false end
    local fightMax = cfg(p, "SAY_FIGHT_MAX") or 0
    if fightMax > 0 and (st.cn or 0) >= fightMax then return false end
    local ck = "cc" .. e.index
    dt = st[ck] and now - st[ck]
    if dt and dt >= 0 and dt < cfg(p, "SAY_REPEAT_MS") then return false end
    local owner = ownerLow(env)
    if owner == 0 then return false end
    local ws, n = (wow.getVar(owner, RATE) or ""):match("^w:(%-?%d+):(%d+)$")
    ws, n = tonumber(ws), tonumber(n)
    if not ws or now < ws or now - ws >= WINDOW_MS then ws, n = now, 0 end
    if n >= cfg(p, "SAY_PARTY_MAX") then return false end
    local text = callouts.text(calloutId, callouts.lang(ownerLocale(env)), args, cfg(p, "SAY_MAX_BYTES"))
    if not text then return false end
    local fn = env.bot.sayParty
    if not fn then return false end
    local ok, said = try(fn, env.bot, text)
    if not ok or not said then return false end
    st.cl, st.cn, st[ck] = now, (st.cn or 0) + 1, now
    wow.setVar(owner, RATE, string.format("w:%d:%d", ws, n + 1))
    metric(env.low, "callouts")
    return true
end

coord.CALLOUT_KEYS = {}
for i = 1, #callouts.LIST do coord.CALLOUT_KEYS[i] = "cc" .. i end

return coord
