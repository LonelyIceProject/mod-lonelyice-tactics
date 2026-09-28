-- Bot tactics / party window: AI decision trace (AI stage 0, party-window-spec 5.8, 9; ai-layer-spec 8).
-- C++ records the actions the playerbots engine executed for owned bots (TacticsTraceListener, kind "");
-- the Lua AI trace (ai/trace.lua, reached through aistat.aitrace()) adds the decisions of the AI layer
-- (kind "ai") and the rule fires (kind "rule"). This file merges and formats them.
-- Message: TRACE -> TRACE <bot> <agoMs,nameEsc,ok,target,relevance,kind,score100;...> newest last.

local util = wow.include("util.lua")
local config = wow.include("config.lua")
local protocol = wow.include("protocol.lua")
local aistat = wow.include("aistat.lua")

local trace = {}
local handlers = protocol.handlers

-- A C++ entry named "tactics" within this many ms of a Lua entry is the same execution.
trace.SAME_MS = 300

-- Merge C++ entries (kind "") with Lua AI trace entries ({at, kind, name, ok, target, score}), oldest
-- first; C++ "tactics" entries that duplicate a Lua entry are dropped. Stable on equal times (C++ first).
function trace.merge(entries, luaEntries)
    local all = {}
    local lua = {}
    for _, e in ipairs(luaEntries or {}) do
        if type(e) == "table" and tonumber(e.at) then
            lua[#lua + 1] = e
        end
    end
    for _, e in ipairs(entries or {}) do
        local dup = false
        if e.name == "tactics" and e.at then
            for _, l in ipairs(lua) do
                if math.abs(e.at - l.at) <= trace.SAME_MS then
                    dup = true
                    break
                end
            end
        end
        if not dup then all[#all + 1] = { e = e, kind = "", at = e.at or 0 } end
    end
    for _, l in ipairs(lua) do
        local kind = (l.kind == "rule") and "rule" or "ai"
        all[#all + 1] = { e = l, kind = kind, at = l.at }
    end
    return util.sortBy(all, function(x) return x.at end)
end

-- `luaEntries` optional (aitrace.entries); without it the payload carries the C++ entries only.
function trace.build(low, entries, now, luaEntries)
    local merged = trace.merge(entries, luaEntries)
    local out = {}
    local first = math.max(1, #merged - config.TRACE_MAX + 1)
    for i = first, #merged do
        local m = merged[i]
        local e = m.e
        local ago = now - (e.at or now)
        if ago < 0 then ago = 0 end
        local score = ""
        if m.kind == "ai" then score = aistat.score100(e.score) end
        out[#out + 1] = table.concat({ math.floor(ago), util.esc(e.name or ""), e.ok and "1" or "0",
            protocol.guidHex(e.target) or "", string.format("%g", tonumber(e.relevance) or 0), m.kind, score }, ",")
    end
    return "TRACE\t" .. low .. "\t" .. table.concat(out, ";")
end

handlers.TRACE = function(req, f)
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), "TRACE", "bad_bot") end
    local now = wow.now()
    protocol.send(req.low, trace.build(low, bot:trace() or {}, now, aistat.aitrace().entries(low, now)))
end

return trace
