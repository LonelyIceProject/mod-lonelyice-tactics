-- Bot tactics / party window: one-shot orders "cast X on Y now" (AI stage 1a, party-window-spec 5.6).
-- ORDER stores the order in the bot's vars and wakes the bot; interpreter.evaluate returns it as the
-- first decision (slot ORDER_SLOT) until it runs, fails or expires (ORDER_TTL_MS). Vars on the bot:
-- order_spell (rank to cast), order_req (spell id the player asked for), order_target (GUID hex),
-- order_until (ms), order_owner (player low guid), order_lang (ru/en of the owner).

local util = wow.include("util.lua")
local config = wow.include("config.lua")
local protocol = wow.include("protocol.lua")
local profile = wow.include("profile.lua")

local orders = {}
local handlers = protocol.handlers

local VARS = { "order_spell", "order_req", "order_target", "order_until", "order_owner", "order_lang" }

-- Reasons that keep the order alive (moving into range, still casting, out of range without reach).
orders.KEEP = util.set({ "reach", "busy", "range" })

local function clear(bot, low)
    for _, k in ipairs(VARS) do wow.setVar(low, k, nil) end
    profile.syncWake(bot, low)   -- stays awake for the default AI slider on an empty store (ai-layer-spec 2.4)
end

-- ORDER <bot> <spell> <status> <reasonEsc> to the player who gave the order.
local function report(low, status, reason)
    local owner = wow.getVar(low, "order_owner")
    if not owner then return end
    local lang = wow.getVar(low, "order_lang") or "en"
    local text = ""
    if reason then text = util.esc(protocol.text(reason, lang)) end
    protocol.send(owner, "ORDER", low, wow.getVar(low, "order_req") or 0, status, text)
end

-- ORDER <bot> <spell> <guid>
handlers.ORDER = function(req, f)
    local op = "ORDER"
    local bot, low = protocol.ownedBot(req, f[2])
    if not bot then return protocol.ack(req, protocol.botEcho(f[2]), op, "bad_bot") end
    local spell = util.toid(f[3])
    local s = spell and wow.spell(spell)
    local rank = s and bot:highestRank(spell) or 0
    if not s or s.passive or not rank or rank == 0 then return protocol.ack(req, low, op, "bad_spell") end
    local guid = protocol.guidHex(f[4])
    local target = guid and wow.unit(guid)   -- nil for an empty (all-zero) guid
    if not target or not target:valid() then return protocol.ack(req, low, op, "bad_target") end
    wow.setVar(low, "order_spell", rank)
    wow.setVar(low, "order_req", spell)
    wow.setVar(low, "order_target", guid)
    wow.setVar(low, "order_until", wow.now() + config.ORDER_TTL_MS)
    wow.setVar(low, "order_owner", req.low)
    wow.setVar(low, "order_lang", req.lang)
    bot:wake(true)
    protocol.ack(req, low, op, "ok")
end

-- Outcome of the previous tick when it was the order (ctx.last.slot == ORDER_SLOT).
function orders.onLast(bot, last)
    local low = bot:lowGuid()
    if not wow.getVar(low, "order_spell") then return end
    if last.ok and last.reason == "ok" then
        report(low, "done")
        clear(bot, low)
    elseif not orders.KEEP[last.reason or ""] then
        report(low, "failed", last.reason or "failed")
        clear(bot, low)
    end
end

-- The order decision for this tick, or nil (expired orders are reported and dropped here).
function orders.decision(bot, listName, now)
    local low = bot:lowGuid()
    local spell = wow.getVar(low, "order_spell")
    if not spell then return nil end
    local untilMs = wow.getVar(low, "order_until") or 0
    if now - untilMs > 0 then
        report(low, "expired", "order_expired")
        clear(bot, low)
        return nil
    end
    return { slot = config.ORDER_SLOT, list = listName, verb = "cast", spell = spell,
             target = wow.getVar(low, "order_target"), reach = true, tag = "order" }
end

return orders
