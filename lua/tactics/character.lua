-- Bot tactics / party window extras: reputations and skills of the Gear tab sidebar (party-extras-spec 5.3).
-- C++ lists raw rows (bot:reputations(), bot:skills()); sorting, filtering and names are done here.
-- Messages: REPS, SKILLS. Also exports character.capJoin (list cap shared by vendor.lua / talents.lua).

local util = wow.include("util.lua")
local config = wow.include("config.lua")
local protocol = wow.include("protocol.lua")

local character = {}
local handlers = protocol.handlers
local send = protocol.send

-- Skill categories sent in SKILLS (SharedDefines.h SKILL_CATEGORY_*): 6 weapon, 9 secondary, 11 profession.
character.SKILL_CATS = { [6] = true, [9] = true, [11] = true }

function character.num(v)
    return tostring(math.floor(tonumber(v) or 0))
end
local num = character.num

-- Join already formatted rows with ";" so that `#head + #result <= config.LIST_MAX_BYTES` (whole rows only).
-- Returns joined, cut (true when rows were dropped).
function character.capJoin(rows, headBytes)
    local budget = config.LIST_MAX_BYTES - (headBytes or 0)
    local out, used = {}, 0
    for _, row in ipairs(rows) do
        local add = #row + ((#out > 0) and 1 or 0)
        if used + add > budget then return table.concat(out, ";"), true end
        out[#out + 1] = row
        used = used + add
    end
    return table.concat(out, ";"), false
end

-- C++ list contract `rows, reason`: reason nil / "ok" = success.
local function failed(rows, reason)
    return type(rows) ~= "table" or (reason ~= nil and reason ~= "ok")
end

-- ----------------------------------------------------------------------------- REPS

-- Rows sorted by (group name, header before children, name): a row whose parent is listed goes under that
-- parent's name; a row whose parent is not listed is top level (sorted by its own name).
function character.sortReps(rows)
    local byId = {}
    for _, r in ipairs(rows) do byId[r.id] = r end
    local keyed = {}
    for i, r in ipairs(rows) do
        local p = (r.parent and r.parent ~= 0) and byId[r.parent] or nil
        local name = r.name or ""
        keyed[i] = { r = r, g = p and (p.name or "") or name, c = p and 1 or 0, n = name, id = r.id or 0 }
    end
    table.sort(keyed, function(a, b)
        if a.g ~= b.g then return a.g < b.g end
        if a.c ~= b.c then return a.c < b.c end
        if a.n ~= b.n then return a.n < b.n end
        return a.id < b.id
    end)
    local out = {}
    for i, k in ipairs(keyed) do out[i] = k.r end
    return out
end

-- REPS <bot> <flags> <id,nameEsc,parent,rank,bar,max,flags;...>
handlers.REPS = function(req, f)
    local op = "REPS"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local rows, reason = bot:reputations()
    if failed(rows, reason) then return protocol.ackReason(req, low, op, false, reason) end
    local text = {}
    for i, r in ipairs(character.sortReps(rows)) do
        text[i] = table.concat({ num(r.id), util.esc(r.name or ""), num(r.parent), num(r.rank), num(r.bar), num(r.max),
            util.esc(r.flags or "") }, ",")
    end
    local head = "REPS\t" .. low .. "\tT\t"
    local joined, cut = character.capJoin(text, #head)
    send(req.low, "REPS", low, cut and "T" or "", joined)
end

-- ----------------------------------------------------------------------------- SKILLS

-- SKILLS <bot> <id,cat,value,max,pureMax,nameEsc;...>  (weapon / secondary / profession; by cat, then name)
handlers.SKILLS = function(req, f)
    local op = "SKILLS"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local rows, reason = bot:skills()
    if failed(rows, reason) then return protocol.ackReason(req, low, op, false, reason) end
    local list = {}
    for _, r in ipairs(rows) do
        if character.SKILL_CATS[r.cat] then
            local sl = wow.skillLine(r.id, req.locale)
            local name = (type(sl) == "table" and type(sl.name) == "string" and sl.name ~= "") and sl.name or ("#" .. num(r.id))
            list[#list + 1] = { r = r, name = name }
        end
    end
    table.sort(list, function(a, b)
        if a.r.cat ~= b.r.cat then return a.r.cat < b.r.cat end
        if a.name ~= b.name then return a.name < b.name end
        return (a.r.id or 0) < (b.r.id or 0)
    end)
    local text = {}
    for i, e in ipairs(list) do
        local r = e.r
        text[i] = table.concat({ num(r.id), num(r.cat), num(r.value), num(r.max), num(r.pureMax), util.esc(e.name) }, ",")
    end
    local head = "SKILLS\t" .. low .. "\t"
    local joined = character.capJoin(text, #head)
    send(req.low, "SKILLS", low, joined)
end

return character
