-- Bot tactics: per (bot, leader) settings in the character_tactics store (tactics-round2-spec 4).
--
-- Every key a player configures on a bot is stored under "l<leaderLow>_<key>", so the same player
-- re-inviting the bot gets their setup back and another leader gets their own. Keys of other scopes stay
-- plain: per bot (`outfits`, `loot`, `last_leader`) and per player (`formation`, `rti`, the pull card
-- `pull` on the PLAYER guid). No schema change: names still match [a-z0-9_]{1,32}
-- ("l4294967295_enabled" = 19 chars).
--
-- Leader = bot:ownerLow() (the real leader, else the real master; the selfbot leader in the sim). When it
-- is 0 (bot outside any owned group) reads use `last_leader`, a per-bot plain key written on every
-- namespaced write; nothing is written without a leader.
--
-- Legacy rows (plain `enabled`, `active`, `p1`..`p5`, `veto`, `ai` from before this change) move lazily to
-- the first leader that loads the bot (store.migrate). Whole-server alternative:
-- data\sql\custom\tactics_migrate_leader.sql (run by hand).
-- Leaf module: includes nothing (store.lua is used by rules.lua, protocol.lua and the party modules).

local store = {}

-- Keys namespaced per (bot, leader).
store.LEADER_KEYS = { enabled = 1, active = 1, p1 = 1, p2 = 1, p3 = 1, p4 = 1, p5 = 1, veto = 1, ai = 1,
                      style = 1, pull = 1, aicfg = 1, manual = 1 }

-- Legacy (pre per-leader) keys that store.migrate moves, in this order. `style`, `pull` and `aicfg` did not
-- exist per bot before, and a plain `pull` on a player guid is the pull card: never moved.
store.LEGACY_KEYS = { "enabled", "active", "p1", "p2", "p3", "p4", "p5", "veto", "ai" }
local LEGACY_SET = {}
for _, k in ipairs(store.LEGACY_KEYS) do LEGACY_SET[k] = true end

store.LAST_LEADER = "last_leader"

local function validLeader(leader)
    return type(leader) == "number" and leader > 0 and leader == math.floor(leader)
end

-- "l" .. leader .. "_" .. key
function store.key(key, leader)
    return "l" .. string.format("%d", leader) .. "_" .. key
end

-- "l<leader>_" prefix, nil without a leader.
function store.prefix(leader)
    if not validLeader(leader) then return nil end
    return "l" .. string.format("%d", leader) .. "_"
end

-- Store name of `key` for a leader: namespaced for a leader key with a leader, plain otherwise
-- (a leader key without a leader reads the plain legacy row).
local function nameOf(key, leader)
    if store.LEADER_KEYS[key] and validLeader(leader) then return store.key(key, leader) end
    return key
end
store.nameOf = nameOf

-- Leader of a bot: bot:ownerLow(), else the stored last_leader, else nil.
function store.leaderOf(bot)
    local owner = bot:ownerLow()
    if validLeader(owner) then return owner end
    local last = tonumber(wow.storeGet(bot:lowGuid(), store.LAST_LEADER) or "")
    if validLeader(last) then return last end
    return nil
end

function store.forLeader(bot)
    return bot:lowGuid(), store.leaderOf(bot)
end

-- last_leader follows every namespaced write (written only when it changes: every write bumps the
-- store revision of the bot).
local function touchLeader(low, leader)
    local s = string.format("%d", leader)
    if wow.storeGet(low, store.LAST_LEADER) ~= s then wow.storeSet(low, store.LAST_LEADER, s) end
end

-- Does the bot have any key of this leader? (storeAll: only called when a legacy row exists)
local function hasLeaderKeys(low, prefix)
    local plen = #prefix
    for name in pairs(wow.storeAll(low) or {}) do
        if name:sub(1, plen) == prefix then return true end
    end
    return false
end

-- A leader that has no key of its own yet reads the legacy rows (what store.migrate would move to it):
-- the same answer before and after the lazy migration, whichever code path reads first.
function store.get(low, key, leader)
    local name = nameOf(key, leader)
    local v = wow.storeGet(low, name)
    if v == nil and name ~= key and LEGACY_SET[key] then
        local legacy = wow.storeGet(low, key)
        if legacy ~= nil and not hasLeaderKeys(low, store.prefix(leader)) then return legacy end
    end
    return v
end

-- Move the legacy rows to `leader` when it has no key of its own yet (the "move" of spec 4.3: another
-- leader must not inherit them). Returns the number of keys moved.
local function moveLegacy(low, leader)
    local raw = wow.storeAll(low) or {}
    local prefix = store.prefix(leader)
    local plen = #prefix
    local legacy = false
    for name in pairs(raw) do
        if name:sub(1, plen) == prefix then return 0 end
        if LEGACY_SET[name] then legacy = true end
    end
    if not legacy then return 0 end
    local n = 0
    for _, key in ipairs(store.LEGACY_KEYS) do
        local data = raw[key]
        if data ~= nil and wow.storeSet(low, prefix .. key, data) then
            wow.storeErase(low, key)
            n = n + 1
        end
    end
    if n > 0 then
        touchLeader(low, leader)
        wow.log("tactics: moved " .. n .. " setting(s) of bot " .. low .. " to leader " .. leader)
    end
    return n
end

-- A write of a leader key that has no row of that leader yet moves the legacy rows first (the leader's
-- first own key must not hide the other legacy keys from it). moveLegacy is a no-op once the leader has keys.
local function moveBeforeWrite(low, key, leader)
    if wow.storeGet(low, store.key(key, leader)) == nil then moveLegacy(low, leader) end
end

-- false (and nothing written) for a leader key without a leader.
function store.set(low, key, data, leader)
    if store.LEADER_KEYS[key] then
        if not validLeader(leader) then return false end
        moveBeforeWrite(low, key, leader)
        if not wow.storeSet(low, store.key(key, leader), data) then return false end
        touchLeader(low, leader)
        return true
    end
    return wow.storeSet(low, key, data)
end

-- true when the row was removed (false also when it did not exist, as wow.storeErase).
function store.erase(low, key, leader)
    if store.LEADER_KEYS[key] then
        if not validLeader(leader) then return false end
        moveBeforeWrite(low, key, leader)
    end
    return wow.storeErase(low, nameOf(key, leader))
end

-- The rows of a bot as one leader sees them: that leader's keys without the prefix plus the plain keys
-- that are not leader keys. Without a leader: the plain (legacy) rows. Other leaders' rows never show.
-- A leader without any key of its own sees the legacy rows (as store.get). Returns view, raw.
function store.view(low, leader)
    local raw = wow.storeAll(low) or {}
    local out = {}
    local prefix = store.prefix(leader)
    local plen = prefix and #prefix or 0
    local own = false
    for name, data in pairs(raw) do
        if prefix and name:sub(1, plen) == prefix then
            out[name:sub(plen + 1)] = data
            own = true
        elseif not name:find("^l%d+_") then
            if not (prefix and store.LEADER_KEYS[name]) then out[name] = data end
        end
    end
    if prefix and not own then
        for _, key in ipairs(store.LEGACY_KEYS) do
            if raw[key] ~= nil then out[key] = raw[key] end
        end
    end
    return out, raw
end

-- ----------------------------------------------------------------------------- migration (spec 4.3)

-- Move the legacy keys of a bot to `leader` when that leader has no key of its own yet. Runs once per
-- (low, leader) and bot session: the var mig_<leader> on the bot is shared by every Lua state (map
-- threads) and survives a script reload; it is cleared on the bot's relog, then the "already has keys"
-- test makes the next run a no-op. Per call: one getVar. Returns the number of keys moved.
function store.migrate(low, leader)
    if not low or low == 0 or not validLeader(leader) then return 0 end
    local var = "mig_" .. string.format("%d", leader)
    if wow.getVar(low, var) then return 0 end
    wow.setVar(low, var, 1)
    return moveLegacy(low, leader)
end

return store
