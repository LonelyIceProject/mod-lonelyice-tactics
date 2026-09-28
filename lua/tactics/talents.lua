-- Bot tactics / party window: talent trees, build validation, spec switch (party-window-spec 5.5, 4.1),
-- premade builds and glyphs (party-extras-spec 5.2).
-- C++ (P2) lists DBC rows and applies a parsed build through PlayerbotFactory; the talent rules
-- (row gating, prerequisites, point budget) are checked here. Messages: TTREE, TALENTS, TAPPLY, TSPEC,
-- PRESPECS, PRESPEC, GLYPHS, GLYPH.

local util = wow.include("util.lua")
local config = wow.include("config.lua")
local protocol = wow.include("protocol.lua")
local spellbook = wow.include("spellbook.lua")
local inventory = wow.include("inventory.lua")
local character = wow.include("character.lua")

local talents = {}
local handlers = protocol.handlers
local send = protocol.send

talents.POINTS_PER_ROW = 5     -- talent points per tier (rows < r need 5*r points in the same tab)
talents.MAX_RANK = 5           -- MAX_TALENT_RANK

local CLASSES = util.set({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 11 })

-- ----------------------------------------------------------------------------- static data (per state)

local trees = {}   -- class -> { rows = {...}, byId = { id -> row }, text = TTREE rows field }

function talents.tree(class)
    local t = trees[class]
    if t then return t end
    local rows = wow.talents(class) or {}
    t = { rows = rows, byId = {}, byPos = {} }
    local text = {}
    for i, r in ipairs(rows) do
        t.byId[r.id] = r
        local tab = t.byPos[r.tab] or {}
        t.byPos[r.tab] = tab
        tab[r.row] = tab[r.row] or {}
        tab[r.row][r.col] = r
        local ranks = {}
        for k = 1, #(r.ranks or {}) do
            if r.ranks[k] and r.ranks[k] ~= 0 then ranks[#ranks + 1] = tostring(r.ranks[k]) end
        end
        text[i] = table.concat({ r.id, r.tab, r.row, r.col, r.max, r.dep or 0, r.depRank or 0,
            table.concat(ranks, ":") }, ",")
    end
    t.text = table.concat(text, ";")
    if #rows > 0 then trees[class] = t end   -- do not cache a failed lookup
    return t
end

-- Main talent tab (0..2) of the bot's active spec: the tab with the most points (ties: lower tab),
-- nil when unknown / no points. Used by style.lua to pick a role's strategies.
function talents.mainTab(bot)
    local class = bot:class()
    local info = bot:talentInfo()
    if not class or not info then return nil end
    local tree = talents.tree(class)
    local ranks = bot:talentRanks(info.active) or {}
    local sums = { [0] = 0, 0, 0 }
    for id, rank in pairs(ranks) do
        local r = tree.byId[id]
        if r and sums[r.tab] then sums[r.tab] = sums[r.tab] + rank end
    end
    local best
    for tab = 0, 2 do
        if sums[tab] > 0 and (not best or sums[tab] > sums[best]) then best = tab end
    end
    return best
end

-- ----------------------------------------------------------------------------- validation

-- Parse and check a build "id:rank;id:rank;..." (ranks absent = 0) against the class rows and the point
-- budget. Returns the C++ build (array of {tab,row,col,rank} sorted by tab,row,col) or nil, code, arg.
function talents.validate(class, text, total)
    local tree = talents.tree(class)
    if #tree.rows == 0 then return nil, "failed" end
    local ranks, sum = {}, 0
    if text ~= "" then
        for _, part in ipairs(util.split(text, ";")) do
            if part ~= "" then
                local id, rank = part:match("^(%d+):(%d+)$")
                id, rank = tonumber(id), tonumber(rank)
                local r = id and tree.byId[id]
                if not r then return nil, "bad_build", "#" .. tostring(id or part:sub(1, 12)) end
                if ranks[id] or rank > (r.max or 0) then return nil, "bad_build", "#" .. id end
                if rank > 0 then
                    ranks[id] = rank
                    sum = sum + rank
                end
            end
        end
    end
    if sum > (total or 0) then return nil, "bad_build", sum .. "/" .. tostring(total or 0) end

    -- points per tab and row
    local perRow = { [0] = {}, {}, {} }
    for id, rank in pairs(ranks) do
        local r = tree.byId[id]
        local t = perRow[r.tab]
        if not t then return nil, "bad_build", "#" .. id end
        t[r.row] = (t[r.row] or 0) + rank
    end
    local build = {}
    for id, rank in pairs(ranks) do
        local r = tree.byId[id]
        local below = 0
        for row, pts in pairs(perRow[r.tab]) do
            if row < r.row then below = below + pts end
        end
        if below < talents.POINTS_PER_ROW * r.row then return nil, "bad_build", "#" .. id end
        -- DBC DependsOnRank is 0-based (Player::LearnTalent checks RankID[DependsOnRank..])
        if r.dep and r.dep ~= 0 and (ranks[r.dep] or 0) < (r.depRank or 0) + 1 then
            return nil, "bad_build", "#" .. id
        end
        build[#build + 1] = { r.tab, r.row, r.col, rank }
    end
    table.sort(build, function(a, b)
        if a[1] ~= b[1] then return a[1] < b[1] end
        if a[2] ~= b[2] then return a[2] < b[2] end
        return a[3] < b[3]
    end)
    return build
end

-- ----------------------------------------------------------------------------- messages

-- C++ resets the bot's strategies after a talent / spec change (ResetBotStrategies): the next evaluate
-- re-applies the leader's saved role, toggles and pull (style.ensure, tactics-round2-spec 4.4). The var
-- name is style.lua's; style.lua includes this file, so it is set here directly.
function talents.strategiesReset(low, leader)
    wow.setVar(low, "style_applied_" .. leader, nil)
end

-- TALENTS <bot> <active> <count> <spec> <free> <total> <minDual> <id:rank;...>
function talents.send(req, bot, low, spec)
    local info = bot:talentInfo()
    if not info then return protocol.ack(req, low, "TALENTS", "failed") end
    if not spec or spec == 0 then spec = info.active or 1 end
    local out = {}
    if spec <= (info.count or 1) then
        local ranks = bot:talentRanks(spec) or {}
        local ids = {}
        for id, rank in pairs(ranks) do
            if rank and rank > 0 then ids[#ids + 1] = id end
        end
        table.sort(ids)
        for i, id in ipairs(ids) do out[i] = id .. ":" .. ranks[id] end
    end
    send(req.low, "TALENTS", low, info.active or 1, info.count or 1, spec, info.free or 0, info.total or 0,
        info.minDualLevel or 0, table.concat(out, ";"))
end

-- TTREE <class>
handlers.TTREE = function(req, f)
    local class = util.toint(f[2])
    if not class or not CLASSES[class] then return protocol.ack(req, "0", "TTREE", "failed") end
    send(req.low, "TTREE", class, talents.tree(class).text)
end

-- TALENTS <bot> <spec 0|1|2>
handlers.TALENTS = function(req, f)
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), "TALENTS", "bad_bot") end
    local spec = util.toint(f[3]) or 0
    if spec < 0 or spec > 2 then spec = 0 end
    talents.send(req, bot, low, spec)
end

-- TAPPLY <bot> <id:rank;...>  (active spec only)
handlers.TAPPLY = function(req, f)
    local op = "TAPPLY"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local info = bot:talentInfo()
    if not info then return protocol.ack(req, low, op, "failed") end
    local build, code, arg = talents.validate(bot:class() or 0, f[3] or "", info.total)
    if not build then return protocol.ack(req, low, op, code, arg) end
    local ok, reason = bot:applyTalents(build)
    if ok then talents.strategiesReset(low, req.low) end
    protocol.ackReason(req, low, op, ok, reason)
    talents.send(req, bot, low, 0)
    send(req.low, spellbook.build(bot, req.locale))
end

-- TSPEC <bot> <1|2>: learn the second spec first when needed (and allowed), then activate.
handlers.TSPEC = function(req, f)
    local op = "TSPEC"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local spec = util.toint(f[3])
    if spec ~= 1 and spec ~= 2 then return protocol.ack(req, low, op, "bad_value", 0) end
    local info = bot:talentInfo()
    if not info then return protocol.ack(req, low, op, "failed") end
    local ok, reason = true, "ok"
    if spec == 2 and (info.count or 1) < 2 then
        ok, reason = bot:learnDualSpec()
        if not ok and reason == "level" then
            protocol.ackText(req, low, op, false, "level", "level", info.minDualLevel or 40)
            return talents.send(req, bot, low, 0)
        end
    end
    if ok then
        ok, reason = bot:activateSpec(spec)
        if not ok and reason == "already" then ok, reason = true, "ok" end
    end
    if ok then talents.strategiesReset(low, req.low) end
    protocol.ackReason(req, low, op, ok, reason)
    talents.send(req, bot, low, 0)
    send(req.low, spellbook.build(bot, req.locale))
end

-- ----------------------------------------------------------------------------- premade builds (extras 5.2)

-- t.byPos[tab][row][col] = talent row (same cache as talents.tree).
function talents.byPos(class)
    return talents.tree(class).byPos
end

-- Merge a premade spec of wow.premadeSpecs (entries {tab,row,col,rank} in level order, rank = the ABSOLUTE
-- target rank at that level) into a build trimmed to `total` points. Returns text "id:rank;..." (ascending id),
-- t0, t1, t2 (points per tab), or nil, "bad_build", detail. The text passed talents.validate (the TAPPLY rules).
function talents.premadeBuild(class, level, total, spec)
    local tree = talents.tree(class)
    if #tree.rows == 0 or type(spec) ~= "table" then return nil, "bad_build", "#" .. tostring(class) end
    total = math.max(0, math.floor(tonumber(total) or 0))
    local have, spent = {}, 0
    for i, e in ipairs(spec.entries or {}) do
        if i > config.PREMADE_MAX_ENTRIES then break end
        local tab, row, col, want = tonumber(e[1]), tonumber(e[2]), tonumber(e[3]), tonumber(e[4]) or 0
        local r = tab and row and col and tree.byPos[tab] and tree.byPos[tab][row] and tree.byPos[tab][row][col]
        if not r then
            return nil, "bad_build", tostring(e[1]) .. "-" .. tostring(e[2]) .. "-" .. tostring(e[3])
        end
        local cur = have[r.id] or 0
        local inc = want - cur
        if inc > 0 then
            inc = math.min(inc, total - spent)
            if inc <= 0 then break end
            have[r.id] = cur + inc
            spent = spent + inc
        end
    end
    if spent == 0 then return nil, "bad_build", "0/" .. total end
    local ids = {}
    for id in pairs(have) do ids[#ids + 1] = id end
    table.sort(ids)
    local parts, sums = {}, { [0] = 0, 0, 0 }
    for i, id in ipairs(ids) do
        parts[i] = id .. ":" .. have[id]
        local tab = tree.byId[id].tab
        sums[tab] = (sums[tab] or 0) + have[id]
    end
    local text = table.concat(parts, ";")
    local build, code, arg = talents.validate(class, text, total)
    if not build then return nil, code, arg end
    return text, sums[0], sums[1], sums[2]
end

-- PRESPECS <bot> <level> <no,nameEsc,t0-t1-t2,item:item;...>
handlers.PRESPECS = function(req, f)
    local op = "PRESPECS"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local class, level = bot:class() or 0, bot:level() or 0
    local info = bot:talentInfo() or {}
    local out = {}
    for _, spec in ipairs(wow.premadeSpecs(class, level) or {}) do
        local text, t0, t1, t2 = talents.premadeBuild(class, level, info.total or 0, spec)
        if not text then t0, t1, t2 = 0, 0, 0 end
        local items = {}
        for i, e in ipairs(spec.glyphItems or {}) do items[i] = tostring(math.floor(tonumber(e) or 0)) end
        out[#out + 1] = table.concat({ math.floor(tonumber(spec.no) or 0), util.esc(spec.name or ""),
            t0 .. "-" .. t1 .. "-" .. t2, table.concat(items, ":") }, ",")
    end
    send(req.low, "PRESPECS", low, level, table.concat(out, ";"))
end

-- PRESPEC <bot> <no>: apply premade build `no` (active spec) -> ACK, TALENTS, BOOK (as TAPPLY).
handlers.PRESPEC = function(req, f)
    local op = "PRESPEC"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local class, level = bot:class() or 0, bot:level() or 0
    local no = util.toid(f[3])
    local spec
    for _, s in ipairs(no and wow.premadeSpecs(class, level) or {}) do
        if s.no == no then spec = s; break end
    end
    if not spec then return protocol.ack(req, low, op, "bad_spec") end
    local info = bot:talentInfo()
    if not info then return protocol.ack(req, low, op, "failed") end
    local text, code, arg = talents.premadeBuild(class, level, info.total, spec)
    if not text then return protocol.ack(req, low, op, code, arg) end
    local build
    build, code, arg = talents.validate(class, text, info.total)
    if not build then return protocol.ack(req, low, op, code, arg) end
    local ok, reason = bot:applyTalents(build)
    if ok then talents.strategiesReset(low, req.low) end
    protocol.ackReason(req, low, op, ok, reason)
    talents.send(req, bot, low, 0)
    send(req.low, spellbook.build(bot, req.locale))
end

-- ----------------------------------------------------------------------------- glyphs (extras 5.2)

talents.GLYPH_SLOTS = 6
talents.GLYPH_SLOT_LEVEL = { [0] = 15, 15, 50, 30, 70, 80 }   -- TacticsExtras.h GLYPH_SLOT_LEVEL

local function n0(v) return tostring(math.floor(tonumber(v) or 0)) end

-- GLYPHS <bot> <enabled> <slot,kind,level,glyph,spell x6> <bag,slot,guid,entry,glyph,kind,spell;...>
function talents.sendGlyphs(req, bot, low)
    local op = "GLYPHS"
    local g, reason = bot:glyphs()
    if type(g) ~= "table" then return protocol.ackReason(req, low, op, false, reason) end
    local bySlot = {}
    for _, s in ipairs(g.slots or {}) do
        if type(s) == "table" and s.slot then bySlot[math.floor(s.slot)] = s end
    end
    local slots = {}
    for i = 0, talents.GLYPH_SLOTS - 1 do
        local s = bySlot[i] or {}
        slots[#slots + 1] = table.concat({ i, n0(s.kind), n0(s.level or talents.GLYPH_SLOT_LEVEL[i]), n0(s.glyph),
            n0(s.spell) }, ",")
    end
    local slotText = table.concat(slots, ";")
    local bag = {}
    for i, b in ipairs(g.bag or {}) do
        bag[i] = table.concat({ n0(b.bag), n0(b.slot), n0(b.guid), n0(b.entry), n0(b.glyph), n0(b.kind), n0(b.spell) }, ",")
    end
    local head = "GLYPHS\t" .. low .. "\t" .. n0(g.enabled) .. "\t" .. slotText .. "\t"
    local bagText = character.capJoin(bag, #head)
    send(req.low, "GLYPHS", low, n0(g.enabled), slotText, bagText)
end

handlers.GLYPHS = function(req, f)
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), "GLYPHS", "bad_bot") end
    talents.sendGlyphs(req, bot, low)
end

-- Non-negative integer field <= 255, else nil.
local function byte(field)
    local n = util.toint(field)
    if not n or n < 0 or n > 255 then return nil end
    return n
end

-- GLYPH <bot> apply <glyphSlot> <bag> <bagSlot> <guid> | GLYPH <bot> remove <glyphSlot> 0 0 0
handlers.GLYPH = function(req, f)
    local op = "GLYPH"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local what = f[3]
    if what ~= "apply" and what ~= "remove" then return protocol.ack(req, low, op, "bad_op") end
    local slot = byte(f[4])
    if not slot then return protocol.ack(req, low, op, "bad_arg") end
    if what == "remove" then
        local ok, reason = bot:glyphRemove(slot)
        protocol.ackReason(req, low, op, ok, reason)
        if ok then talents.sendGlyphs(req, bot, low) end
        return
    end
    local bag, bagSlot, guid = byte(f[5]), byte(f[6]), inventory.itemGuid(f[7])
    if not bag or not bagSlot or not guid then return protocol.ack(req, low, op, "bad_arg") end
    local ok, reason, a = bot:glyphApply(slot, bag, bagSlot, guid)
    if ok and tonumber(a) == 0 then
        protocol.ackText(req, low, op, true, "ok", "glyph_pending")
    else
        protocol.ackReason(req, low, op, ok, reason, "done", a)
    end
    if ok then
        talents.sendGlyphs(req, bot, low)
        inventory.sendBags(req, bot, low, op)
    end
end

return talents
