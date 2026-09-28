-- Bot tactics / party window extras: buy from a vendor and buy back (party-extras-spec 5.4, Bags tab card
-- "Торговец"). C++ lists the vendor / buyback rows and buys through the real client packets
-- (CMSG_BUY_ITEM / CMSG_BUYBACK_ITEM); field validation and texts are here.
-- Messages: VENDOR, BUY, BUYBACK, BUYBACKBUY.

local util = wow.include("util.lua")
local config = wow.include("config.lua")
local protocol = wow.include("protocol.lua")
local inventory = wow.include("inventory.lua")
local character = wow.include("character.lua")

local vendor = {}
local handlers = protocol.handlers
local send = protocol.send
local num = character.num

vendor.BUYBACK_FIRST = 74      -- BUYBACK_SLOT_START (Player.h:711)
vendor.BUYBACK_LAST = 85       -- BUYBACK_SLOT_END - 1

-- Integer field within [lo, hi], else nil.
local function intIn(field, lo, hi)
    local n = util.toint(field)
    if not n or n < lo or n > hi then return nil end
    return n
end

-- Item entry: id that fits the uint32 argument of the C++ binding (sol2 would wrap a larger number).
local function entryOf(field)
    local n = util.toid(field)
    if not n or n > 0xFFFFFFFF then return nil end
    return n
end

-- VENDOR <bot> <npcNameEsc> <flags> <slot,entry,price,count,ext;...>  (all empty when no vendor is near)
function vendor.send(req, bot, low)
    local op = "VENDOR"
    local rows, reason, npc = bot:vendorItems()
    if reason == "no_vendor" then return send(req.low, "VENDOR", low, "", "", "") end
    if type(rows) ~= "table" or (reason ~= nil and reason ~= "ok") then
        return protocol.ackReason(req, low, op, false, reason)
    end
    local text = {}
    for i, r in ipairs(rows) do
        text[i] = table.concat({ num(r.slot), num(r.entry), num(r.price), num(r.count), num(r.ext) }, ",")
    end
    local name = util.esc(type(npc) == "string" and npc or "")
    local head = "VENDOR\t" .. low .. "\t" .. name .. "\tT\t"
    local joined, cut = character.capJoin(text, #head)
    send(req.low, "VENDOR", low, name, cut and "T" or "", joined)
end

-- BUYBACK <bot> <slot,entry,count,price;...>
function vendor.sendBuyback(req, bot, low)
    local op = "BUYBACK"
    local rows, reason = bot:buyback()
    if type(rows) ~= "table" or (reason ~= nil and reason ~= "ok") then
        return protocol.ackReason(req, low, op, false, reason)
    end
    local text = {}
    for i, r in ipairs(rows) do
        text[i] = table.concat({ num(r.slot), num(r.entry), num(r.count), num(r.price) }, ",")
    end
    local joined = character.capJoin(text, #("BUYBACK\t" .. low .. "\t"))
    send(req.low, "BUYBACK", low, joined)
end

handlers.VENDOR = function(req, f)
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), "VENDOR", "bad_bot") end
    vendor.send(req, bot, low)
end

handlers.BUYBACK = function(req, f)
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), "BUYBACK", "bad_bot") end
    vendor.sendBuyback(req, bot, low)
end

-- BUY <bot> <slot> <entry> <count>   (count = stacks of the vendor's buy count)
handlers.BUY = function(req, f)
    local op = "BUY"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local slot = intIn(f[3], 0, 255)
    local entry = entryOf(f[4])
    local count = intIn(f[5], 1, config.BUY_MAX_COUNT)
    if not slot or not entry or not count then return protocol.ack(req, low, op, "bad_arg") end
    local ok, reason, gained, spent = bot:vendorBuy(slot, entry, count)
    protocol.ackReason(req, low, op, ok, reason, "bought",
        tostring(math.floor(tonumber(gained) or 0)) .. ", -" .. inventory.money(spent or 0, req.lang))
    if ok then
        inventory.sendBags(req, bot, low, op)
        vendor.send(req, bot, low)
    end
end

-- BUYBACKBUY <bot> <slot 74..85> <entry>
handlers.BUYBACKBUY = function(req, f)
    local op = "BUYBACKBUY"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local slot = intIn(f[3], vendor.BUYBACK_FIRST, vendor.BUYBACK_LAST)
    if not slot then return protocol.ack(req, low, op, "bad_pos") end
    local entry = entryOf(f[4])
    if not entry then return protocol.ack(req, low, op, "bad_arg") end
    local ok, reason, spent = bot:buybackBuy(slot, entry)
    protocol.ackReason(req, low, op, ok, reason, "bought_back", "-" .. inventory.money(spent or 0, req.lang))
    if ok then
        inventory.sendBags(req, bot, low, op)
        vendor.sendBuyback(req, bot, low)
    end
end

return vendor
