-- Bot tactics: manual mode, "only my rules" (abilities-mirroring-spec 3).
--
-- Store key `manual` per (bot, leader) (store.LEADER_KEYS): "1" = manual, the class AI keeps its life support
-- (C++ Tactics.ManualKeepStrategies) plus potions / racials (Tactics.ManualKeepOptional); "1s" = strict,
-- potions and racials only by rules too (bot:setManual(true, {})). Missing = off. The headless sim sets it
-- through the per-fight key `aicfg` instead: MANUAL=1 / MANUAL=2 (strict) (sim/scenarios/rfc_manual.lua).
--
-- C++ keeps the flag in the bot's runtime only (not persistent, like the veto set): manual.refresh pushes it
-- from every evaluate on a store revision / leader change and every VETO_REFRESH_MS while on. It runs right
-- after veto.refresh (this file wraps that function: the interpreter is another package's file).
-- In manual mode the AI slider is effectively 0 (profile.effectiveAi asks manual.get), the veto and the style
-- toggles have nothing left to constrain; mechanics, orders and the rules work as always.
-- Protocol: SETSTYLE <bot> manual <0|1> [strict] (style.lua routes it here), STYLE field 9 = "<on>,<strict>".

local config = wow.include("config.lua")
local store = wow.include("store.lua")
local protocol = wow.include("protocol.lua")
local basics = wow.include("basics.lua")
local veto = wow.include("veto.lua")

local manual = {}

manual.KEY = "manual"

-- "1" -> true, false; "1s" -> true, true; anything else -> false, false
function manual.parse(text)
    if text == "1" then return true, false end
    if text == "1s" then return true, true end
    return false, false
end

function manual.serialize(on, strict)
    if not on then return nil end
    return strict and "1s" or "1"
end

-- aicfg "KEY=v;..." of the sim: MANUAL=1 / MANUAL=2 -> on, strict
local function simValue(text)
    if type(text) ~= "string" or text == "" then return nil end
    local v = tonumber((";" .. text):match(";MANUAL=(%d+)"))
    if not v or v <= 0 then return nil end
    return true, v >= 2
end

-- per-state cache: low -> { rev, leader, on, strict }
local cache = {}

-- on, strict for a bot as `leader` sees it (leader nil = store.leaderOf(bot)).
function manual.get(bot, low, leader)
    low = low or bot:lowGuid()
    if leader == nil then leader = store.leaderOf(bot) end
    local rev = wow.storeRev(low)
    local e = cache[low]
    if e and e.rev == rev and e.leader == leader then return e.on, e.strict end
    local on, strict = manual.parse(store.get(low, manual.KEY, leader))
    if not on then
        local simOn, simStrict = simValue(store.get(low, "aicfg", leader))
        if simOn then on, strict = true, simStrict end
    end
    cache[low] = { rev = rev, leader = leader, on = on, strict = strict }
    return on, strict
end

function manual.forget(low)
    cache[low] = nil
end

-- 0 off, 1 manual, 2 strict (the value last pushed to C++, var manual_state)
local function stateOf(on, strict)
    if not on then return 0 end
    return strict and 2 or 1
end

-- Push the flag to C++ (bot:setManual; keep {} = strict, nil = the C++ default keep list).
function manual.push(bot, low, on, strict, now)
    if not basics.has(bot, "setManual") then return false, "no_binding" end
    local ok, reason = bot:setManual(on and true or false, (on and strict) and {} or nil)
    wow.setVar(low, "manual_state", stateOf(on, strict))
    wow.setVar(low, "manual_rev", wow.storeRev(low))
    wow.setVar(low, "manual_at", now or wow.now())
    return ok, reason
end

-- Evaluate hook (map thread). A bot that was never switched on costs one getVar per tick after the first.
function manual.refresh(bot, env, now)
    local low = env.low or bot:lowGuid()
    local leader = env.leader
    if leader == nil then leader = store.leaderOf(bot) end
    local on, strict = manual.get(bot, low, leader)
    local want = stateOf(on, strict)
    local pushed = wow.getVar(low, "manual_state") or 0
    if want == 0 and pushed == 0 then return end
    local at = wow.getVar(low, "manual_at")
    if pushed ~= want or wow.getVar(low, "manual_rev") ~= wow.storeRev(low)
        or (want ~= 0 and (not at or now - at >= config.VETO_REFRESH_MS or now < at)) then
        manual.push(bot, low, on, strict, now)
    end
end

-- Runs manual.refresh right after veto.refresh (called by interpreter.evaluate every tick). Once per state.
if not veto._manualWrapped then
    local vetoRefresh = veto.refresh
    veto.refresh = function(bot, env, now)
        vetoRefresh(bot, env, now)
        manual.refresh(bot, env, now)
    end
    veto._manualWrapped = true
end

-- "<on>,<strict>" (STYLE field 9)
function manual.styleField(bot, low, leader)
    local on, strict = manual.get(bot, low, leader)
    return (on and "1" or "0") .. "," .. (strict and "1" or "0")
end

-- SETSTYLE <bot> manual <0|1> [strict]: ACK, then STYLE (sendStyle(req, bot, low) = style.send).
function manual.handle(req, bot, low, value, mode, sendStyle)
    local op = "SETSTYLE"
    mode = mode or ""
    if (value ~= "0" and value ~= "1") or (mode ~= "" and mode ~= "strict") then
        protocol.ack(req, low, op, "bad_value", 0)
        return sendStyle(req, bot, low)
    end
    local on, strict = value == "1", mode == "strict"
    local ok
    if on then
        ok = store.set(low, manual.KEY, manual.serialize(on, strict), req.low)
    else
        ok = store.erase(low, manual.KEY, req.low) or store.get(low, manual.KEY, req.low) == nil
    end
    if not ok then
        protocol.ack(req, low, op, "store_failed")
        return sendStyle(req, bot, low)
    end
    manual.forget(low)
    manual.push(bot, low, on, strict, wow.now())
    -- slider / wake: the effective AI changes with the mode (profile.effectiveAi)
    local okP, profile = pcall(wow.include, "profile.lua")
    if okP and type(profile) == "table" and profile.syncWake then profile.syncWake(bot, low) end
    protocol.ack(req, low, op, "ok")
    sendStyle(req, bot, low)
end

return manual
