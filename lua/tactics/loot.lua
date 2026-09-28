-- Bot tactics / party window: loot rules (party-window-spec 5.8). Store key `loot` on the bot:
-- "mode\ton\tentry,entry,..." (mode useful|normal|gray|all|disenchant, on 1/0 = strategy "loot" in the
-- non-combat list). Applied with playerbots chat commands ("ll <mode>", "nc +loot" / "nc -loot",
-- "ll <item links>" / "ll -<item links>"); playerbots does not keep the loot mode and list across a
-- relog, so the first evaluate after login re-applies them (var loot_applied). A bot without stored rules
-- gets DEFAULT_MODE ("useful": upgrades, quest items, needed consumables and trade goods, green and better;
-- no grey / white vendor trash). On "useful" the bot also throws away gear its auto-equip replaced and quest
-- rewards / leftovers it does not need (C++: EquipAction::EquipUpgrades, TacticsBagCleanup.cpp).
-- Messages: LOOT, SETLOOT.

local util = wow.include("util.lua")
local config = wow.include("config.lua")
local catalog = wow.include("catalog.lua")
local protocol = wow.include("protocol.lua")

local loot = {}
local handlers = protocol.handlers
local send = protocol.send

local MODES = util.set(catalog.lootModes)
loot.DEFAULT_MODE = "useful"

-- { mode, on (bool or nil when never set), items = {entry, ...} } or nil when the key is absent.
function loot.load(low)
    local text = wow.storeGet(low, "loot")
    if not text then return nil end
    local f = util.split(text, "\t")
    local r = { mode = MODES[f[1] or ""] and f[1] or loot.DEFAULT_MODE, items = {} }
    if f[2] == "1" then r.on = true elseif f[2] == "0" then r.on = false end
    for _, e in ipairs(util.split(f[3] or "", ",")) do
        local n = util.toid(e)
        if n then r.items[#r.items + 1] = n end
    end
    return r
end

local function save(low, r)
    local on = (r.on == true and "1") or (r.on == false and "0") or ""
    local items = {}
    for i, e in ipairs(r.items) do items[i] = tostring(e) end
    return wow.storeSet(low, "loot", r.mode .. "\t" .. on .. "\t" .. table.concat(items, ","))
end

-- Item link understood by ChatHelper::parseItems ("Hitem:<entry>:") and the command whitelist.
function loot.link(entry)
    return "|Hitem:" .. entry .. ":0|h[x]|h|r"
end

-- "ll <links>" / "ll -<links>" commands for a list of entries, each at most CMD_MAX bytes.
function loot.listCommands(entries, remove)
    local cmds = {}
    local head = remove and "ll -" or "ll "
    local cur
    for _, e in ipairs(entries) do
        local l = loot.link(e)
        if cur and #cur + #l <= config.CMD_MAX then
            cur = cur .. l
        else
            if cur then cmds[#cmds + 1] = cur end
            cur = head .. l
        end
    end
    if cur then cmds[#cmds + 1] = cur end
    return cmds
end

-- All commands that bring the bot to the stored state.
function loot.applyCommands(r)
    local cmds = { "ll " .. r.mode }
    if r.on ~= nil then cmds[#cmds + 1] = r.on and "nc +loot" or "nc -loot" end
    for _, c in ipairs(loot.listCommands(r.items, false)) do cmds[#cmds + 1] = c end
    return cmds
end

-- Evaluate hook (map thread): re-apply the stored rules once per login. Only under a real player's ownership:
-- a selfbot-led group (sim, ".playerbots bot self") also counts as owned, and there the commands would be
-- whispered "from" the leader bot. Not marked as applied then, so a later real owner still gets them.
function loot.ensure(bot, low)
    if wow.getVar(low, "loot_applied") then return end
    local owner = bot:owner()
    if not (owner and owner:isRealPlayer()) then return end
    wow.setVar(low, "loot_applied", 1)
    local r = loot.load(low) or { mode = loot.DEFAULT_MODE, items = {} }
    for _, cmd in ipairs(loot.applyCommands(r)) do protocol.runCommand(bot, cmd) end
end

-- LOOT <bot> <mode> <on> <entry,nameEsc;...>
local function sendLoot(req, bot, low, r)
    r = r or loot.load(low) or { mode = loot.DEFAULT_MODE, items = {} }
    local on = r.on
    if on == nil then
        on = false
        for _, name in ipairs(bot:strategies("nc") or {}) do
            if name == "loot" then on = true; break end
        end
    end
    local items = {}
    for i, e in ipairs(r.items) do
        local it = wow.item(e, req.locale)
        items[i] = e .. "," .. util.esc(it and it.name or ("#" .. e))
    end
    send(req.low, "LOOT", low, r.mode, on and "1" or "0", table.concat(items, ";"))
end

handlers.LOOT = function(req, f)
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), "LOOT", "bad_bot") end
    sendLoot(req, bot, low)
end

-- SETLOOT <bot> <mode|on|add|del> <value>
handlers.SETLOOT = function(req, f)
    local op = "SETLOOT"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local key, value = f[3], f[4] or ""
    local r = loot.load(low) or { mode = loot.DEFAULT_MODE, items = {} }
    local cmds
    if key == "mode" then
        if not MODES[value] then return protocol.ack(req, low, op, "bad_value", 0) end
        r.mode = value
        cmds = { "ll " .. value }
    elseif key == "on" then
        if value ~= "1" and value ~= "0" then return protocol.ack(req, low, op, "bad_value", 0) end
        r.on = value == "1"
        cmds = { r.on and "nc +loot" or "nc -loot" }
    elseif key == "add" or key == "del" then
        local entry = util.toid(value)
        if not entry or not wow.item(entry) then return protocol.ack(req, low, op, "bad_item_entry") end
        local pos
        for i, e in ipairs(r.items) do
            if e == entry then pos = i; break end
        end
        if key == "add" then
            if not pos then
                if #r.items >= config.LOOT_LIST_MAX then return protocol.ack(req, low, op, "too_many") end
                r.items[#r.items + 1] = entry
            end
        elseif pos then
            table.remove(r.items, pos)
        end
        cmds = loot.listCommands({ entry }, key == "del")
    else
        return protocol.ack(req, low, op, "bad_op")
    end
    if not save(low, r) then return protocol.ack(req, low, op, "store_failed") end
    wow.setVar(low, "loot_applied", 1)   -- the live bot gets the change right now
    for _, cmd in ipairs(cmds) do
        local ok, code = protocol.runCommand(bot, cmd)
        if not ok then
            protocol.ackReason(req, low, op, false, code)
            return sendLoot(req, bot, low, r)
        end
    end
    protocol.ack(req, low, op, "ok")
    sendLoot(req, bot, low, r)
end

return loot
