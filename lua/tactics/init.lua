-- Bot tactics (FF12-style gambits for party playerbots) - Lua entry point.
-- Loaded by the C++ host into every Lua state (one per map-update thread) after it created the globals
-- `tactics` (empty table) and `wow` (API, spec section 3.4). Must define:
--   tactics.evaluate(bot, ctx)        -> decisions | nil     (map thread, per bot per tick)
--   tactics.on_message(player, text)                         (world thread, addon payload)
--   tactics.on_event(event, player)                          (world thread, "login" | "logout")
-- Module files are loaded with wow.include (once per state). See README.md.

tactics = tactics or {}

local interpreter = wow.include("interpreter.lua")
local protocol = wow.include("protocol.lua")

-- Party window modules (party-window-spec 5.9): each adds its protocol.handlers.X.
-- aistat.lua: AISTAT of the AI layer (ai-layer-spec 8).
for _, file in ipairs({ "inventory.lua", "bots.lua", "talents.lua", "style.lua", "orders.lua", "veto.lua",
                        "outfits.lua", "loot.lua", "quests.lua", "character.lua", "vendor.lua", "trace.lua",
                        "aistat.lua" }) do
    wow.include(file)
end

-- Basic actions / manual mode (abilities-mirroring-spec 2.3, 3): basics.lua registers its catalogue entries
-- (also pulled in by actions.lua), manual.lua hooks the per-tick push of the manual flag.
wow.include("basics.lua")
wow.include("manual.lua")
-- Mirroring of the leader's actions (abilities-mirroring-spec 5.4): sets tactics.on_mirror, MIRROR* messages.
wow.include("mirror.lua")

tactics.evaluate = interpreter.evaluate
tactics.on_message = protocol.on_message
tactics.on_event = protocol.on_event

-- Headless bot simulation (".tactics sim ..."): the sim/ scripts are a development tool and are not shipped;
-- when the folder is present they add tactics.on_sim_command and tactics.on_tick.
local simOk, sim = pcall(wow.include, "sim/driver.lua")
if simOk and sim then
    tactics.on_sim_command = sim.on_command
    tactics.on_tick = sim.on_tick
end

-- Catalogue self-check: ids without an implementation are hidden from the editor; say so once per load.
local missing = interpreter.missingImplementations()
if #missing > 0 then
    wow.warn("catalog ids without implementation (hidden): " .. table.concat(missing, ", "))
end
