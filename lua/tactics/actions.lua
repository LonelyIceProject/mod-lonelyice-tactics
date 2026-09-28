-- Bot tactics: action semantics (spec section 8, "Actions").
-- Each entry is  build(env, u, rule) -> decision table or nil (nil = rule does not apply now; the
-- interpreter tries the next candidate unit, then the next rule).
-- A decision uses the C++ primitive verbs: cast, use, attack, move, follow, stop, wait, and (abilities-
-- mirroring-spec 10.1) melee, shoot, stopattack, cancel, pet, petcast, command
-- (fields: target, spell, item, x/y/z, dist, reach, tag, cmd, text; the interpreter adds slot and list).
-- "spell" and "item" are the two regular kinds (rule field x = spell id / item entry); the others
-- are the special actions listed in catalog.specials.

local config = wow.include("config.lua")

local actions = {}

-- Spell implicit targets that accept a unit other than the caster (SharedDefines Targets).
local UNIT_TARGETS = {
    [6] = true,   -- TARGET_UNIT_TARGET_ENEMY
    [21] = true,  -- TARGET_UNIT_TARGET_ALLY
    [25] = true,  -- TARGET_UNIT_TARGET_ANY
    [35] = true,  -- TARGET_UNIT_TARGET_PARTY
    [57] = true,  -- TARGET_UNIT_TARGET_RAID
}

-- item entry -> true when its on-use spell can only target the user (static data, cached per state)
local itemSelfOnly = {}

local function isSelfOnlyItem(entry)
    local cached = itemSelfOnly[entry]
    if cached ~= nil then return cached end
    local selfOnly = true
    local item = wow.item(entry)
    local spellId = item and item.useSpells and item.useSpells[1]
    local s = spellId and wow.spell(spellId)
    if s and s.targetA then
        for i = 1, #s.targetA do
            if UNIT_TARGETS[s.targetA[i]] then selfOnly = false end
        end
    end
    itemSelfOnly[entry] = selfOnly
    return selfOnly
end

-- Cast rule spell x (highest known rank) on the rule unit. Does not change the current target.
actions.spell = function(env, u, rule)
    local bot = env.bot
    local rank = bot:highestRank(rule.x)
    if not rank or rank == 0 then return nil end
    local ok = bot:canCast(rank, u)      -- out of range returns true, "range" (C++ moves into range)
    if not ok then return nil end
    return { verb = "cast", spell = rank, target = u:guid(), tag = "spell:" .. rule.x }
end

-- Use bag item x; on the rule unit if it is friendly and the item can target others, else on self.
actions.item = function(env, u, rule)
    local bot = env.bot
    local target = bot
    if u:guid() ~= env.guid and not isSelfOnlyItem(rule.x) and u:isFriendlyTo(bot) then
        target = u
    end
    local ok, reason = bot:canUse(rule.x, target)
    if not ok and reason ~= "range" then return nil end
    return { verb = "use", item = rule.x, target = target:guid(), tag = "item:" .. rule.x }
end

-- Switch the current target (the class AI keeps hitting it).
actions.attack = function(env, u, rule)
    local bot = env.bot
    if u:guid() == env.guid or not u:isHostileTo(bot) then return nil end
    local cur = bot:currentTarget()
    if cur and cur:guid() == u:guid() then return nil end
    return { verb = "attack", target = u:guid(), tag = "attack" }
end

-- Move to a point BEHIND_DIST yards behind the tank, on the line from the tank's victim through the tank.
actions.behind = function(env, u, rule)
    local bot = env.bot
    local tank
    local group = env:group()
    for i = 1, #group do
        local m = group[i]
        if m:guid() ~= env.guid and m:isAlive() and m:isTank() then
            if not tank or m:isMainTank() then tank = m end
            if m:isMainTank() then break end
        end
    end
    if not tank then return nil end
    local victim = tank:victim()
    if not victim then return nil end
    local tx, ty, tz = tank:position()
    local vx, vy = victim:position()
    if not tx or not vx then return nil end
    local dx, dy = tx - vx, ty - vy
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.1 then return nil end
    local px = tx + dx / len * config.BEHIND_DIST
    local py = ty + dy / len * config.BEHIND_DIST
    local bx, by = bot:position()
    if not bx then return nil end
    local ddx, ddy = bx - px, by - py
    if math.sqrt(ddx * ddx + ddy * ddy) <= config.BEHIND_TOLERANCE then return nil end
    return { verb = "move", x = px, y = py, z = tz, tag = "behind" }
end

-- Run to the leader (the bot's owner).
actions.follow = function(env, u, rule)
    local bot = env.bot
    local owner = bot:owner()
    if not owner then return nil end
    local d = bot:distance(owner)
    if d ~= nil and d <= config.FOLLOW_SKIP_DIST then return nil end
    return { verb = "follow", target = owner:guid(), tag = "follow" }
end

-- Do nothing; the interpreter stops collecting lower rules after it.
actions.wait = function(env, u, rule)
    return { verb = "wait", tag = "wait" }
end

-- Basic actions of abilities-mirroring-spec 2.3 (melee, shoot, stop_attack, move_to / move_away, stay,
-- cancel, pet_*, petspell, drink, eat): builders and catalogue entries live in basics.lua.
for id, build in pairs(wow.include("basics.lua").actions) do
    if actions[id] == nil then actions[id] = build end
end

-- Rule kinds that carry an id in x (the rest are catalog.specials without x). "cancel" is also a special
-- (the picker lists it there) but its x is the aura to remove.
actions.X_KINDS = { spell = "spell", item = "item", cancel = "spell", petspell = "spell" }

-- Side check for validation / evaluation: may action `a` be combined with a target of side `side`?
function actions.sideAllowed(a, side, catalog)
    local sp = catalog.specialById[a]
    if sp and sp.side == "foe" and side ~= "foe" then return false end
    return true
end

return actions
