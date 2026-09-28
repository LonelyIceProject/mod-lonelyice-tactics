-- Bot tactics / AI layer: the free layer of intents (ai-layer-spec 5). Called by interpreter.lua:
--   ai.onLast(bot, low, last, now [, entry])  outcome of the previous tick: commitment, rule shadow, stats,
--                                             sets last.intent for FIRED / metrics (before protocol.onLast);
--                                             intent.onOk callbacks, failed claims released (round 2, 2.4)
--   ai.decide(env, listName, now)              nil | one decision (slot AI_SLOT, tag "ai:<intent>")
--   ai.decideNoncombat(env, now)               out of combat (round 2, 1.4): never a decision; the mana
--                                             economy may run the whitelisted "drink" command
--   ai.onNoncombat(low)                        folds the fight counters into ai_stat, clears the state var
--   ai.onRules(env, out)                       optional (interpreter): the rule candidates of this tick, so a
--                                             rule-driven kick is announced on the exact caster
-- Rules always win: the decision is appended after the rule candidates, never for a category a rule fired
-- in the last AI_RULE_SHADOW_MS, never for a vetoed spell. Per-bot memory: var "ai" (5.3).
-- Party coordination (ai/coord.lua) only scales urgencies; every AI_* tunable is read through profile.cfg.

local config = wow.include("config.lua")
local profile = wow.include("profile.lua")
local kit = wow.include("ai/kit.lua")
local aitrace = wow.include("ai/trace.lua")
local common = wow.include("ai/common.lua")
local coord = wow.include("ai/coord.lua")
local veto = wow.include("veto.lua")
local protocol = wow.include("protocol.lua")

local ai = {}
local cfg = profile.cfg

-- Intents in aitrace.IDS order; m.index = the id's index in vars (a missing file is skipped, the indices of
-- the others stay the same).
local INTENTS = {}
local BY_INDEX = {}
for i, id in ipairs(aitrace.IDS) do
    local ok, m = pcall(wow.include, "ai/intents/" .. id .. ".lua")
    if ok and type(m) == "table" then
        m.index = i
        INTENTS[#INTENTS + 1] = m
        BY_INDEX[i] = m
    else
        wow.warn("AI layer: intent " .. id .. " not available (" .. tostring(m):sub(1, 120) .. ")")
    end
end
ai.INTENTS = INTENTS
ai.BY_INDEX = BY_INDEX

-- Rule shadow (5.6): intent category -> state key of the last rule of that category.
local CAT_KEY = { target = "rT", move = "rM", heal = "rH", offense = "rO" }
local RULE_SLOT_MAX = 50

local function metric(low, key)
    local m = wow.metrics
    if m and m.active() then m.add(low, key, 1) end
end

-- ----------------------------------------------------------------------------- state (5.3)

local NI = #aitrace.IDS
local STATE_KEYS = { "c", "cu", "p", "pa", "ps" }
for i = 1, NI do STATE_KEYS[#STATE_KEYS + 1] = "s" .. i end
for i = 1, NI do STATE_KEYS[#STATE_KEYS + 1] = "n" .. i end
for _, k in ipairs({ "a1", "ht", "ha", "rT", "rM", "rH", "rO", "f", "ao", "pm", "fs", "sw", "q", "k", "l", "ls",
                     "la",
                     -- round 2: oom said, help said at, last callout at, callouts this fight, runner distance
                     -- to the tank x10, runner announced (target low)
                     "om", "hp1", "cl", "cn", "rd", "rn" }) do
    STATE_KEYS[#STATE_KEYS + 1] = k
end
for _, k in ipairs(coord.CALLOUT_KEYS) do STATE_KEYS[#STATE_KEYS + 1] = k end

local state = {}
ai.state = state

function state.parse(raw)
    local st = { tAt = {}, tAvg = {} }
    if raw and raw ~= "" then
        for k, v in raw:gmatch("(%w+)=([^;]*)") do
            if k == "t" then
                for at, avg in v:gmatch("(%-?%d+):(%-?%d+)") do
                    st.tAt[#st.tAt + 1] = tonumber(at)
                    st.tAvg[#st.tAvg + 1] = tonumber(avg)
                end
            else
                st[k] = tonumber(v)
            end
        end
    end
    st._raw = raw or ""
    return st
end

function state.serialize(st)
    local parts = {}
    for i = 1, #STATE_KEYS do
        local k = STATE_KEYS[i]
        local v = st[k]
        if v then parts[#parts + 1] = k .. "=" .. string.format("%d", math.floor(v)) end
    end
    local n = #st.tAt
    if n > 0 then
        local t = {}
        for i = 1, n do t[i] = string.format("%d:%d", math.floor(st.tAt[i]), math.floor(st.tAvg[i])) end
        parts[#parts + 1] = "t=" .. table.concat(t, ",")
    end
    return table.concat(parts, ";")
end

function state.load(low)
    return state.parse(wow.getVar(low, "ai"))
end

function state.save(low, st)
    local s = state.serialize(st)
    if s ~= st._raw then
        wow.setVar(low, "ai", s ~= "" and s or nil)
        st._raw = s
    end
end

-- The state parsed by onLast is reused by decide within the same evaluate call (and by the next call when
-- the var still holds exactly what this state last wrote).
local tickLow, tickSt

local function stateFor(low)
    local raw = wow.getVar(low, "ai")
    if tickLow == low and tickSt and tickSt._raw == (raw or "") then return tickSt end
    local st = state.parse(raw)
    tickLow, tickSt = low, st
    return st
end

-- ----------------------------------------------------------------------------- outcome (5.10)

local function ruleCategory(r)
    if not r then return nil end
    if r.a == "attack" then return "rT" end
    if r.a == "behind" or r.a == "follow" then return "rM" end
    if r.a == "spell" or r.a == "item" then return (r.side == "foe") and "rO" or "rH" end
    return nil
end

-- Failure backoff: a decision (spell / item) that failed to execute is not picked again for AI_FAIL_BACKOFF_MS,
-- so an unusable choice (e.g. a second potion in one fight: the potion cooldown only starts after combat) cannot
-- take the AI slot tick after tick. Per Lua state; losing it on a map change only shortens a backoff.
local FAIL_BACKOFF_MS = config.AI_FAIL_BACKOFF_MS or 8000
local badUntil = {}
-- low -> the AI decision emitted last tick: { key, idx, d = decision, p = profile, claim = {kind, target, fail} }
local pending = {}
-- low -> the profile of the last decide (onLast has no env); low -> { ["co.3"] = targetHex } (ai.onRules)
local lastProfile, ruleTargets = {}, {}

local decisionKey = common.decisionKey

local function backedOff(low, d, now)
    local key = decisionKey(d)
    local t = key and badUntil[low] and badUntil[low][key]
    return t ~= nil and now < t and t - now <= FAIL_BACKOFF_MS
end

-- A small env for the coordination calls made from onLast (no interpreter env there).
local function outcomeEnv(bot, low, st, now, p)
    return { bot = bot, low = low, guid = bot:guid(), level = bot:level() or 0, state = st, now = now, profile = p }
end

local function unitName(hex)
    local u = hex and wow.unit(hex)
    return u and u:valid() and u:name() or "?"
end

-- A rule executed a kick (a foe spell of the kit's interrupt list): announce it like an AI kick (2.4), so
-- AI bots defer to it. Target: the rule candidate of that slot (ai.onRules) or the bot's current target.
local function ruleKick(bot, low, last, now, r, st, entry)
    if not r or r.a ~= "spell" or r.side ~= "foe" or not r.x then return end
    local p = lastProfile[low]
    if not p then
        p = profile.get(bot, { low = low, cacheEntry = entry, ctx = { now = now } })
        lastProfile[low] = p
    end
    if not coord.enabled(p) then return end
    local s = kit.spell(r.x)
    local first = s and s.first and s.first > 0 and s.first or r.x
    local k = kit.get(bot, low, now)
    local isKick = false
    for _, e in ipairs(k.interrupt) do
        if e.first == first then
            isKick = true
            break
        end
    end
    if not isKick then return end
    local rt = ruleTargets[low]
    local target = rt and rt[tostring(last.list) .. "." .. tostring(last.slot)]
    if not target then
        local cur = bot:currentTarget()
        target = cur and cur:valid() and cur:guid() or nil
    end
    if not target then return end
    coord.claim(outcomeEnv(bot, low, st, now, p), "int", target, now, "int_claim", { target = unitName(target) })
end

function ai.onLast(bot, low, last, now, entry)
    local pend = pending[low]
    pending[low] = nil
    if pend and pend.key and last.slot == config.AI_SLOT and not last.ok then
        badUntil[low] = badUntil[low] or {}
        badUntil[low][pend.key] = now + FAIL_BACKOFF_MS
    end
    local reason = last.reason
    if not reason or reason == "" then reason = last.ok and "ok" or "failed" end
    local isAi = last.slot == config.AI_SLOT
    local ruleOk = not isAi and last.ok and reason == "ok" and type(last.slot) == "number"
        and last.slot >= 1 and last.slot <= RULE_SLOT_MAX
    local raw = wow.getVar(low, "ai")
    if not isAi and not ruleOk and not raw then return end
    local st = stateFor(low)
    if isAi then
        local idx = st.p
        local intent = idx and BY_INDEX[idx]
        last.intent = intent and intent.id or nil
        if intent then
            local p = (pend and pend.p) or lastProfile[low]
            if last.ok and reason == "ok" then
                if st.c and st.c ~= idx then
                    st.sw = (st.sw or 0) + 1
                    metric(low, "ai_switches")
                end
                st.c, st.cu = idx, now + cfg(p, "COMMIT_MS")
                st["n" .. idx] = (st["n" .. idx] or 0) + 1
                st.l, st.ls, st.la = idx, st.ps or 0, now
                if intent.id == "focus_target" then st.f = now end
                if intent.id == "position" then st.pm = now end
                aitrace.result(low, "ok")
                if intent.onOk and pend and pend.idx == idx and p then
                    intent.onOk(outcomeEnv(bot, low, st, now, p), low, pend.d)
                end
            else
                aitrace.result(low, reason)
                -- a failed claimed job: take the claim back (and maybe say so)
                local c = pend and pend.idx == idx and pend.claim
                if c and p then
                    coord.release(outcomeEnv(bot, low, st, now, p), c.kind, c.target, now, c.fail)
                end
            end
        end
    else
        if st.p then aitrace.drop(low) end
        -- the AI decision never ran (a rule / order went first): its claim is taken back silently
        local c = pend and pend.claim
        if c and pend.p then coord.release(outcomeEnv(bot, low, st, now, pend.p), c.kind, c.target, now) end
        if ruleOk then
            local list = entry and entry[last.list]
            local r = list and list[last.slot]
            local key = ruleCategory(r)
            if key then st[key] = now end
            -- execution time (C++ last.at, same clock as bot:trace()), so trace.lua can drop the matching
            -- C++ "tactics" entry; the next tick's `now` may be further than trace.SAME_MS away
            aitrace.rule(low, last.list, last.slot, tonumber(last.at) or now)
            if key == "rO" then ruleKick(bot, low, last, now, r, st, entry) end
        end
    end
    st.p, st.pa, st.ps = nil, nil, nil
    state.save(low, st)
end

-- Optional hook of the interpreter: the rule candidates of this tick (targets of kicks, 2.4).
function ai.onRules(env, out)
    local low = env.low or env.bot:lowGuid()
    local t
    for i = 1, #(out or {}) do
        local d = out[i]
        if d.target and type(d.slot) == "number" and d.slot <= RULE_SLOT_MAX then
            t = t or {}
            t[tostring(d.list) .. "." .. tostring(d.slot)] = d.target
        end
    end
    ruleTargets[low] = t
end

-- ----------------------------------------------------------------------------- decide (5.2)

local function tank(env)
    local t = env._tank
    if t == nil then
        t = false
        local group = env:group()
        for i = 1, #group do
            local m = group[i]
            if m:isAlive() and m:isTank() then
                if not t or m:isMainTank() then t = m end
                if m:isMainTank() then break end
            end
        end
        env._tank = t
    end
    return t or nil
end

local function shadowed(st, category, now, p)
    local t = st[CAT_KEY[category] or ""]
    if not t then return false end
    local dt = now - t
    return dt >= 0 and dt < cfg(p, "RULE_SHADOW_MS")
end

local function delayOk(st, i, now, delay)
    local k = "s" .. i
    local t = st[k]
    if not t or now < t then
        st[k] = now
        return (delay or 0) <= 0
    end
    return now - t >= delay
end

-- Trend of the group's average hp (5.9, level >= AI_TREND_LEVEL).
local function trendSample(env, st, now, p)
    local tAt, tAvg = st.tAt, st.tAvg
    local n = #tAt
    local lastAt = tAt[n]
    if not lastAt or now - lastAt >= config.AI_TREND_MS or now < lastAt then
        local avg = common.groupAvgHp(env)
        if avg then
            if lastAt and now < lastAt then
                for i = n, 1, -1 do tAt[i], tAvg[i] = nil, nil end
            end
            tAt[#tAt + 1], tAvg[#tAvg + 1] = now, avg
            while #tAt > config.AI_TREND_SAMPLES do
                table.remove(tAt, 1)
                table.remove(tAvg, 1)
            end
        end
    end
    n = #tAt
    return n >= 2 and (tAvg[1] - tAvg[n]) > cfg(p, "TREND_DROP") and (tAt[n] - tAt[1]) >= config.AI_TREND_SPAN_MS
end

local function reserveOf(env, p)
    local r = (env.boss and cfg(p, "RESERVE_BOSS") or cfg(p, "RESERVE_TRASH")) + p.reserveBonus
        - (p.ai == 3 and 10 or 0) - (env.trendBad and 10 or 0)
    return common.clamp(r, 5, 60)
end

-- Resource and cooldown budget (5.8). The mana economy intent is exempt (its casts cost nothing or restore
-- mana; its cooldowns are never "wasted": round 2, 1.2).
local budget = {}
ai.budget = budget

function budget.allows(env, st, d, intent)
    if intent.id == "preserve_self" or intent.noBudget then return true end
    if d.spell and env.mana then
        local exempt = intent.id == "heal_priority" and env._healExempt
        if not exempt and env.mana - kit.costPct(env.bot, d.spell) < env.reserve then return false end
    end
    if d._cd and not common.cdAllowed(env, d._cd) then return false end
    return true
end

-- Slider 3: automatic aoe toggle (3.6).
local function aoeAuto(env, p, st, now)
    if p.ai ~= 3 or env.level < config.AI_AOE_LEVEL or p.style.passive then return end
    if st.ao then
        local dt = now - st.ao
        if dt >= 0 and dt < config.AI_AOE_AUTO_MS then return end
    end
    st.ao = now
    if wow.getVar(env.low, "style_touched_aoe") then return end
    local bot = env.bot
    local att = env:attackers()
    local near = 0
    for i = 1, #att do
        local u = att[i]
        if u:isAlive() then
            local d = bot:distance(u)
            if d and d <= config.NEAR_RADIUS then near = near + 1 end
        end
    end
    if near >= 3 and not p.style.aoe then
        if protocol.runCommand(bot, "co +aoe") then
            p.style.aoe = true
            aitrace.note(env.low, aitrace.AOE_ON, now)
        end
    elseif near <= 1 and p.style.aoe then
        if protocol.runCommand(bot, "co -aoe") then
            p.style.aoe = false
            aitrace.note(env.low, aitrace.AOE_OFF, now)
        end
    end
end

local DECISION_FIELDS = { "verb", "target", "spell", "item", "x", "y", "z", "dist", "reach" }

function ai.decide(env, listName, now)
    if listName ~= "co" then return nil end
    local bot = env.bot
    local low = env.low or bot:lowGuid()
    env.low = low
    local p = profile.get(bot, env)
    env.profile = p
    lastProfile[low] = p
    if p.ai == 0 then return nil end

    local st = stateFor(low)
    env.state, env.now, env.veto, env.tank = st, now, veto, tank
    env.badUntil = badUntil[low]
    env.kit = kit.get(bot, low, now)
    env.hp = bot:hpPct()
    env.mana = bot:manaPct()
    env.fightMs = env.ctx and env.ctx.combatMs or 0
    local att = env:attackers()
    local n, boss, elite, me = 0, false, false, false
    for i = 1, #att do
        local u = att[i]
        if u:isAlive() then
            n = n + 1
            if u:isBoss() then boss = true elseif u:isElite() then elite = true end
            if not me then
                local v = u:victim()
                me = v ~= nil and v:guid() == env.guid
            end
        end
    end
    env.nAttackers, env.boss, env.elite, env.targetedMe = n, boss, elite, me
    if not st.fs then st.fs = now end
    st.k = (st.k or 0) + 1
    env.trendBad = env.level >= config.AI_TREND_LEVEL and trendSample(env, st, now, p) or false
    env.reserve = reserveOf(env, p)
    aoeAuto(env, p, st, now)

    local best, bestScore, bestIntent = nil, p.threshold, nil
    local commitMs = cfg(p, "COMMIT_MS")
    local commitOn = st.c and st.cu and now < st.cu and (st.cu - now) <= commitMs
    local commitBonus = cfg(p, "COMMIT_BONUS")
    -- sim diagnostics: why each intent with urgency did not become the decision (aix.<intent>.<step>)
    local diag = wow.metrics and wow.metrics.active() and function(intent, step)
        wow.metrics.add(low, "aix." .. intent.id .. "." .. step, 1)
    end or nil
    for j = 1, #INTENTS do
        local intent = INTENTS[j]
        local i = intent.index
        if p.enabled[intent.id] and env.level >= intent.level then
            local u = intent.urgency(env, st)
            if u > 0 then
                local score = u * (p.weight[intent.id] or 1)
                if commitOn and st.c == i then score = score * commitBonus end
                -- the slider threshold is inclusive (a base urgency equal to it fires: dispel 0.6 at slider 1,
                -- position 0.4 at slider 2); between intents the earlier one keeps a tie (fixed priority order)
                if not (best and score > bestScore or not best and score >= bestScore - 1e-9) then
                    if diag then diag(intent, "low") end
                elseif not (intent.noShadow or not shadowed(st, intent.category, now, p)) then
                    if diag then diag(intent, "shadow") end
                elseif not delayOk(st, i, now, p.delayMs) then
                    if diag then diag(intent, "delay") end
                else
                    local d = intent.build(env, st)
                    if not d then
                        if diag then diag(intent, "nobuild") end
                    elseif not budget.allows(env, st, d, intent) then
                        if diag then diag(intent, "budget") end
                    elseif veto.check(low, d.spell, d.target) then
                        if diag then diag(intent, "veto") end
                    elseif backedOff(low, d, now) then
                        if diag then diag(intent, "backoff") end
                    else
                        best, bestScore, bestIntent = d, score, intent
                    end
                end
            else
                st["s" .. i] = nil
            end
        end
    end

    local out
    if best then
        local bestIdx = bestIntent.index
        if diag then diag(bestIntent, "pick") end
        -- coordination (2.4): the chosen job is claimed / announced before it runs
        local claim
        if bestIntent.onPick then claim = bestIntent.onPick(env, st, best, now) end
        pending[low] = { key = decisionKey(best), idx = bestIdx, d = best, p = p, claim = claim }
        out = { slot = config.AI_SLOT, list = listName, tag = "ai:" .. bestIntent.id }
        for _, f in ipairs(DECISION_FIELDS) do out[f] = best[f] end
        if out.reach == nil then out.reach = false end
        st.p, st.pa, st.ps = bestIdx, now, math.floor(bestScore * 100 + 0.5)
        aitrace.decided(low, out, bestIdx, bestScore, now)
    else
        st.q = (st.q or 0) + 1
        metric(low, "ai_silent")
    end
    state.save(low, st)
    return out
end

-- Out of combat (round 2, 1.4): the mana economy may drink between pulls. Never a decision.
local manaEconomy = BY_INDEX[aitrace.INDEX.mana_economy]

function ai.decideNoncombat(env, now)
    if not manaEconomy or not manaEconomy.noncombat then return nil end
    local bot = env.bot
    local mana = bot:manaPct()
    -- cheap exit first: no mana bar, or plenty of it (the default threshold; an override can only be read
    -- from the profile, which is cached on the interpreter's cache entry)
    if not mana or mana >= 100 then return nil end
    env.low = env.low or bot:lowGuid()
    local p = profile.get(bot, env)
    if p.ai == 0 or not p.enabled.mana_economy then return nil end
    env.profile, env.now, env.mana, env.noncombat = p, now, mana, true
    manaEconomy.noncombat(env, now)
    return nil
end

-- Leaving combat: fold the fight counters into ai_stat and clear the fight memory (once).
function ai.onNoncombat(low)
    pending[low] = nil
    local raw = wow.getVar(low, "ai")
    if not raw then return end
    local st = state.parse(raw)
    if st.fs then aitrace.endFight(low, st) end
    wow.setVar(low, "ai", nil)
    if tickLow == low then tickLow, tickSt = nil, nil end
end

return ai
