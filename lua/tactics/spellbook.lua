-- Bot tactics: spellbook / bag export for the action picker (BOOK message, spec section 6), including
-- the non-tactical spell filter. C++ only exposes raw spell data; every "is this useful in a fight"
-- decision is made here.

local util = wow.include("util.lua")
local catalog = wow.include("catalog.lua")

local spellbook = {}

-- ----------------------------------------------------------------------------- filter tables

spellbook.CLASS_SKILL_CATEGORY = 7

-- Class-category skill lines that are not party tactics.
spellbook.EXCLUDED_SKILL_LINES = util.set({
    633,  -- Lockpicking
    762,  -- Riding
    777,  -- Mounts
    778,  -- Companions
})

-- SPELL_EFFECT_* that mark a non-tactical spell.
spellbook.EXCLUDED_EFFECTS = util.set({
    5,    -- TELEPORT_UNITS (teleports, hearth-like)
    33,   -- OPEN_LOCK
    36,   -- LEARN_SPELL
    39,   -- LANGUAGE
    44,   -- SKILL_STEP
    50,   -- TRANS_DOOR (portals)
    57,   -- LEARN_PET_SPELL
    60,   -- PROFICIENCY
    76,   -- SUMMON_OBJECT_WILD
    104,  -- SUMMON_OBJECT_SLOT1
    105,  -- SUMMON_OBJECT_SLOT2
    106,  -- SUMMON_OBJECT_SLOT3
    107,  -- SUMMON_OBJECT_SLOT4
    118,  -- SKILL
})

-- SPELL_AURA_* that mark a non-tactical spell.
spellbook.EXCLUDED_AURAS = util.set({
    32,   -- MOD_INCREASE_MOUNTED_SPEED
    44,   -- TRACK_CREATURES
    45,   -- TRACK_RESOURCES
    78,   -- MOUNTED
    151,  -- TRACK_STEALTHED
    207,  -- MOD_INCREASE_MOUNTED_FLIGHT_SPEED
})

-- Basic attacks outside the class skill lines (abilities-mirroring-spec 2.1): Attack, Shoot (wand),
-- Auto Shot, Throw, Shoot (bow / gun / crossbow of warriors and rogues). Shown on the pseudo-tab
-- BASIC_TAB "Basic"; the pet's spells (bot:petSpells) on PET_TAB "Pet". Neither tab gets "?" rows.
spellbook.BASIC = { [6603] = "basic", [5019] = "basic", [75] = "basic", [2764] = "basic", [3018] = "basic" }
spellbook.BASIC_TAB = 0
spellbook.PET_TAB = 1

local ATTR0_PASSIVE = 0x40
local ATTR0_DO_NOT_DISPLAY = 0x80
local MAX_LEARN_LEVEL = 80

-- ----------------------------------------------------------------------------- static caches (per state)

local skillCategory = {}   -- skill line id -> category (false when unknown)
local spellInfo = {}       -- spell id -> compact record (false when unknown)

local function isClassSkill(line)
    local cat = skillCategory[line]
    if cat == nil then
        local sl = wow.skillLine(line)
        cat = sl and sl.category or false
        skillCategory[line] = cat
    end
    return cat == spellbook.CLASS_SKILL_CATEGORY and not spellbook.EXCLUDED_SKILL_LINES[line]
end

-- Rules 1, 3 and 4 of the filter (display flags, effects, auras).
local function baseTactical(s)
    if s.passive then return false end
    local a0 = (s.attr and s.attr[1]) or 0
    if util.band(a0, ATTR0_PASSIVE) ~= 0 or util.band(a0, ATTR0_DO_NOT_DISPLAY) ~= 0 then return false end
    for i = 1, 3 do
        local eff = s.effects and s.effects[i]
        if eff and spellbook.EXCLUDED_EFFECTS[eff] then return false end
        local aura = s.auras and s.auras[i]
        if aura and spellbook.EXCLUDED_AURAS[aura] then return false end
    end
    return true
end

-- { base = rules 1,3,4 ok, skill = first qualifying class skill line or nil, first, talent, level }
local function info(id)
    local rec = spellInfo[id]
    if rec ~= nil then return rec or nil end
    local s = wow.spell(id)
    if not s then
        spellInfo[id] = false
        return nil
    end
    rec = {
        base = spellbook.BASIC[id] ~= nil or baseTactical(s),
        first = (s.first and s.first > 0) and s.first or id,
        talent = s.talent and true or false,
        level = (s.spellLevel and s.spellLevel > 0) and s.spellLevel or (s.baseLevel or 0),
    }
    if spellbook.BASIC[id] then
        rec.skill = spellbook.BASIC_TAB
    elseif s.skills then
        for i = 1, #s.skills do
            if isClassSkill(s.skills[i]) then
                rec.skill = s.skills[i]
                break
            end
        end
    end
    spellInfo[id] = rec
    return rec
end

-- Full filter (rules 1-4). Exposed for other scripts.
function spellbook.isTactical(id)
    local rec = info(id)
    return rec ~= nil and rec.base and rec.skill ~= nil
end

-- ----------------------------------------------------------------------------- export

local function itemCategory(item)
    return catalog.itemSubclassCat[item.subclass] or "misc"
end

-- Build the BOOK payload for a bot. locale = "ruRU"/"enGB"/... (nil = server default).
function spellbook.build(bot, locale)
    local botLow = bot:lowGuid()
    local class, race = bot:class() or 0, bot:race() or 0

    -- Known spells, one row per chain (highest known rank).
    local rows, chains, perSkill = {}, {}, {}
    local known = bot:spells() or {}
    for i = 1, #known do
        local rec = info(known[i])
        if rec and rec.base and rec.skill and not chains[rec.first] then
            chains[rec.first] = true
            local rank = bot:highestRank(rec.first)
            if not rank or rank == 0 then rank = known[i] end
            local firstRec = info(rec.first) or rec
            rows[#rows + 1] = { id = rank, skill = rec.skill, level = firstRec.level,
                                flags = rec.talent and "kt" or "k" }
            perSkill[rec.skill] = (perSkill[rec.skill] or 0) + 1
        end
    end

    -- Pet spells (pseudo-tab PET_TAB): the pet's castable spells, one row per chain (highest rank).
    local petRows = 0
    local pets = (type(bot.petSpells) == "function" and bot:petSpells()) or {}
    local petChains = {}
    for i = 1, #pets do
        local id = pets[i].id
        local s = id and wow.spell(id)
        if s and not s.passive then
            local first = (s.first and s.first > 0) and s.first or id
            local prev = petChains[first]
            if not prev or id > prev.id then
                local firstSpell = (first ~= id) and wow.spell(first) or s
                local level = (firstSpell and firstSpell.spellLevel and firstSpell.spellLevel > 0) and firstSpell.spellLevel
                    or (firstSpell and firstSpell.baseLevel) or 0
                if not prev then petRows = petRows + 1 end
                petChains[first] = { id = id, skill = spellbook.PET_TAB, level = level, flags = "k" }
            end
        end
    end
    for _, row in pairs(petChains) do rows[#rows + 1] = row end

    -- Tabs: "Basic" first, then class skill lines ordered by number of known spells (desc), then id, then "Pet".
    local tabs = {}
    for line in pairs(perSkill) do
        if line ~= spellbook.BASIC_TAB then tabs[#tabs + 1] = line end
    end
    table.sort(tabs, function(a, b)
        if perSkill[a] ~= perSkill[b] then return perSkill[a] > perSkill[b] end
        return a < b
    end)
    local classTabs = tabs
    tabs = {}
    if perSkill[spellbook.BASIC_TAB] then tabs[1] = spellbook.BASIC_TAB end
    for _, line in ipairs(classTabs) do tabs[#tabs + 1] = line end
    if petRows > 0 then tabs[#tabs + 1] = spellbook.PET_TAB end

    -- "?" rows: not yet learned first ranks of this class/race in the class skill lines.
    local unknown = {}
    for _, line in ipairs(classTabs) do
        local abilities = wow.skillAbilities(line) or {}
        for i = 1, #abilities do
            local a = abilities[i]
            local okClass = (a.classMask or 0) == 0 or (class > 0 and util.hasBit(a.classMask, class - 1))
            local okRace = (a.raceMask or 0) == 0 or (race > 0 and util.hasBit(a.raceMask, race - 1))
            if okClass and okRace and not chains[a.spell] then
                local rec = info(a.spell)
                if rec and rec.base and rec.first == a.spell and rec.level >= 1 and rec.level <= MAX_LEARN_LEVEL then
                    local prev = unknown[a.spell]
                    if (not prev or rec.level < prev.level) and (bot:highestRank(a.spell) or 0) == 0 then
                        unknown[a.spell] = { id = a.spell, skill = line, level = rec.level,
                                             flags = rec.talent and "ut" or "u" }
                    end
                end
            end
        end
    end
    for _, row in pairs(unknown) do rows[#rows + 1] = row end
    table.sort(rows, function(a, b)
        if a.level ~= b.level then return a.level < b.level end
        return a.id < b.id
    end)

    -- Serialize
    local cats = {}
    local lang = util.lang(locale)
    for i, line in ipairs(tabs) do
        local name
        if line == spellbook.BASIC_TAB then
            name = util.L(catalog.text.tab_basic, lang)
        elseif line == spellbook.PET_TAB then
            name = util.L(catalog.text.tab_pet, lang)
        else
            local sl = wow.skillLine(line, locale)
            name = sl and sl.name or tostring(line)
        end
        cats[i] = line .. "," .. util.esc(name)
    end
    local spells = {}
    for i, r in ipairs(rows) do
        spells[i] = r.id .. "," .. r.skill .. "," .. r.level .. "," .. r.flags
    end

    local items = {}
    local bag = bot:items() or {}
    for i = 1, #bag do
        local it = wow.item(bag[i].entry, locale)
        if it and it.class == 0 then
            local cat = itemCategory(it)
            items[#items + 1] = { entry = bag[i].entry, count = bag[i].count or 0, cat = cat,
                                  order = catalog.itemcatById[cat] and catalog.itemcatById[cat].order or 99,
                                  name = it.name or "" }
        end
    end
    table.sort(items, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        if a.name ~= b.name then return a.name < b.name end
        return a.entry < b.entry
    end)
    local itemText = {}
    for i, it in ipairs(items) do
        itemText[i] = it.entry .. "," .. it.count .. "," .. it.cat .. "," .. util.esc(it.name)
    end

    return "BOOK\t" .. botLow .. "\t" .. table.concat(cats, ";") .. "\t" .. table.concat(spells, ";")
        .. "\t" .. table.concat(itemText, ";")
end

return spellbook
