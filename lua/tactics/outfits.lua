-- Bot tactics / party window: saved outfits (party-window-spec 5.8). Store key `outfits` on the bot:
-- outfits joined by ";", each "idx\tnameEsc\titems", items "slot.entry.guid" joined by ":" (escaped names
-- never contain ";" or TAB, so the text is safe on the wire and in the DB). Wearing = bot:itemAction
-- ("equip") per item, found by guid in the bags (fallback: same entry). Messages: OUTFITS, OUTFIT.

local util = wow.include("util.lua")
local config = wow.include("config.lua")
local catalog = wow.include("catalog.lua")
local protocol = wow.include("protocol.lua")
local inventory = wow.include("inventory.lua")

local outfits = {}
local handlers = protocol.handlers
local send = protocol.send

local EQUIP_SLOTS = 19   -- equipment slots 0..18 (bag 255)

-- ----------------------------------------------------------------------------- store format

-- idx -> { idx, nameEsc, items = { {slot, entry, guid}, ... } }
function outfits.load(low)
    local out = {}
    local text = wow.storeGet(low, "outfits") or ""
    for _, part in ipairs(util.split(text, ";")) do
        local f = util.split(part, "\t")
        local idx = util.toint(f[1])
        if idx and idx >= 1 and idx <= config.OUTFITS_MAX and f[2] then
            local o = { idx = idx, nameEsc = f[2], items = {} }
            for _, it in ipairs(util.split(f[3] or "", ":")) do
                local slot, entry, guid = it:match("^(%d+)%.(%d+)%.(%d+)$")
                if slot then
                    o.items[#o.items + 1] = { slot = tonumber(slot), entry = tonumber(entry), guid = tonumber(guid) }
                end
            end
            out[idx] = o
        end
    end
    return out
end

local function itemsText(o)
    local t = {}
    for i, it in ipairs(o.items) do t[i] = it.slot .. "." .. it.entry .. "." .. it.guid end
    return table.concat(t, ":")
end

local function save(low, list)
    local parts = {}
    for idx = 1, config.OUTFITS_MAX do
        local o = list[idx]
        if o then parts[#parts + 1] = idx .. "\t" .. o.nameEsc .. "\t" .. itemsText(o) end
    end
    if #parts == 0 then
        return wow.storeErase(low, "outfits") or wow.storeGet(low, "outfits") == nil
    end
    return wow.storeSet(low, "outfits", table.concat(parts, ";"))
end

-- Outfit name: decoded text, 1..OUTFIT_NAME_MAX UTF-8 characters, no control characters.
function outfits.validName(name)
    if not name or name == "" or name:match("^%s*$") then return false end
    if name:find("[%z\1-\31\127]") then return false end
    return util.utf8len(name) <= config.OUTFIT_NAME_MAX and #name <= 4 * config.OUTFIT_NAME_MAX
end

-- ----------------------------------------------------------------------------- wear

local function isEquipPos(bag, slot) return bag == 255 and slot < EQUIP_SLOTS end

-- Backpack (255, 23..38) and equipped bags (19..22): the only places an item can be equipped from.
local function isBagPos(bag, slot) return (bag == 255 and slot >= 23 and slot <= 38) or (bag >= 19 and bag <= 22) end

-- Equip every item of outfit o. Returns worn (already equipped + newly equipped), total, and the first
-- C++ failure reason (nil when every attempted equip worked).
function outfits.wear(bot, o)
    local inv, reason = bot:inventory()
    if not inv then return 0, #o.items, reason or "failed" end
    local equipped, byGuid, byEntry = {}, {}, {}
    for _, it in ipairs(inv.items or {}) do
        if isEquipPos(it.bag, it.slot) then
            equipped[it.guid] = true
        elseif isBagPos(it.bag, it.slot) then
            byGuid[it.guid] = it
            byEntry[it.entry] = byEntry[it.entry] or {}
            table.insert(byEntry[it.entry], it)
        end
    end
    local worn, used, firstFail = 0, {}, nil
    for _, want in ipairs(o.items) do
        if equipped[want.guid] then
            worn = worn + 1
        else
            local it = byGuid[want.guid]
            if not it or used[it.guid] then
                it = nil
                for _, cand in ipairs(byEntry[want.entry] or {}) do
                    if not used[cand.guid] then it = cand; break end
                end
            end
            if it then
                used[it.guid] = true
                local ok, why = bot:itemAction("equip", it.bag, it.slot, it.guid, 0, 0)
                if ok then
                    worn = worn + 1
                elseif not firstFail then
                    firstFail = why or "failed"
                end
            end
        end
    end
    return worn, #o.items, firstFail
end

-- ----------------------------------------------------------------------------- messages

-- OUTFITS <bot> <idx,nameEsc,items;...>
local function sendOutfits(req, low)
    local list = outfits.load(low)
    local t = {}
    for idx = 1, config.OUTFITS_MAX do
        local o = list[idx]
        if o then t[#t + 1] = idx .. "," .. o.nameEsc .. "," .. itemsText(o) end
    end
    send(req.low, "OUTFITS", low, table.concat(t, ";"))
end

handlers.OUTFITS = function(req, f)
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), "OUTFITS", "bad_bot") end
    sendOutfits(req, low)
end

-- OUTFIT <bot> <save|wear|del|rename> <idx> <nameEsc>
handlers.OUTFIT = function(req, f)
    local op = "OUTFIT"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local what = f[3]
    local idx = util.toint(f[4])
    if not idx or idx < 1 or idx > config.OUTFITS_MAX then return protocol.ack(req, low, op, "bad_value", 0) end
    local list = outfits.load(low)
    local name = util.unesc(f[5] or "")

    if what == "save" then
        if name == "" then name = string.format(util.L(catalog.text.outfit_name, req.lang), idx) end
        if not outfits.validName(name) then return protocol.ack(req, low, op, "bad_name") end
        local inv, reason = bot:inventory()
        if not inv then return protocol.ackReason(req, low, op, false, reason) end
        local o = { idx = idx, nameEsc = util.esc(name), items = {} }
        for _, it in ipairs(inv.items or {}) do
            if isEquipPos(it.bag, it.slot) then
                o.items[#o.items + 1] = { slot = it.slot, entry = it.entry, guid = it.guid }
            end
        end
        table.sort(o.items, function(a, b) return a.slot < b.slot end)
        list[idx] = o
        if not save(low, list) then return protocol.ack(req, low, op, "store_failed") end
        protocol.ack(req, low, op, "ok")
    elseif what == "wear" then
        local o = list[idx]
        if not o then return protocol.ack(req, low, op, "bad_value", 0) end
        local worn, total, why = outfits.wear(bot, o)
        if worn == 0 and why then
            protocol.ackReason(req, low, op, false, why)
        else
            protocol.ackText(req, low, op, true, "ok", "outfit_worn", worn .. "/" .. total)
        end
        sendOutfits(req, low)
        return inventory.sendBags(req, bot, low, op)
    elseif what == "del" then
        if not list[idx] then return protocol.ack(req, low, op, "bad_value", 0) end
        list[idx] = nil
        if not save(low, list) then return protocol.ack(req, low, op, "store_failed") end
        protocol.ack(req, low, op, "ok")
    elseif what == "rename" then
        if not list[idx] then return protocol.ack(req, low, op, "bad_value", 0) end
        if not outfits.validName(name) then return protocol.ack(req, low, op, "bad_name") end
        list[idx].nameEsc = util.esc(name)
        if not save(low, list) then return protocol.ack(req, low, op, "store_failed") end
        protocol.ack(req, low, op, "ok")
    else
        return protocol.ack(req, low, op, "bad_op")
    end
    sendOutfits(req, low)
end

return outfits
