-- Bot tactics / party window: bags, item actions, stats, trainer (party-window-spec 5.3, 4.1, 4.2).
-- C++ (P1) lists and moves items with real client packets; everything here is message format and
-- validation. Messages: INV -> BAGS, ITEM, SELLGREY, STATS, TRAIN -> TRAINER.

local util = wow.include("util.lua")
local config = wow.include("config.lua")
local catalog = wow.include("catalog.lua")
local protocol = wow.include("protocol.lua")
local spellbook = wow.include("spellbook.lua")

local inventory = {}
local handlers = protocol.handlers
local send = protocol.send

-- Operations of bot:itemAction (party-window-spec 2.3).
inventory.OPS = util.set({ "equip", "unequip", "use", "sell", "destroy", "move", "give", "deposit", "withdraw" })

local MAX_U32 = 4294967295

-- "12g 3s 40c" (localized unit letters). copper may be negative (shown with "-").
function inventory.money(copper, lang)
    copper = math.floor(tonumber(copper) or 0)
    local sign = ""
    if copper < 0 then sign, copper = "-", -copper end
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. util.L(catalog.text.money_g, lang) end
    if s > 0 then parts[#parts + 1] = s .. util.L(catalog.text.money_s, lang) end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. util.L(catalog.text.money_c, lang) end
    return sign .. table.concat(parts, " ")
end

-- Item guid field: decimal low guid (as sent in BAGS); a 16-digit hex GUID is accepted too (low 32 bits).
function inventory.itemGuid(field)
    local n = util.toid(field)
    if n then return (n <= MAX_U32) and n or nil end
    local hex = protocol.guidHex(field)
    if hex then
        n = tonumber(hex:sub(9), 16)
        if n and n > 0 then return n end
    end
    return nil
end

-- Non-negative integer field <= max ("" = 0).
local function uint(field, max)
    if field == nil or field == "" then return 0 end
    local n = util.toint(field)
    if not n or n < 0 or n > max then return nil end
    return n
end

-- ----------------------------------------------------------------------------- BAGS

local function str(v)
    if v == nil then return "" end
    if v == true then return "1" end
    if v == false then return "0" end
    return tostring(v)
end

-- Only [a-z0-9:] may pass through unescaped flag / fits fields (C++ builds them; be strict anyway).
local function safe(v)
    local s = str(v)
    if s:find("[^%w:]") then return util.esc(s) end
    return s
end

local function num(v)
    return tostring(math.floor(tonumber(v) or 0))
end

-- Build the BAGS payload from a bot:inventory() table (capped at BAGS_MAX_BYTES, flag "T" when cut).
function inventory.buildBags(low, inv)
    local containers = {}
    for i, c in ipairs(inv.containers or {}) do
        containers[i] = table.concat({ safe(c.kind), num(c.bag), num(c.start), num(c.size), num(c.entry) }, ",")
    end
    local flags = safe(inv.flags)
    local head = table.concat({ "BAGS", low, num(inv.money), "", table.concat(containers, ";"), "" }, "\t")
    local budget = config.BAGS_MAX_BYTES - #head - #flags - 1   -- 1 = a possible "T"
    local items, used, cut = {}, 0, false
    for _, it in ipairs(inv.items or {}) do
        local row = table.concat({ num(it.bag), num(it.slot), num(it.guid), num(it.entry), num(it.count),
            num(it.ench), num(it.gem1), num(it.gem2), num(it.gem3), num(it.rprop), num(it.suffix),
            num(it.dur), num(it.maxdur), safe(it.flags), safe(it.fits) }, ",")
        local add = #row + ((#items > 0) and 1 or 0)
        if used + add > budget then
            cut = true
            break
        end
        items[#items + 1] = row
        used = used + add
    end
    if cut then flags = flags .. "T" end
    return table.concat({ "BAGS", low, num(inv.money), flags, table.concat(containers, ";"),
        table.concat(items, ";") }, "\t")
end

-- Send BAGS for an owned bot; on failure an ACK err of op (default "INV").
function inventory.sendBags(req, bot, low, op)
    local inv, reason = bot:inventory()
    if not inv then return protocol.ackReason(req, low, op or "INV", false, reason) end
    send(req.low, inventory.buildBags(low, inv))
end

-- ----------------------------------------------------------------------------- handlers

handlers.INV = function(req, f)
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), "INV", "bad_bot") end
    inventory.sendBags(req, bot, low)
end

-- ITEM <bot> <op> <bag> <slot> <guid> <a> <b>
handlers.ITEM = function(req, f)
    local op = "ITEM"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local what = f[3]
    if not inventory.OPS[what or ""] then return protocol.ack(req, low, op, "bad_op") end
    local bag, slot = uint(f[4], 255), uint(f[5], 255)
    local guid = inventory.itemGuid(f[6])
    local a, b = uint(f[7], MAX_U32), uint(f[8], MAX_U32)
    if not bag or not slot or f[4] == "" or f[5] == "" then return protocol.ack(req, low, op, "bad_pos") end
    if not guid then return protocol.ack(req, low, op, "stale") end
    if not a or not b then return protocol.ack(req, low, op, "bad_pos") end
    if what == "move" and (a > 255 or b > 255) then return protocol.ack(req, low, op, "bad_pos") end
    local ok, reason = bot:itemAction(what, bag, slot, guid, a, b)
    protocol.ackReason(req, low, op, ok, reason)
    if ok then inventory.sendBags(req, bot, low, op) end
end

handlers.SELLGREY = function(req, f)
    local op = "SELLGREY"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local ok, reason, sold, money = bot:sellGrey()
    protocol.ackReason(req, low, op, ok, reason, "sold",
        tostring(sold or 0) .. ", +" .. inventory.money(money or 0, req.lang))
    if ok then inventory.sendBags(req, bot, low, op) end
end

-- STATS <bot> -> STATS <bot> key=value;...  (%g numbers, keys sorted)
handlers.STATS = function(req, f)
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), "STATS", "bad_bot") end
    local stats = bot:stats()
    if not stats then return protocol.ack(req, low, "STATS", "failed") end
    local keys = {}
    for k, v in pairs(stats) do
        if type(k) == "string" and k:match("^[%w_]+$") and type(v) == "number" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local kv = {}
    for i, k in ipairs(keys) do
        local v = stats[k]
        if v ~= v or v == math.huge or v == -math.huge then v = 0 end   -- NaN / inf
        kv[i] = k .. "=" .. string.format("%g", v)
    end
    send(req.low, "STATS", low, table.concat(kv, ";"))
end

-- TRAINER <bot> <npcNameEsc> <spell,cost,can;...>  (empty when no trainer near the bot)
function inventory.sendTrainer(req, bot, low)
    -- rows, reason (nil = ok), trainer name in the message player's locale (nil on error)
    local rows, _, npc = bot:trainerSpells()
    local out = {}
    if type(rows) == "table" then
        for _, r in ipairs(rows) do
            out[#out + 1] = num(r.spell) .. "," .. num(r.cost) .. "," .. (r.canLearn and "1" or "0")
        end
    end
    if type(npc) ~= "string" then npc = "" end
    send(req.low, "TRAINER", low, util.esc(npc or ""), table.concat(out, ";"))
end

-- TRAIN <bot> <0/1>: 0 = list only; 1 = learn everything affordable.
handlers.TRAIN = function(req, f)
    local op = "TRAIN"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    if f[3] ~= "0" and f[3] ~= "1" then return protocol.ack(req, low, op, "bad_value", 0) end
    if f[3] == "1" then
        local ok, reason, learned, spent = bot:trainerLearnAll()
        protocol.ackReason(req, low, op, ok, reason, "learned",
            tostring(learned or 0) .. ", -" .. inventory.money(spent or 0, req.lang))
        inventory.sendTrainer(req, bot, low)
        if ok then send(req.low, spellbook.build(bot, req.locale)) end
        return
    end
    inventory.sendTrainer(req, bot, low)
end

return inventory
