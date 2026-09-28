-- Bot tactics: rule text format, presets in the store, validation and progression checks.
--
-- Rule list text (identical on the wire and in the DB, spec 4.3):
--   rules = "" | rule (";" rule)* ;  rule = kv ("," kv)* ;  kv = key "=" value ;  value = [A-Za-z0-9_.-]*
--   keys: on (1/0), t (target id), c1/v1, c2/v2 (condition id / value), a (spell|item|special id), x (id)
-- Unknown keys are ignored. Store keys: enabled ("1"/"0"), active ("1".."5"), p1..p5 ("<nameEsc>\t<co>\t<nc>"),
-- all per (bot, leader): "l<leaderLow>_<key>" (store.lua).

local util = wow.include("util.lua")
local config = wow.include("config.lua")
local catalog = wow.include("catalog.lua")
local actions = wow.include("actions.lua")
local store = wow.include("store.lua")
local basics = wow.include("basics.lua")

local rules = {}

local MAX_CONDITIONS = 2
local VALUE_PATTERN = "^[A-Za-z0-9_.%-]*$"

-- ----------------------------------------------------------------------------- parse / serialize

-- Parse one rule text into { on, t, c = { {id, raw}, ... }, a, x, raw = {key = value} }.
local function parseRule(text)
    local kv = {}
    for _, pair in ipairs(util.split(text, ",")) do
        local k, v = pair:match("^([%w_]+)=(.*)$")
        if k then kv[k] = v end
    end
    local r = { raw = kv, c = {} }
    r.on = kv.on ~= "0"
    r.t = kv.t
    r.a = kv.a
    r.xraw = kv.x
    r.x = util.toid(kv.x)
    for i = 1, MAX_CONDITIONS do
        local id = kv["c" .. i]
        if id and id ~= "" then
            r.c[#r.c + 1] = { id = id, raw = kv["v" .. i], n = i }
        end
    end
    return r
end

-- Parse a rule list text. Empty entries (";;") are skipped.
function rules.parseList(text)
    local out = {}
    if not text or text == "" then return out end
    for _, part in ipairs(util.split(text, ";")) do
        if part ~= "" then out[#out + 1] = parseRule(part) end
    end
    return out
end

-- Parse a condition value according to the condition's param kind. Returns value or nil, ok.
function rules.parseValue(cond, raw)
    local p = cond.param
    if p == "none" then return nil, true end
    if p == "num" then
        local n = util.toint(raw)
        if not n or n < cond.min or n > cond.max then return nil, false end
        return n, true
    end
    if p == "spell" or p == "spellid" then
        local id = util.toid(raw)
        if not id then return nil, false end
        return id, true
    end
    if p == "dispel" then
        local d = catalog.dispelById[raw or ""]
        if not d then return nil, false end
        return d.type, true
    end
    if p == "enum" then
        local opts = catalog.enumById[cond.enum or ""]
        local o = opts and opts[raw or ""]
        if not o then return nil, false end
        return o.value, true
    end
    return nil, false
end

-- Canonical text of one rule (validated rule table).
local function serializeRule(r)
    local parts = { "on=" .. (r.on and "1" or "0"), "t=" .. r.t }
    for i = 1, #r.c do
        local c = r.c[i]
        parts[#parts + 1] = "c" .. i .. "=" .. c.id
        if c.raw ~= nil and c.raw ~= "" and catalog.conditionById[c.id].param ~= "none" then
            parts[#parts + 1] = "v" .. i .. "=" .. c.raw
        end
    end
    parts[#parts + 1] = "a=" .. r.a
    if r.x then parts[#parts + 1] = "x=" .. r.x end
    return table.concat(parts, ",")
end

function rules.serializeList(list)
    local t = {}
    for i = 1, #list do t[i] = serializeRule(list[i]) end
    return table.concat(t, ";")
end

-- ----------------------------------------------------------------------------- level gates

function rules.targetUnlocked(id, level)
    local t = catalog.targetById[id]
    return t ~= nil and level >= (t.lvl or 0)
end

function rules.conditionUnlocked(id, level)
    local c = catalog.conditionById[id]
    return c ~= nil and level >= (c.lvl or 0)
end

-- ----------------------------------------------------------------------------- compile (evaluate side)

-- Prepare a parsed rule for the interpreter: resolve catalogue entries and values.
-- Sets r.usable = false when anything is unknown/malformed (the rule is then skipped, never an error).
-- Level gates are checked per tick by the interpreter (the level can change).
function rules.compile(r)
    r.usable = false
    local tgt = catalog.targetById[r.t or ""]
    if not tgt then return r end
    r.side = tgt.side
    if #r.c == 0 then return r end
    for i = 1, #r.c do
        local c = r.c[i]
        local def = catalog.conditionById[c.id]
        if not def then return r end
        local value, ok = rules.parseValue(def, c.raw)
        if not ok then return r end
        c.value = value
        c.def = def
    end
    if actions.X_KINDS[r.a or ""] then   -- spell, item, cancel, petspell (abilities-mirroring-spec 2.4)
        if not r.x then return r end
    elseif not catalog.specialById[r.a or ""] then
        return r
    end
    if not actions.sideAllowed(r.a, r.side, catalog) then return r end
    r.usable = true
    return r
end

-- ----------------------------------------------------------------------------- validation (PUT side)

local ATTR0_NO_AURA_CANCEL = 0x80000000

-- Spell info (wow.spell) of an aura the bot can never remove itself (C++ DoCancel answers cannot_cancel):
-- negative, or SPELL_ATTR0_NO_AURA_CANCEL. Fields missing (older server): false.
function rules.cannotCancel(s)
    if type(s) ~= "table" then return false end
    if s.positive == false then return true end
    local a0 = type(s.attr) == "table" and tonumber(s.attr[1]) or nil
    return a0 ~= nil and math.floor(a0 / ATTR0_NO_AURA_CANCEL) % 2 == 1
end

-- Validate and normalize one list for a bot level. `bot` (optional) also checks that a=petspell names a
-- spell of the bot's current pet (without it: any non-passive spell; the builder skips unknown ones).
-- Returns list (normalized rule tables) or nil, code, arg (arg formats the ACK text).
function rules.validateList(text, level, bot)
    local list = rules.parseList(text)
    if #list > config.slots(level) then return nil, "too_many_rules" end
    for i = 1, #list do
        local r = list[i]
        local kv = r.raw
        if (kv.on ~= nil and kv.on ~= "0" and kv.on ~= "1") then return nil, "bad_value", i end
        for _, v in pairs(kv) do
            if not v:match(VALUE_PATTERN) then return nil, "bad_value", i end
        end
        -- target
        local tgt = catalog.targetById[r.t or ""]
        if not tgt then return nil, "unknown_id", r.t or "" end
        if level < (tgt.lvl or 0) then return nil, "locked_target", r.t end
        -- conditions
        if #r.c == 0 or r.c[1].n ~= 1 then return nil, "bad_value", i end
        if #r.c >= 2 and level < config.COND2_LEVEL then return nil, "cond2_locked", config.COND2_LEVEL end
        for j = 1, #r.c do
            local c = r.c[j]
            local def = catalog.conditionById[c.id]
            if not def then return nil, "unknown_id", c.id end
            if level < (def.lvl or 0) then return nil, "locked_condition", c.id end
            local value, ok = rules.parseValue(def, c.raw)
            if not ok then return nil, "bad_value", i end
            if def.param == "spell" or def.param == "spellid" then
                local s = wow.spell(value)
                if not s then return nil, "unknown_spell", i end
                c.raw = tostring(s.first and s.first > 0 and s.first or value)
            elseif def.param == "num" then
                c.raw = tostring(value)
            elseif def.param == "none" then
                c.raw = nil
            end
        end
        -- action
        if r.a == "spell" then
            local s = r.x and wow.spell(r.x)
            if not s or s.passive then return nil, "unknown_spell", i end
            r.x = (s.first and s.first > 0) and s.first or r.x
        elseif r.a == "item" then
            local it = r.x and wow.item(r.x)
            if not it or it.class ~= 0 then return nil, "bad_item", i end
        elseif r.a == "cancel" or r.a == "petspell" then   -- x = spell, first rank (abilities-mirroring-spec 2.4)
            local s = r.x and wow.spell(r.x)
            if not s or s.passive then return nil, "unknown_spell", i end
            r.x = (s.first and s.first > 0) and s.first or r.x
            -- cancel: the same test as C++ DoCancel (positive, no SPELL_ATTR0_NO_AURA_CANCEL), else a dead slot
            if r.a == "cancel" and rules.cannotCancel(s) then return nil, "cannot_cancel", i end
            -- petspell: checked against the current pet only when the bot has one (a dismissed / dead pet
            -- or another demon must not block saving; the builder skips spells the pet does not know)
            if r.a == "petspell" and bot and basics.pet(bot) and not basics.petRank(bot, r.x) then
                return nil, "unknown_spell", i
            end
        elseif catalog.specialById[r.a or ""] then
            r.x = nil
        else
            return nil, "unknown_id", r.a or ""
        end
        if not actions.sideAllowed(r.a, tgt.side, catalog) then return nil, "bad_value", i end
        r.t = tgt.id
    end
    return list
end

-- Preset name: decoded text, 1..PRESET_NAME_MAX UTF-8 characters, no control characters.
function rules.validName(name)
    if not name or name == "" then return false end
    if name:find("[%z\1-\31\127]") then return false end
    if name:match("^%s*$") then return false end
    return util.utf8len(name) <= config.PRESET_NAME_MAX and #name <= 4 * config.PRESET_NAME_MAX
end

-- ----------------------------------------------------------------------------- presets in the store

-- All stored presets of a bot as `leader` sees them (store.view: the leader's own keys, tactics-round2-spec
-- 4): idx -> { idx, name, nameEsc, co, nc } (texts as stored). `all` = that view (keys without the prefix).
-- Without a leader: the plain (legacy) rows.
function rules.loadPresets(low, leader)
    local all = store.view(low, leader)
    local presets, count = {}, 0
    for idx = 1, config.MAX_PRESETS do
        local data = all["p" .. idx]
        if data then
            local f = util.split(data, "\t")
            presets[idx] = { idx = idx, nameEsc = f[1] or "", name = util.unesc(f[1] or ""),
                             co = f[2] or "", nc = f[3] or "" }
            count = count + 1
        end
    end
    return presets, count, all
end

-- Effective active preset index: stored "active" if that preset exists, else the lowest stored one,
-- else 1 (virtual empty default).
function rules.activeIndex(presets, all)
    local a = util.toint(all and all.active or nil) or 1
    if presets[a] then return a end
    for idx = 1, config.MAX_PRESETS do
        if presets[idx] then return idx end
    end
    return 1
end

function rules.isEnabled(all)
    return not (all and all.enabled == "0")
end

function rules.presetData(nameEsc, co, nc)
    return nameEsc .. "\t" .. co .. "\t" .. nc
end

function rules.defaultName(idx, lang)
    return string.format(util.L(catalog.text.preset_name, lang), idx)
end

return rules
