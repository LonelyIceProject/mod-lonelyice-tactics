-- Bot tactics / party window: the bot's quest log (party-window-spec 5.8) and completed quests
-- (party-extras-spec 5.5). Messages: QUESTS, QUEST, QDONE.

local util = wow.include("util.lua")
local config = wow.include("config.lua")
local protocol = wow.include("protocol.lua")

local quests = {}
local handlers = protocol.handlers

-- QUESTS <bot> <id,level,complete,titleEsc;...>
function quests.send(req, bot, low)
    local out = {}
    for _, q in ipairs(bot:quests() or {}) do
        out[#out + 1] = table.concat({ math.floor(q.id or 0), math.floor(q.level or 0), q.complete and "1" or "0",
            util.esc(q.title or "") }, ",")
    end
    protocol.send(req.low, "QUESTS", low, table.concat(out, ";"))
end

handlers.QUESTS = function(req, f)
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), "QUESTS", "bad_bot") end
    quests.send(req, bot, low)
end

-- QUEST <bot> <drop|acceptall> <id>   (acceptall: quest givers within interaction distance of the bot,
-- AcceptQuestAction.cpp:50-71)
handlers.QUEST = function(req, f)
    local op = "QUEST"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local ok, reason
    if f[3] == "drop" then
        local id = util.toid(f[4])
        if not id then return protocol.ack(req, low, op, "bad_quest") end
        ok, reason = bot:dropQuest(id)
    elseif f[3] == "acceptall" then
        ok, reason = protocol.runCommand(bot, "accept *")
    else
        return protocol.ack(req, low, op, "bad_op")
    end
    protocol.ackReason(req, low, op, ok, reason)
    quests.send(req, bot, low)
end

-- QDONE <bot> <offset> -> QDONE <bot> <total> <offset> <id,level,titleEsc;...>  (party-extras-spec 5.5):
-- one page of config.QDONE_PAGE rewarded quests, ascending id; quests without a template (empty title) dropped.
handlers.QDONE = function(req, f)
    local op = "QDONE"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local offset = util.toint(f[3])
    if not offset or offset < 0 then return protocol.ack(req, low, op, "bad_arg") end
    -- the binding takes a uint32 (sol2 would wrap a larger number): any offset past the list is an empty page
    local rows, total, reason = bot:rewardedQuests(math.min(offset, 0xFFFFFFFF), config.QDONE_PAGE)
    if type(rows) ~= "table" or (reason ~= nil and reason ~= "ok") then
        return protocol.ackReason(req, low, op, false, reason)
    end
    local out = {}
    for _, q in ipairs(rows) do
        if type(q.title) == "string" and q.title ~= "" then
            out[#out + 1] = table.concat({ math.floor(q.id or 0), math.floor(q.level or 0), util.esc(q.title) }, ",")
        end
    end
    protocol.send(req.low, "QDONE", low, math.floor(tonumber(total) or 0), offset, table.concat(out, ";"))
end

return quests
