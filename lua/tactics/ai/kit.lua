-- Bot tactics / AI layer: the bot's spell and item kit, classified from spell data (ai-layer-spec 4).
-- Static per-spell classification is cached per Lua state; the per-bot kit (kits[low]) is rebuilt when the
-- bot's level, number of known spells or their id checksum (new rank) changed, checked at most every AI_KIT_TTL_MS. Only first ranks are
-- stored; `rank` is bot:highestRank(first) at build time. kit.OVERRIDE fixes what the heuristics misread.
-- Round 2 (tactics-round2-spec 1.1): mana lists manaCd / manaChannel / manaCdFriend, bag list manaPotion
-- (potions and mana gems), and per healDirect entry `ranks` = the known ranks of the chain, ascending.

local config = wow.include("config.lua")
local spellbook = wow.include("spellbook.lua")

local kit = {}

-- SharedDefines --------------------------------------------------------------------------------------
local EFF_HEAL, EFF_HEAL_MAX_HEALTH, EFF_HEAL_PCT, EFF_DISPEL, EFF_INTERRUPT = 10, 67, 136, 38, 68
local AURA_PERIODIC_HEAL, AURA_STUN, AURA_SILENCE, AURA_ABSORB, AURA_DMG_TAKEN = 8, 12, 27, 69, 87
local TARGET_SELF, TARGET_ENEMY = 1, 6
local HEAL_EFFECTS = { [EFF_HEAL] = true, [EFF_HEAL_MAX_HEALTH] = true, [EFF_HEAL_PCT] = true }
local POTION_EFFECTS = { [EFF_HEAL] = true, [EFF_HEAL_PCT] = true }
-- friendly unit targets: TARGET_UNIT_TARGET_ALLY 21, _ANY 25, _PARTY 35, _RAID 57, _CHAINHEAL_ALLY 45
local FRIEND_TARGETS = { [21] = true, [25] = true, [35] = true, [57] = true, [45] = true }
-- absorb, damage taken %, school immunity, dodge, parry, max health
local DEFENSIVE_AURAS = { [69] = true, [87] = true, [39] = true, [49] = true, [47] = true, [230] = true }
-- crit, haste, damage done %, melee/ranged haste, casting speed, attack power (+%), damage done
local OFFENSIVE_AURAS = { [52] = true, [65] = true, [79] = true, [138] = true, [140] = true, [216] = true,
                          [99] = true, [166] = true, [13] = true }

kit.BIG_MS = 120000
kit.MEDIUM_MS = 30000
kit.LONG_CD_MS = 60000

-- first-rank id -> kit list ("interrupt", "defensive", "burst", "guard", ...) or false (ignore). Checked
-- against Spell.dbc 3.3.5 (scratchpad tactics\ai_spells.py): these are the expected members the heuristics
-- cannot find or put in the wrong list.
kit.OVERRIDE = {
    [16979] = "interrupt",  -- Feral Charge - Bear: charge + triggered interrupt (effects 96, 64)
    [12975] = "defensive",  -- Last Stand: dummy effect
    [61336] = "defensive",  -- Survival Instincts: dummy aura
    [642] = "defensive",    -- Divine Shield: aura 79 (-100% damage done) reads as offensive
    [1719] = "burst",       -- Recklessness: aura 87 (+damage taken) reads as defensive
    [13750] = "burst",      -- Adrenaline Rush: energy regen aura
    [12042] = "burst",      -- Arcane Power: spell modifier auras
    [50334] = "burst",      -- Berserk: spell modifier auras
    [10060] = "burst",      -- Power Infusion: ally target (cast on self)
    [2825] = "burst",       -- Bloodlust: raid area target
    [32182] = "burst",      -- Heroism: raid area target
    [47788] = "guard",      -- Guardian Spirit: aura 118/69
    [6940] = "guard",       -- Hand of Sacrifice: aura 81 (split damage)
    -- mana economy (tactics-round2-spec 1.1)
    [34433] = "manaCd",     -- Shadowfiend: summon (effect 28) + dummy
    [16190] = "manaCd",     -- Mana Tide Totem: summon totem (effect 28)
    [54428] = "manaCd",     -- Divine Plea: aura 21 + 87 (read as defensive without this)
    [31842] = "manaCd",     -- Divine Illumination: aura 72 (spell cost modifier)
    [12051] = "manaChannel", -- Evocation: channeled aura 21
    [64901] = "manaChannel", -- Hymn of Hope: channeled periodic trigger (aura 23)
    [29166] = "manaCdFriend", -- Innervate: aura 24 on an ally
    [47755] = false,        -- Rapture: triggered energize (talent passive)
    [12043] = false,        -- Presence of Mind
}

-- Defensive cooldowns a tank must not use on its own: they drop its threat (Divine Shield). preserve_self
-- skips them when the bot's role is tank.
kit.TANK_UNSAFE = { [642] = true }

-- Dispel types by first rank when wow.spell().misc is missing (older server build).
kit.DISPEL_FALLBACK = {
    [528] = { [3] = true }, [552] = { [3] = true }, [527] = { [1] = true },
    [1152] = { [3] = true, [4] = true }, [4987] = { [1] = true, [3] = true, [4] = true },
    [526] = { [3] = true, [4] = true }, [51886] = { [2] = true, [3] = true, [4] = true },
    [8946] = { [4] = true }, [2893] = { [4] = true }, [2782] = { [2] = true }, [475] = { [2] = true },
}

-- A shield that cannot be put on a target carrying this aura (Power Word: Shield -> Weakened Soul).
kit.SHIELD_BLOCK = { [17] = 6788 }

kit.LISTS = { "interrupt", "dispelFriend", "dispelFoe", "healDirect", "healHot", "shield", "defensive", "guard",
              "burst", "burstMedium", "manaCd", "manaCdFriend", "manaChannel" }

-- Mana restoration (SharedDefines: SPELL_EFFECT_ENERGIZE 30; SPELL_AURA_OBS_MOD_POWER 21, PERIODIC_ENERGIZE 24,
-- MOD_POWER_REGEN 85, MOD_POWER_REGEN_PERCENT 110; misc 0 = POWER_MANA)
local EFF_ENERGIZE = 30
local MANA_SELF_AURAS = { [21] = true, [24] = true, [85] = true, [110] = true }
-- Innervate is aura 24 (PERIODIC_ENERGIZE) in 3.3.5 data, so 24 counts for the friend list too
local MANA_FRIEND_AURAS = { [24] = true, [85] = true, [110] = true }
local ITEM_CONSUMABLE, ITEM_ARMOR, SUBCLASS_POTION = 0, 4, 1
local RANK_WALK_MAX = 20

-- ----------------------------------------------------------------------------- static spell data

local sdata = {}      -- id -> wow.spell table | false
local classes = {}    -- first rank id -> { list names } | false

local function spell(id)
    local s = sdata[id]
    if s == nil then
        s = wow.spell(id) or false
        sdata[id] = s
    end
    return s or nil
end
kit.spell = spell

local function recoveryOf(s)
    local a, b = s.recovery or 0, s.categoryRecovery or 0
    return a > b and a or b
end

local function anyIn(arr, set)
    if not arr then return false end
    for i = 1, 3 do
        local v = arr[i]
        if v and set[v] then return true end
    end
    return false
end

local function has(arr, value)
    if not arr then return false end
    for i = 1, 3 do
        if arr[i] == value then return true end
    end
    return false
end

-- selfOnly, friend, enemy
local function targetsOf(s)
    local t = s.targetA
    local any, selfOnly, friend, enemy = false, true, false, false
    if t then
        for i = 1, 3 do
            local v = t[i]
            if v and v ~= 0 then
                any = true
                if v ~= TARGET_SELF then selfOnly = false end
                if FRIEND_TARGETS[v] then friend = true end
                if v == TARGET_ENEMY then enemy = true end
            end
        end
    end
    return any and selfOnly, friend, enemy
end
kit.targetsOf = targetsOf

-- Does the spell restore mana: an energize effect (with `energize`) or one of `auras`, misc 0 (mana)?
-- misc missing (older server build) counts as mana.
local function restoresMana(s, auras, energize)
    local eff, aur, misc = s.effects, s.auras, s.misc
    for i = 1, 3 do
        local m = misc and misc[i] or 0
        if m == 0 then
            if energize and eff and eff[i] == EFF_ENERGIZE then return true end
            local a = aur and aur[i]
            if a and auras[a] then return true end
        end
    end
    return false
end

-- Kit list names of a first-rank spell id (static), or nil.
function kit.classify(id)
    local c = classes[id]
    if c ~= nil then return c or nil end
    local s = spell(id)
    local ov = kit.OVERRIDE[id]
    if not s or ov == false then
        classes[id] = false
        return nil
    end
    local out = {}
    local rec = recoveryOf(s)
    local cast = s.castTime or 0
    local selfOnly, friend, enemy = targetsOf(s)
    local notNegative = s.positive ~= false
    if ov then
        if ov == "burst" and rec < kit.BIG_MS then ov = "burstMedium" end
        out[1] = ov
    else
        -- interrupts (stuns flagged, used on non-elite targets only)
        if s.positive ~= true and enemy and cast == 0 then
            if has(s.effects, EFF_INTERRUPT) or has(s.auras, AURA_SILENCE) then
                out[#out + 1] = "interrupt"
            elseif has(s.auras, AURA_STUN) and rec <= kit.LONG_CD_MS then
                out[#out + 1] = "interrupt"
            end
        end
        if has(s.effects, EFF_DISPEL) then
            if friend and notNegative then out[#out + 1] = "dispelFriend"
            elseif enemy then out[#out + 1] = "dispelFoe" end
        end
        if anyIn(s.effects, HEAL_EFFECTS) and friend and notNegative and not s.channeled and cast <= 3500
            and rec < kit.LONG_CD_MS then
            out[#out + 1] = "healDirect"
        end
        if has(s.auras, AURA_PERIODIC_HEAL) and friend and notNegative and cast <= 1500 then
            out[#out + 1] = "healHot"
        end
        if has(s.auras, AURA_ABSORB) and (friend or selfOnly) and notNegative and rec < kit.LONG_CD_MS then
            out[#out + 1] = "shield"
        end
        if notNegative and cast == 0 and rec >= kit.LONG_CD_MS then
            local def = anyIn(s.auras, DEFENSIVE_AURAS)
            local off = anyIn(s.auras, OFFENSIVE_AURAS)
            if selfOnly and def and not off then
                out[#out + 1] = "defensive"
            elseif friend and not selfOnly and has(s.auras, AURA_DMG_TAKEN) then
                out[#out + 1] = "guard"
            elseif selfOnly and off and rec >= kit.BIG_MS then
                out[#out + 1] = "burst"
            end
        end
        if notNegative and cast == 0 and selfOnly and rec >= kit.MEDIUM_MS and rec < kit.BIG_MS
            and anyIn(s.auras, OFFENSIVE_AURAS) and not anyIn(s.auras, DEFENSIVE_AURAS) then
            out[#out + 1] = "burstMedium"
        end
        -- mana cooldowns (round 2, 1.1)
        if notNegative and rec >= kit.LONG_CD_MS then
            if selfOnly and cast == 0 and restoresMana(s, MANA_SELF_AURAS, true) then
                out[#out + 1] = s.channeled and "manaChannel" or "manaCd"
            elseif friend and not selfOnly and restoresMana(s, MANA_FRIEND_AURAS, false) then
                out[#out + 1] = "manaCdFriend"
            end
        end
    end
    if #out == 0 then out = false end
    classes[id] = out
    return out or nil
end

-- Dispel types (set) of a dispel spell: misc values of its dispel effects, else the fallback table.
local function dispelTypes(first, s)
    local t
    if s.misc then
        for i = 1, 3 do
            local m = s.misc[i]
            if s.effects and s.effects[i] == EFF_DISPEL and m and m >= 1 and m <= 4 then
                t = t or {}
                t[m] = true
            end
        end
    end
    return t or kit.DISPEL_FALLBACK[first] or {}
end

-- ----------------------------------------------------------------------------- helpers

-- Cost of a spell rank in percent of the bot's max mana (0 for non-mana spells).
function kit.costPct(bot, spellId)
    local s = spell(spellId)
    if not s or (s.powerType or 0) ~= 0 then return 0 end
    local cost = s.cost or 0
    if cost > 0 then
        local mx = bot:maxPower(0)
        if not mx or mx <= 0 then return 0 end
        return cost / mx * 100
    end
    return s.costPct or 0
end

function kit.cdClass(recoveryMs)
    recoveryMs = recoveryMs or 0
    if recoveryMs >= kit.BIG_MS then return "big" end
    if recoveryMs >= kit.MEDIUM_MS then return "medium" end
    return "small"
end

local function sortBy(list, key, desc)
    table.sort(list, function(a, b)
        local x, y = a[key] or 0, b[key] or 0
        if x ~= y then
            if desc then return x > y end
            return x < y
        end
        return a.first < b.first
    end)
end

-- Healing potions (preserve_self) and, round 2 (1.1), mana potions / mana gems: the first on-use spell
-- energizes mana on the user. Potions are class 0 subclass 1; gems are class 0 subclass 0 (Mana Agate 5514
-- is class 4 in this core's item data). One pass over the bags for both lists.
local NO_AURAS = {}
local function potions(bot)
    local out, mana = {}, {}
    local bag = bot:items() or {}
    for i = 1, #bag do
        local it = wow.item(bag[i].entry)
        local cls = it and it.class
        local useId = (cls == ITEM_CONSUMABLE or cls == ITEM_ARMOR) and it.useSpells and it.useSpells[1]
        local s = useId and spell(useId)
        if s and targetsOf(s) then
            if cls == ITEM_CONSUMABLE and anyIn(s.effects, POTION_EFFECTS) then
                out[#out + 1] = { entry = bag[i].entry, count = bag[i].count or 0, first = bag[i].entry,
                                  ilvl = it.itemLevel or 0 }
            elseif restoresMana(s, NO_AURAS, true) then
                mana[#mana + 1] = { entry = bag[i].entry, count = bag[i].count or 0, first = bag[i].entry,
                                    ilvl = it.itemLevel or 0, gem = it.subclass ~= SUBCLASS_POTION or nil }
            end
        end
    end
    sortBy(out, "ilvl", true)
    sortBy(mana, "ilvl", true)
    return out, mana
end
-- Ascending { {id, cost}, ... } of the ranks of a chain the bot knows (walks wow.spell().next). Without
-- bot:knows (older build) the ranks up to the highest known one count.
local function ranksOf(bot, first, highest)
    local out = {}
    local id, n = first, 0
    local canAsk = bot.knows ~= nil
    while id and id > 0 and n < RANK_WALK_MAX do
        n = n + 1
        local s = spell(id)
        if not s then break end
        local known
        if canAsk then known = bot:knows(id) else known = true end
        if known then out[#out + 1] = { id = id, cost = kit.costPct(bot, id) } end
        if id == highest and not canAsk then break end
        id = s.next
    end
    return out
end
kit.ranksOf = ranksOf

-- ----------------------------------------------------------------------------- per-bot kit

local kits = {}   -- low -> kit

-- Checksum of the known spell ids: a new rank learned at a trainer replaces the superseded one (inactive
-- ranks are not listed), so the count stays the same but the sum changes.
local function idSum(known)
    local sum = 0
    for i = 1, #known do sum = sum + (known[i] or 0) end
    return sum
end

local function build(bot, low, now, known)
    local k = { at = now, level = bot:level() or 0, count = #known, sum = idSum(known), dispelTypes = {} }
    for _, name in ipairs(kit.LISTS) do k[name] = {} end
    local seen = {}
    for i = 1, #known do
        local s = spell(known[i])
        -- passives (talents, auras) never enter a kit list: skip them before any classification
        local first = s and not s.passive and ((s.first and s.first > 0) and s.first or known[i])
        if first and not seen[first] then
            seen[first] = true
            local lists = kit.classify(first)
            if lists and spellbook.isTactical(first) then
                local rank = bot:highestRank(first) or 0
                local rs = rank > 0 and spell(rank)
                if rs then
                    local fs = spell(first)
                    local selfOnly = targetsOf(fs)
                    local e = { first = first, rank = rank, recovery = recoveryOf(rs), cost = kit.costPct(bot, rank),
                                castTime = rs.castTime or 0, duration = rs.duration or 0,
                                range = (rs.maxRangeFriend and rs.maxRangeFriend > 0) and rs.maxRangeFriend
                                    or rs.maxRange or 0,
                                selfOnly = selfOnly, stun = (not has(fs.effects, EFF_INTERRUPT))
                                    and (not has(fs.auras, AURA_SILENCE)) and has(fs.auras, AURA_STUN) or nil }
                    for _, name in ipairs(lists) do
                        local entry = e
                        if name == "healDirect" then e.ranks = ranksOf(bot, first, rank) end
                        if name == "dispelFriend" or name == "dispelFoe" then
                            entry = setmetatable({ types = dispelTypes(first, fs) }, { __index = e })
                            if name == "dispelFriend" then
                                for t in pairs(entry.types) do k.dispelTypes[t] = true end
                            end
                        end
                        local list = k[name]
                        list[#list + 1] = entry
                    end
                end
            end
        end
    end
    sortBy(k.interrupt, "recovery")
    sortBy(k.defensive, "recovery")
    sortBy(k.burst, "recovery", true)
    sortBy(k.burstMedium, "recovery", true)
    sortBy(k.healDirect, "cost")
    k.potion, k.manaPotion = potions(bot)
    kits[low] = k
    return k
end

-- The bot's kit (cached; re-checked at most every AI_KIT_TTL_MS).
function kit.get(bot, low, now)
    local k = kits[low]
    if k then
        local dt = now - k.at
        if dt >= 0 and dt < config.AI_KIT_TTL_MS then return k end
        local known = bot:spells() or {}
        if k.level == (bot:level() or 0) and k.count == #known and k.sum == idSum(known) then
            k.at = now
            k.potion, k.manaPotion = potions(bot)
            return k
        end
        return build(bot, low, now, known)
    end
    return build(bot, low, now, bot:spells() or {})
end

function kit.forget(low)
    kits[low] = nil
end

return kit
