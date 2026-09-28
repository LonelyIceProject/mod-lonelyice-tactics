-- Helpers: payload escaping (spec 5.2), rule list text (spec 4.3), catalogue, timers, text helpers.

local BT = BotTactics
local L = BT.L

BT.PREFIX = "BTAC"
BT.PROTO = "1"

-- ---------------------------------------------------------------- strings

-- Plain split that keeps empty fields ("a,,b" -> {"a", "", "b"}).
function BT.Split(s, sep)
    local out = {}
    if s == nil then
        return out
    end
    local start = 1
    while true do
        local i = string.find(s, sep, start, true)
        if not i then
            out[#out + 1] = string.sub(s, start)
            return out
        end
        out[#out + 1] = string.sub(s, start, i - 1)
        start = i + #sep
    end
end

-- List field: "" means no entries.
function BT.List(s, sep)
    if s == nil or s == "" then
        return {}
    end
    return BT.Split(s, sep or ";")
end

-- Text fields: every byte of % TAB LF CR ; , = : | becomes %XX.
function BT.Esc(s)
    return (string.gsub(s or "", "[%%\t\n\r;,=:|]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

function BT.Unesc(s)
    return (string.gsub(s or "", "%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

-- Text coming from the server shown in a FontString: no escape sequences, and glyphs the
-- 3.3.5 fonts do not have replaced by ASCII.
function BT.Show(s)
    if s == nil then
        return ""
    end
    s = string.gsub(s, "|", "||")
    s = string.gsub(s, "\226\137\165", ">=")   -- U+2265
    s = string.gsub(s, "\226\137\164", "<=")   -- U+2264
    s = string.gsub(s, "\226\128\166", "...")  -- U+2026
    s = string.gsub(s, "\226\128\148", "-")    -- U+2014
    s = string.gsub(s, "\226\128\147", "-")    -- U+2013
    return s
end

function BT.Trim(s)
    return (string.gsub(s or "", "^%s*(.-)%s*$", "%1"))
end

-- Lower case for search: ASCII + Cyrillic, "ё" folded to "е" (like the preview).
function BT.Norm(s)
    s = string.gsub(s or "", "\208\129", "\208\181")   -- Ё -> е
    s = string.gsub(s, "\209\145", "\208\181")         -- ё -> е
    s = string.gsub(s, "\208([\144-\175])", function(c)
        local b = string.byte(c)
        if b < 160 then
            return "\208" .. string.char(b + 32)       -- А-П -> а-п
        end
        return "\209" .. string.char(b - 32)           -- Р-Я -> р-я
    end)
    return string.lower(s)
end

function BT.Utf8Len(s)
    local _, n = string.gsub(s or "", "[^\128-\191]", "")
    return n
end

-- ---------------------------------------------------------------- one-line labels (party-ui-audit W1/W2)

-- Splits a display string into tokens: escape sequences (|cAARRGGBB, |r, |T...|t, |H...|h, ||) keep
-- their place with zero width, every other token is one UTF-8 character.
local function TextTokens(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = string.sub(s, i, i)
        local j
        if c == "|" then
            local nx = string.sub(s, i + 1, i + 1)
            if nx == "c" then
                j = i + 9
            elseif nx == "T" or nx == "H" then
                local e = string.find(s, (nx == "T") and "|t" or "|h", i + 2, true)
                j = e and (e + 1) or n
            else
                j = i + 1
            end
            out[#out + 1] = { string.sub(s, i, j), nx == "|" }
        else
            local b = string.byte(c)
            local len = (b >= 240 and 4) or (b >= 224 and 3) or (b >= 192 and 2) or 1
            j = i + len - 1
            out[#out + 1] = { string.sub(s, i, j), true }
        end
        i = j + 1
    end
    return out
end

-- Sets a label that must stay on one line: no word wrap where the client has SetWordWrap (the client
-- then ends it with "..."), else the text is cut to `width` with "..." (3.3.5 has no SetWordWrap; a
-- FontString of one line height would wrap and show only the first words). Colour escapes survive the
-- cut. Returns true when the text was shortened (callers put the full text into a tooltip).
function BT.OneLine(fs, text, width)
    text = text or ""
    if fs.SetNonSpaceWrap then
        fs:SetNonSpaceWrap(true)
    end
    fs:SetText(text)
    width = width or 0
    if width <= 0 or fs:GetStringWidth() <= width then
        return false
    end
    if fs.SetWordWrap and fs.CanWordWrap then
        fs:SetWordWrap(false)
        return true
    end
    local toks = TextTokens(text)
    local open = false
    local last = #toks
    for _ = 1, 200 do
        -- drop the last visible character
        while last > 0 and not toks[last][2] do
            last = last - 1
        end
        if last <= 0 then
            break
        end
        last = last - 1
        local parts, colour = {}, false
        for k = 1, last do
            local t = toks[k][1]
            parts[#parts + 1] = t
            if string.sub(t, 1, 2) == "|c" then
                colour = true
            elseif t == "|r" then
                colour = false
            end
        end
        open = colour
        local s = BT.Trim(table.concat(parts)) .. "..." .. (open and "|r" or "")
        fs:SetText(s)
        if fs:GetStringWidth() <= width then
            break
        end
    end
    return true
end

-- Rule values travel unescaped; keep them inside [A-Za-z0-9_.-].
function BT.CleanValue(v)
    if v == nil then
        return nil
    end
    return (string.gsub(tostring(v), "[^%w_%.%-]", ""))
end

-- ---------------------------------------------------------------- rules (spec 4.3)

local KNOWN_KEYS = { on = true, t = true, c1 = true, v1 = true, c2 = true, v2 = true, a = true, x = true }

-- rule = { on = bool, t = id, c = { {id=, v=}, {id=, v=}? }, a = id or nil, x = number or nil,
--          extra = { {k, v}, ... } (unknown keys, kept for forward compatibility) }
function BT.ParseRules(text)
    local rules = {}
    for _, rs in ipairs(BT.List(text, ";")) do
        if rs ~= "" then
            local kv, extra = {}, {}
            for _, pair in ipairs(BT.Split(rs, ",")) do
                local k, v = string.match(pair, "^([^=]+)=(.*)$")
                if k then
                    if KNOWN_KEYS[k] then
                        kv[k] = v
                    else
                        extra[#extra + 1] = { k, v }
                    end
                end
            end
            local r = { on = kv.on ~= "0", t = kv.t or "self", c = {}, extra = extra }
            if kv.c1 and kv.c1 ~= "" then
                r.c[1] = { id = kv.c1, v = kv.v1 }
            else
                r.c[1] = { id = "any" }
            end
            if kv.c2 and kv.c2 ~= "" then
                r.c[2] = { id = kv.c2, v = kv.v2 }
            end
            if kv.a and kv.a ~= "" then
                r.a = kv.a
            end
            r.x = tonumber(kv.x)
            rules[#rules + 1] = r
        end
    end
    return rules
end

function BT.SerializeRules(rules)
    local out = {}
    for _, r in ipairs(rules or {}) do
        local p = { "on=" .. (r.on and "1" or "0"), "t=" .. BT.CleanValue(r.t) }
        for i = 1, 2 do
            local c = r.c[i]
            if c and c.id then
                p[#p + 1] = "c" .. i .. "=" .. BT.CleanValue(c.id)
                local def = BT.cat.condById[c.id]
                local param = def and def.param
                if param ~= "none" and c.v ~= nil and c.v ~= "" then
                    p[#p + 1] = "v" .. i .. "=" .. BT.CleanValue(c.v)
                end
            end
        end
        if r.a then
            p[#p + 1] = "a=" .. BT.CleanValue(r.a)
            if (r.a == "spell" or r.a == "item" or r.a == "cancel" or r.a == "petspell") and r.x then
                p[#p + 1] = "x=" .. string.format("%d", r.x)
            end
        end
        for _, e in ipairs(r.extra or {}) do
            p[#p + 1] = BT.CleanValue(e[1]) .. "=" .. BT.CleanValue(e[2])
        end
        out[#out + 1] = table.concat(p, ",")
    end
    return table.concat(out, ";")
end

function BT.CopyRules(rules)
    local out = {}
    for i, r in ipairs(rules or {}) do
        local c = {}
        for j, cc in ipairs(r.c) do
            c[j] = { id = cc.id, v = cc.v }
        end
        out[i] = { on = r.on, t = r.t, c = c, a = r.a, x = r.x, extra = r.extra }
    end
    return out
end

-- ---------------------------------------------------------------- catalogue

local function Index(list)
    local byId = {}
    for _, e in ipairs(list) do
        byId[e.id] = e
    end
    return byId
end

function BT.SetCatalog(cat, fromServer)
    cat.targetById = Index(cat.targets)
    cat.condById = Index(cat.conds)
    cat.specialById = Index(cat.specials)
    cat.itemcatById = Index(cat.itemcats)
    cat.dispelById = Index(cat.dispels)
    -- Generic option lists for "enum" conditions: cat.enums[list] = { {id, label}, ... }
    cat.enums = cat.enums or {}
    cat.enumById = {}
    for list, opts in pairs(cat.enums) do
        cat.enumById[list] = Index(opts)
    end
    cat.fromServer = fromServer
    BT.cat = cat
end

BT.SetCatalog(BT.FALLBACK_CAT, false)

-- Target label for a bot: "self" and "leader" show the actual character names.
function BT.TargetLabel(t, botLow)
    if not t then
        return "?"
    end
    if t.id == "self" then
        local b = botLow and BT.bots[botLow]
        if b and b.name and b.name ~= "" then
            return b.name .. " " .. BT.L.selfSuffix
        end
    elseif t.id == "leader" then
        local me = UnitName("player")
        if me then
            return me .. " " .. BT.L.leaderSuffix
        end
    end
    return t.label
end

-- True when the id is level-gated above the bot's level.
function BT.IsLocked(entry, level)
    return entry ~= nil and (entry.lvl or 0) > (level or 0)
end

-- ---------------------------------------------------------------- classes

BT.CLASS_TOKENS = {
    [1] = "WARRIOR", [2] = "PALADIN", [3] = "HUNTER", [4] = "ROGUE", [5] = "PRIEST",
    [6] = "DEATHKNIGHT", [7] = "SHAMAN", [8] = "MAGE", [9] = "WARLOCK", [11] = "DRUID",
}

function BT.ClassToken(class)
    local n = tonumber(class)
    if n then
        return BT.CLASS_TOKENS[n]
    end
    if class and class ~= "" then
        return string.upper(class)
    end
    return nil
end

function BT.ClassColor(class)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[BT.ClassToken(class) or ""]
    if c then
        return c.r, c.g, c.b
    end
    return 0.93, 0.87, 0.77
end

function BT.ClassName(class)
    local token = BT.ClassToken(class)
    if token and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token] then
        return LOCALIZED_CLASS_NAMES_MALE[token]
    end
    return token or "?"
end

-- ---------------------------------------------------------------- units

-- Low guid of a player unit ("0x0000000000001234" -> 0x1234).
function BT.UnitLow(unit)
    local g = UnitGUID(unit)
    if not g then
        return nil
    end
    return tonumber(string.sub(g, -8), 16)
end

-- Guid of a unit as the protocol writes it: 16 upper-case hex digits (party-window-spec 4).
function BT.GuidHex(unit)
    local g = unit and UnitGUID(unit)
    if not g then
        return nil
    end
    return string.upper(string.sub(g, 3))
end

-- Low guid of a protocol guid field: 16 hex digits or a plain decimal number.
function BT.ParseLow(s)
    if s == nil or s == "" then
        return nil
    end
    if #s == 16 and not string.find(s, "[^%x]") then
        return tonumber(string.sub(s, -8), 16)
    end
    return tonumber(s)
end

-- The guid field to send back for a bot in LOGIN / LOGOUT: exactly what BOTS gave, else 16 hex digits.
function BT.GuidField(low)
    local a = BT.acctByLow and BT.acctByLow[low]
    if a and a.id then
        return a.id
    end
    return string.format("%016X", low or 0)
end

-- Unit token of a player by low guid: player, party1..4, raid1..40.
function BT.UnitByLow(low)
    if not low then
        return nil
    end
    if BT.UnitLow("player") == low then
        return "player"
    end
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) and BT.UnitLow(u) == low then
            return u
        end
    end
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        for i = 1, 40 do
            local u = "raid" .. i
            if UnitExists(u) and BT.UnitLow(u) == low then
                return u
            end
        end
    end
    return nil
end

local NAME_UNITS = { "player", "pet", "target", "focus", "targettarget", "mouseover" }
for i = 1, 4 do
    NAME_UNITS[#NAME_UNITS + 1] = "party" .. i
    NAME_UNITS[#NAME_UNITS + 1] = "partypet" .. i
    NAME_UNITS[#NAME_UNITS + 1] = "party" .. i .. "target"
end

-- Name of the unit with this 16-hex guid among the units the client knows, else "?".
function BT.UnitNameByGuid(hex)
    if not hex or hex == "" or hex == "0" then
        return "?"
    end
    hex = string.upper(hex)
    for _, u in ipairs(NAME_UNITS) do
        if BT.GuidHex(u) == hex then
            return UnitName(u) or "?"
        end
    end
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        for i = 1, 40 do
            for _, u in ipairs({ "raid" .. i, "raid" .. i .. "target" }) do
                if BT.GuidHex(u) == hex then
                    return UnitName(u) or "?"
                end
            end
        end
    end
    return "?"
end

-- ---------------------------------------------------------------- items and money

-- "item:" hyperlink of a BAGS row (party-window-spec 6.4): enchant, 4 gem/socket ids, suffix id,
-- unique id = suffix factor, level.
function BT.ItemLink(row)
    return "item:" .. (row.entry or 0) .. ":" .. (row.ench or 0) .. ":" .. (row.gem1 or 0) .. ":" .. (row.gem2 or 0)
        .. ":" .. (row.gem3 or 0) .. ":0:" .. (row.rprop or 0) .. ":" .. (row.suffix or 0) .. ":"
        .. (row.level or UnitLevel("player") or 80)
end

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t"

-- Copper amount as "12[g] 47[s] 80[c]" with the coin icons.
function BT.Money(copper)
    copper = math.floor(tonumber(copper) or 0)
    if copper < 0 then
        copper = 0
    end
    local g = math.floor(copper / 10000)
    local s = math.floor(copper / 100) % 100
    local c = copper % 100
    local out = {}
    if g > 0 then
        out[#out + 1] = g .. GOLD_ICON
    end
    if g > 0 or s > 0 then
        out[#out + 1] = s .. SILVER_ICON
    end
    out[#out + 1] = c .. COPPER_ICON
    return table.concat(out, " ")
end

-- ---------------------------------------------------------------- confirmations and prompts

-- Yes/No StaticPopup; fn runs on Yes. One dialog definition per key.
function BT.Confirm(key, text, fn)
    local name = "BOTTACTICS_" .. string.upper(key)
    if not StaticPopupDialogs[name] then
        StaticPopupDialogs[name] = {
            text = "%s",
            button1 = YES,
            button2 = NO,
            OnAccept = function(self, data)
                data = data or self.data
                if type(data) == "function" then
                    data()
                end
            end,
            timeout = 0,
            whileDead = 1,
            hideOnEscape = 1,
        }
    end
    local d = StaticPopup_Show(name, text)
    if d then
        d.data = fn
    end
    return d
end

local promptDefault = ""
local function PromptBox(self)
    return self.editBox or _G[self:GetName() .. "EditBox"]
end

-- StaticPopup with an edit box; fn(text) runs on Accept / Enter. BT.promptBox is the visible box
-- (item links shift-clicked while it is open go into it, see the ChatEdit_InsertLink hook below).
function BT.Prompt(key, text, default, fn)
    local name = "BOTTACTICS_PROMPT_" .. string.upper(key)
    if not StaticPopupDialogs[name] then
        StaticPopupDialogs[name] = {
            text = "%s",
            button1 = ACCEPT,
            button2 = CANCEL,
            hasEditBox = 1,
            maxLetters = 255,
            OnShow = function(self)
                local eb = PromptBox(self)
                BT.promptBox = eb
                eb:SetText(promptDefault)
                eb:SetFocus()
                eb:HighlightText()
            end,
            OnHide = function(self)
                if BT.promptBox == PromptBox(self) then
                    BT.promptBox = nil
                end
            end,
            OnAccept = function(self, data)
                data = data or self.data
                if type(data) == "function" then
                    data(PromptBox(self):GetText())
                end
            end,
            EditBoxOnEnterPressed = function(self)
                local parent = self:GetParent()
                if type(parent.data) == "function" then
                    parent.data(self:GetText())
                end
                parent:Hide()
            end,
            EditBoxOnEscapePressed = function(self)
                self:GetParent():Hide()
            end,
            timeout = 0,
            whileDead = 1,
            hideOnEscape = 1,
        }
    end
    promptDefault = default or ""
    local d = StaticPopup_Show(name, text)
    if d then
        d.data = fn
    end
    return d
end

if hooksecurefunc and ChatEdit_InsertLink then
    hooksecurefunc("ChatEdit_InsertLink", function(link)
        local eb = BT.promptBox
        if eb and eb:IsVisible() and link then
            eb:Insert(link)
        end
    end)
end

-- ---------------------------------------------------------------- action display

-- name, icon, extra(right text), kind for a rule's action.
function BT.ActionInfo(bot, r)
    if not r or not r.a then
        return nil
    end
    if r.a == "spell" then
        local name, rank, icon
        if r.x then
            name, rank, icon = GetSpellInfo(r.x)
        end
        return name or ("#" .. tostring(r.x)), icon or BT.ICON_UNKNOWN, nil, "spell"
    elseif (r.a == "petspell" or r.a == "cancel") and r.x then
        -- abilities-mirroring-spec 2.4: pet ability / "remove own aura" show the spell like "spell"
        local name, _, icon = GetSpellInfo(r.x)
        name = name or ("#" .. tostring(r.x))
        if r.a == "cancel" then
            return string.format(BT.L.cancelAction, name), icon or BT.SPECIAL_ICONS.cancel or BT.ICON_UNKNOWN, nil, "spell"
        end
        return string.format(BT.L.petAction, name), icon or BT.ICON_UNKNOWN, nil, "spell"
    elseif r.a == "item" then
        local name, count
        local book = BT.books[bot]
        if book and r.x then
            local it = book.itemByEntry[r.x]
            if it then
                name, count = it.name, it.count
            end
        end
        if not name and r.x then
            name = GetItemInfo(r.x)
        end
        local icon = r.x and GetItemIcon and GetItemIcon(r.x)
        return name or ("item " .. tostring(r.x)), icon or BT.ICON_UNKNOWN, count, "item"
    end
    local sp = BT.cat.specialById[r.a]
    return BT.Show(sp and sp.label or r.a), BT.SPECIAL_ICONS[r.a] or BT.ICON_UNKNOWN, nil, "special"
end

-- ---------------------------------------------------------------- timers

local timers = {}
local timerFrame = CreateFrame("Frame")
timerFrame:Hide()
timerFrame:SetScript("OnUpdate", function(self)
    local now = GetTime()
    local due
    for key, t in pairs(timers) do
        if now >= t.at then
            due = due or {}
            due[#due + 1] = key
        end
    end
    if due then
        for _, key in ipairs(due) do
            local t = timers[key]
            timers[key] = nil
            if t then
                t.fn()
            end
        end
    end
    if next(timers) == nil then
        self:Hide()
    end
end)

-- Runs fn after delay seconds; a new call with the same key replaces the pending one.
function BT.After(key, delay, fn)
    timers[key] = { at = GetTime() + delay, fn = fn }
    timerFrame:Show()
end

function BT.Cancel(key)
    timers[key] = nil
end

function BT.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffd9b665" .. L.title .. ":|r " .. BT.Show(msg))
end
