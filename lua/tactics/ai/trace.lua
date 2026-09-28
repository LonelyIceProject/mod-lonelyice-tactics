-- Bot tactics / AI layer: ring of AI decisions and per-fight stats in bot vars (ai-layer-spec 7).
--   var ai_trace: up to AI_TRACE_MAX entries "at,intentIdx,score100,obj,targetHex,result" joined by ";",
--                 newest last. intentIdx 0 = a rule fire (obj = "<list>.<slot>"), 1..8 = intents in IDS
--                 order, 30/31 = slider-3 auto aoe on/off. obj = spell id, "i<entry>" for items, else the verb.
--                 result = "p" (pending), "ok" or the C++ reason.
--   var ai_stat:  "f=<fights>;n=<n1..n8 summed>;lf=<n1..n8 of the last fight>;sw=<switches>;q=<silent ticks>;
--                 k=<ticks>;l=<intentIdx>,<score100>,<at>" written when a fight ends (ai.onNoncombat).
-- Read-only API for WP2: aitrace.entries(low, now), aitrace.stats(low).

local config = wow.include("config.lua")

local aitrace = {}

-- Intent ids in INTENTS order (tie-break priority, ai-layer-spec 6); the index is the id in vars. Round 2
-- (tactics-round2-spec 1.2) inserted mana_economy at 4 and moved the aoe notes from 8/9 to 30/31.
aitrace.IDS = { "preserve_self", "interrupt", "dispel", "mana_economy", "heal_priority", "focus_target",
                "cooldown_burst", "position" }
aitrace.INDEX = {}
for i, id in ipairs(aitrace.IDS) do aitrace.INDEX[id] = i end
aitrace.SPECIAL = { [30] = "aoe on", [31] = "aoe off" }
aitrace.AOE_ON, aitrace.AOE_OFF = 30, 31
-- ai_stat written before round 2 carries 7 counters (no mana_economy): read them into the new layout
local LEGACY_N, LEGACY_INSERT = 7, 4

local VAR, STAT = "ai_trace", "ai_stat"
local MAX_BYTES = 1024

local function fmt(n)
    return string.format("%d", math.floor((tonumber(n) or 0) + 0.5))
end

-- Append one entry, keep AI_TRACE_MAX entries and <= MAX_BYTES.
local function push(low, entry)
    local raw = wow.getVar(low, VAR)
    raw = (raw and raw ~= "") and (raw .. ";" .. entry) or entry
    local _, seps = raw:gsub(";", ";")
    local drop = seps + 1 - config.AI_TRACE_MAX
    while (drop > 0 or #raw > MAX_BYTES) and raw:find(";", 1, true) do
        raw = raw:sub(raw:find(";", 1, true) + 1)
        drop = drop - 1
    end
    if #raw > MAX_BYTES then raw = "" end
    wow.setVar(low, VAR, raw ~= "" and raw or nil)
end

-- An AI decision emitted this tick (result pending until ai.onLast).
function aitrace.decided(low, d, idx, score, now)
    local obj = d.spell or (d.item and ("i" .. d.item)) or d.verb or ""
    push(low, table.concat({ fmt(now), idx, fmt(score * 100), obj, d.target or "", "p" }, ","))
end

-- Outcome of the pending (newest) AI entry.
function aitrace.result(low, reason)
    local raw = wow.getVar(low, VAR)
    if not raw then return end
    local head = raw:match("^(.*),p$")
    if head then wow.setVar(low, VAR, head .. "," .. (tostring(reason or "failed"):gsub("[,;]", "_"))) end
end

-- Remove the pending entry (the decision never ran: a rule candidate executed first).
function aitrace.drop(low)
    local raw = wow.getVar(low, VAR)
    if not raw or not raw:find(",p$") then return end
    local head = raw:match("^(.*);[^;]*$")
    wow.setVar(low, VAR, (head and head ~= "") and head or nil)
end

-- A rule executed ok (shown in the same timeline).
function aitrace.rule(low, list, slot, now)
    push(low, table.concat({ fmt(now), 0, 0, tostring(list) .. "." .. tostring(slot), "", "ok" }, ","))
end

-- Slider-3 automatic strategy switch (idx AOE_ON / AOE_OFF).
function aitrace.note(low, idx, now)
    push(low, table.concat({ fmt(now), idx, 0, "", "", "ok" }, ","))
end

-- { {at, kind = "ai"|"rule", name = intentId | "co#3" | "aoe on", ok, reason, target, score, spell, item}, ... }
-- oldest first.
function aitrace.entries(low, now)
    local out = {}
    local raw = wow.getVar(low, VAR)
    if not raw or raw == "" then return out end
    for e in raw:gmatch("[^;]+") do
        local at, idx, score, obj, target, result = e:match("^(%-?%d+),(%d+),(%-?%d+),([^,]*),([^,]*),([^,]*)$")
        if at then
            idx = tonumber(idx)
            local rule = idx == 0
            local rec = { at = tonumber(at), kind = rule and "rule" or "ai", ok = result == "ok",
                          reason = (result == "p") and "pending" or result, target = target ~= "" and target or nil,
                          score = (tonumber(score) or 0) / 100, intentIdx = idx }
            if rule then
                rec.name = obj:gsub("%.", "#")
                rec.score = nil
            else
                rec.name = aitrace.IDS[idx] or aitrace.SPECIAL[idx] or tostring(idx)
                if obj:match("^%d+$") then rec.spell = tonumber(obj)
                elseif obj:match("^i%d+$") then rec.item = tonumber(obj:sub(2)) end
            end
            out[#out + 1] = rec
        end
    end
    table.sort(out, function(a, b) return a.at < b.at end)
    return out
end

-- ----------------------------------------------------------------------------- per-fight stats

local function nums(text, n)
    local t = {}
    local i = 0
    for v in (text or ""):gmatch("[^,]+") do
        i = i + 1
        t[i] = tonumber(v) or 0
    end
    for k = 1, n do t[k] = t[k] or 0 end
    return t, i
end

-- Counters per intent; a legacy 7-entry list gets a 0 for mana_economy.
local function counters(text, n)
    local t, found = nums(text, n)
    if found == LEGACY_N and n == #aitrace.IDS and n == LEGACY_N + 1 then
        table.insert(t, LEGACY_INSERT, 0)
        t[n + 1] = nil
    end
    return t, found
end

local function parseStat(raw)
    local kv = {}
    for k, v in (raw or ""):gmatch("(%w+)=([^;]*)") do kv[k] = v end
    local n = #aitrace.IDS
    local cn, found = counters(kv.n, n)
    local l = kv.l and nums(kv.l, 3) or nil
    -- legacy layout: the last intent index shifts past the inserted mana_economy
    if l and found == LEGACY_N and l[1] >= LEGACY_INSERT then l[1] = l[1] + 1 end
    return { fights = tonumber(kv.f) or 0, n = cn, lf = (counters(kv.lf, n)), sw = tonumber(kv.sw) or 0,
             q = tonumber(kv.q) or 0, k = tonumber(kv.k) or 0, l = l }
end

-- Fold the fight counters of a state table (ai-layer-spec 5.3) into var ai_stat.
function aitrace.endFight(low, st)
    local s = parseStat(wow.getVar(low, STAT))
    s.fights = s.fights + 1
    for i = 1, #aitrace.IDS do
        local f = st["n" .. i] or 0
        s.n[i] = s.n[i] + f
        s.lf[i] = f
    end
    s.sw = s.sw + (st.sw or 0)
    s.q = s.q + (st.q or 0)
    s.k = s.k + (st.k or 0)
    if st.l then s.l = { st.l, st.ls or 0, st.la or 0 } end
    local parts = { "f=" .. fmt(s.fights), "n=" .. table.concat(s.n, ","), "lf=" .. table.concat(s.lf, ","),
                    "sw=" .. fmt(s.sw), "q=" .. fmt(s.q), "k=" .. fmt(s.k) }
    if s.l then parts[#parts + 1] = "l=" .. fmt(s.l[1]) .. "," .. fmt(s.l[2]) .. "," .. fmt(s.l[3]) end
    wow.setVar(low, STAT, table.concat(parts, ";"))
end

local function byId(arr)
    local t = {}
    for i, id in ipairs(aitrace.IDS) do t[id] = arr[i] or 0 end
    return t
end

-- { fights, fires = {[intentId] = n}, switches, silent, ticks, last = {intentId, score, at} | nil,
--   lastFight = {[intentId] = n}, current = { fires = {...}, switches, silent, ticks } (fight in progress) }
function aitrace.stats(low)
    local s = parseStat(wow.getVar(low, STAT))
    local out = { fights = s.fights, fires = byId(s.n), lastFight = byId(s.lf), switches = s.sw, silent = s.q,
                  ticks = s.k }
    if s.l and aitrace.IDS[s.l[1]] then
        local id = aitrace.IDS[s.l[1]]
        out.last = { id, s.l[2] / 100, s.l[3], intentId = id, score = s.l[2] / 100, at = s.l[3] }
    end
    local raw = wow.getVar(low, "ai")
    if raw and raw ~= "" then
        local kv = {}
        for k, v in raw:gmatch("(%w+)=([^;]*)") do kv[k] = tonumber(v) end
        local cur = { fires = {}, switches = kv.sw or 0, silent = kv.q or 0, ticks = kv.k or 0, fightStart = kv.fs }
        for i, id in ipairs(aitrace.IDS) do cur.fires[id] = kv["n" .. i] or 0 end
        out.current = cur
        if kv.l and aitrace.IDS[kv.l] then
            local id = aitrace.IDS[kv.l]
            out.last = { id, (kv.ls or 0) / 100, kv.la or 0, intentId = id, score = (kv.ls or 0) / 100, at = kv.la or 0 }
        end
    end
    return out
end

return aitrace
