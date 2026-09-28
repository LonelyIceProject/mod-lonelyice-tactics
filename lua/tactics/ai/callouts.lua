-- Bot tactics / AI layer: the party chat callouts of the coordination (tactics-round2-spec 2.7).
-- Names are inserted in the nominative after a colon ("Прерываю: Шаман!") - no Russian declension.
-- callouts.text(id, lang, args) -> sanitized text (no "|", no control bytes, cut at a UTF-8 boundary) | nil

local config = wow.include("config.lua")

local callouts = {}

-- id -> { ru, en }; index = the repeat-guard slot in the AI state (cc<index>)
callouts.LIST = {
    { id = "int_claim", ru = "Прерываю: {target}!",   en = "Interrupting {target}!" },
    { id = "int_fail",  ru = "Не успел прервать!",    en = "Missed the interrupt!" },
    { id = "dsp_claim", ru = "Снимаю {type}: {target}", en = "Dispelling {type} on {target}" },
    { id = "tgt_far",   ru = "Беру дальнего: {target}", en = "Taking the ranged one: {target}" },
    { id = "tgt_claim", ru = "Беру: {target}",        en = "Taking {target}" },
    { id = "help",      ru = "Помогите, бьют меня!",  en = "Help, they are on me!" },
    { id = "heal_ack",  ru = "Лечу: {target}",        en = "Healing {target}" },
    { id = "oom",       ru = "Нет маны!",             en = "Out of mana!" },
    { id = "pot",       ru = "Пью зелье маны",        en = "Mana potion" },
    { id = "innervate", ru = "Озарение: {target}",    en = "Innervate on {target}" },
    { id = "cd_burst",  ru = "Жгу кулдауны",          en = "Popping cooldowns" },
    { id = "drink",     ru = "Пью, секунду",          en = "Drinking, one sec" },
    { id = "runner",    ru = "{target} убегает!",     en = "{target} is running!" },
}
callouts.BY_ID = {}
for i, e in ipairs(callouts.LIST) do
    e.index = i
    callouts.BY_ID[e.id] = e
end

-- Dispel type (SpellInfo Dispel 1..4) -> the word used in "Снимаю {type}: ..." (ru accusative).
callouts.DISPEL = {
    [1] = { ru = "магию",     en = "magic" },
    [2] = { ru = "проклятие", en = "curse" },
    [3] = { ru = "болезнь",   en = "disease" },
    [4] = { ru = "яд",        en = "poison" },
}

-- "ruRU" -> "ru", anything else (nil: the sim owner has no session) -> "en"
function callouts.lang(locale)
    return locale == "ruRU" and "ru" or "en"
end

-- Remove "|" and control bytes; cut to maxBytes without splitting a UTF-8 sequence.
function callouts.clean(text, maxBytes)
    text = tostring(text or ""):gsub("[%c|]", "")
    maxBytes = maxBytes or config.AI_SAY_MAX_BYTES or 120
    if #text <= maxBytes then return text end
    local cut = maxBytes
    -- step back over continuation bytes (10xxxxxx) so the lead byte and its sequence go together
    while cut > 0 and text:byte(cut + 1) and text:byte(cut + 1) >= 0x80 and text:byte(cut + 1) < 0xC0 do
        cut = cut - 1
    end
    return text:sub(1, cut)
end

-- Text of a callout. args.target = a unit name, args.type = a dispel type number (or a ready label).
function callouts.text(id, lang, args, maxBytes)
    local e = callouts.BY_ID[id]
    if not e then return nil end
    local fmt = e[lang] or e.en
    args = args or {}
    local target = callouts.clean(args.target or "?", 48)
    local ty = args.type
    if type(ty) == "number" then
        local d = callouts.DISPEL[ty]
        ty = d and (d[lang] or d.en) or ""
    end
    ty = callouts.clean(ty or "", 32)
    local text = fmt:gsub("{target}", function() return target end):gsub("{type}", function() return ty end)
    text = callouts.clean(text, maxBytes)
    if text == "" then return nil end
    return text
end

return callouts
