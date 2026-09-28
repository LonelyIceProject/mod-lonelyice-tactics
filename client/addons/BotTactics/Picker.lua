-- FF12-like action picker: round category tabs (class skill lines, item categories, specials),
-- search across tabs, "?" rows for spells not learned yet, keyboard navigation, native tooltips.

local BT = BotTactics
local L, W, P = BT.L, BT.W, BT.Protocol

local K = {}
BT.Picker = K

local PANEL_W = 340
local NUM_ROWS = 15               -- the panel starts below the party window's orders strip
local ROW_H = 22
local LIST_Y = -152
local LIST_W = PANEL_W - 12 - 30
local BUBBLE_STEP = 33
local BOOK_MAX_AGE = 20

local st = { open = false, entries = {}, offset = 0 }
K.state = st

-- BOOK pseudo-tabs of the server (abilities-mirroring-spec 2.1): 0 "Basic" (Attack, Shoot, Auto Shot, Throw),
-- 1 "Pet" (the pet's spells: picked as a=petspell). The special "cancel" switches the picker to mode "cancel":
-- the aura to remove comes from the bot's current buffs (UnitBuff of its party unit) or from the book.
K.BASIC_TAB = 0
K.PET_TAB = 1
local ICON_CANCEL = "Interface\\Icons\\Spell_Holy_DispelMagic"

local main = BT.Editor.frame
local pk = CreateFrame("Frame", "BotTacticsPicker", main)
pk:SetWidth(PANEL_W)
-- below the orders strip of the party window, so the group orders stay usable
pk:SetPoint("TOPRIGHT", main, "TOPRIGHT", -10, -60)
pk:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -10, 10)
pk:SetFrameLevel(main:GetFrameLevel() + 30)
pk:EnableMouse(true)
W.Panel(pk, { 0.08, 0.06, 0.04, 0.98 }, W.GOLD_DIM)
pk:Hide()

local titleText = W.Text(pk, "GameFontNormal", W.GOLD)
titleText:SetPoint("TOPLEFT", 12, -10)
local subText = W.Text(pk, "GameFontHighlightSmall", W.MUTED)
subText:SetPoint("LEFT", titleText, "RIGHT", 8, 0)
subText:SetPoint("RIGHT", pk, "RIGHT", -30, 0)
subText:SetHeight(12)

local closeButton = CreateFrame("Button", nil, pk, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", 2, 2)
closeButton:SetScript("OnClick", function()
    K.Close()
    BT.Editor.Refresh()
end)

-- ---------------------------------------------------------------- bubbles (round tabs)

local bubbles = {}
local separators = {}

local function Bubble(i)
    local b = bubbles[i]
    if b then
        return b
    end
    b = W.Round(pk, nil)
    b.count = W.Text(b, "NumberFontNormalSmall", nil, "RIGHT")
    b.count:SetPoint("BOTTOMRIGHT", -2, 2)
    b:SetScript("OnClick", function(self)
        K.SetTab(self.tabId)
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(self.label or "", 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    bubbles[i] = b
    return b
end

local function Separator(i)
    local s = separators[i]
    if not s then
        s = pk:CreateTexture(nil, "ARTWORK")
        s:SetTexture(W.LINE[1], W.LINE[2], W.LINE[3], 1)
        s:SetWidth(1)
        s:SetHeight(22)
        separators[i] = s
    end
    return s
end

local tabTitle = W.Text(pk, "GameFontNormal", W.TEXT)
tabTitle:SetPoint("TOPLEFT", 14, -112)
tabTitle:SetPoint("RIGHT", pk, "RIGHT", -100, 0)
tabTitle:SetHeight(14)
local tabCount = W.Text(pk, "GameFontHighlightSmall", W.FAINT, "RIGHT")
tabCount:SetPoint("TOPRIGHT", -14, -113)
tabCount:SetWidth(90)

-- ---------------------------------------------------------------- search

local search = CreateFrame("EditBox", "BotTacticsPickerSearch", pk, "InputBoxTemplate")
search:SetPoint("TOPLEFT", 20, -128)
search:SetWidth(PANEL_W - 40)
search:SetHeight(20)
search:SetAutoFocus(false)
search:SetAltArrowKeyMode(false)
search:SetMaxLetters(40)
local searchHint = W.Text(search, "GameFontDisableSmall", W.FAINT)
searchHint:SetPoint("LEFT", 2, 0)
searchHint:SetText(L.search)

-- ---------------------------------------------------------------- list

local scroll = CreateFrame("ScrollFrame", "BotTacticsPickerScroll", pk, "FauxScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", pk, "TOPLEFT", 12, LIST_Y)
scroll:SetWidth(LIST_W)
scroll:SetHeight(NUM_ROWS * ROW_H)

local rows = {}

local function MaxOffset()
    return math.max(0, #st.entries - NUM_ROWS)
end

local UpdateRows

local function SetOffset(offset)
    offset = math.max(0, math.min(MaxOffset(), offset))
    st.offset = offset
    local bar = _G["BotTacticsPickerScrollScrollBar"]
    if bar then
        bar:SetValue(offset * ROW_H)
    end
    UpdateRows()
end

local function Wheel(_, delta)
    SetOffset(st.offset - delta * 3)
end

local function IsSelectable(e)
    return e and (e.kind == "s" or e.kind == "i" or e.kind == "x" or e.kind == "c") and not e.disabled
end

local function ShowDetail(e)
    if not e then
        K.detailIcon:SetTexture(nil)
        K.detailName:SetText("")
        K.detailNote:SetText(st.mode == "cond" and L.chooseCond or L.chooseHint)
        return
    end
    if e.kind == "u" then
        K.detailIcon:SetTexture(BT.ICON_UNKNOWN)
        K.detailIcon:SetDesaturated(true)
        K.detailName:SetText("?")
    else
        K.detailIcon:SetTexture(e.icon or BT.ICON_UNKNOWN)
        K.detailIcon:SetDesaturated(e.disabled and true or false)
        K.detailName:SetText(e.name)
    end
    K.detailNote:SetText(e.note or "")
end

local function RowTooltip(row, e)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if e.kind == "s" then
        GameTooltip:SetHyperlink("spell:" .. e.id)
    elseif e.kind == "i" then
        GameTooltip:SetHyperlink("item:" .. e.entry)
        GameTooltip:AddLine(e.note, W.MUTED[1], W.MUTED[2], W.MUTED[3])
    elseif e.kind == "c" then
        GameTooltip:SetText(e.name, 1, 1, 1)
        GameTooltip:AddLine(e.note, W.MUTED[1], W.MUTED[2], W.MUTED[3], 1)
    elseif e.kind == "x" then
        GameTooltip:SetText(e.name, 1, 1, 1)
        if e.desc and e.desc ~= "" then
            GameTooltip:AddLine(e.desc, 1, 0.82, 0, 1)
        end
        if e.disabled then
            GameTooltip:AddLine(L.foeOnly, 1, 0.3, 0.3)
        else
            GameTooltip:AddLine(L.specialNote, 0.6, 0.6, 0.6)
        end
    elseif e.kind == "u" then
        GameTooltip:SetText(L.notLearned, 0.6, 0.6, 0.6)
        GameTooltip:AddLine(e.note, 1, 1, 1, 1)
    else
        GameTooltip:Hide()
        return
    end
    GameTooltip:Show()
end

local function CreateRow(i)
    local b = CreateFrame("Button", nil, pk)
    b:SetWidth(LIST_W)
    b:SetHeight(ROW_H)
    b:SetPoint("TOPLEFT", pk, "TOPLEFT", 12, LIST_Y - (i - 1) * ROW_H)
    b:SetFrameLevel(scroll:GetFrameLevel() + 2)
    b.sel = b:CreateTexture(nil, "BACKGROUND")
    b.sel:SetAllPoints()
    b.sel:SetTexture(0.18, 0.14, 0.09, 1)
    b.sel:Hide()
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetWidth(18)
    b.icon:SetHeight(18)
    b.icon:SetPoint("LEFT", 3, 0)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.q = W.Text(b, "GameFontNormal", W.FAINT, "CENTER")
    b.q:SetPoint("CENTER", b.icon, "CENTER", 0, 0)
    b.q:SetText("?")
    b.name = W.Text(b, "GameFontHighlightSmall", W.TEXT)
    b.name:SetPoint("LEFT", 26, 0)
    b.name:SetPoint("RIGHT", -64, 0)
    b.name:SetHeight(12)
    b.right = W.Text(b, "GameFontHighlightSmall", W.MUTED, "RIGHT")
    b.right:SetPoint("RIGHT", -4, 0)
    b.right:SetWidth(60)
    b.header = W.Text(b, "GameFontNormalSmall", W.GOLD_DIM)
    b.header:SetPoint("BOTTOMLEFT", 4, 3)
    b.header:SetPoint("RIGHT", -4, 0)
    b.header:SetHeight(12)

    b:EnableMouseWheel(true)
    b:SetScript("OnMouseWheel", Wheel)
    b:SetScript("OnEnter", function(self)
        local e = self.entry
        if not e then
            return
        end
        if IsSelectable(e) then
            st.hl = self.index
            UpdateRows()
        end
        ShowDetail(e)
        RowTooltip(self, e)
    end)
    b:SetScript("OnLeave", function()
        GameTooltip:Hide()
        ShowDetail(st.entries[st.hl or 0])
    end)
    b:SetScript("OnClick", function(self)
        local e = self.entry
        if IsSelectable(e) then
            K.Apply(e)
        end
    end)
    return b
end

for i = 1, NUM_ROWS do
    rows[i] = CreateRow(i)
end

scroll:SetScript("OnVerticalScroll", function(self, value)
    st.offset = math.max(0, math.min(MaxOffset(), math.floor(value / ROW_H + 0.5)))
    UpdateRows()
end)
scroll:EnableMouseWheel(true)
scroll:SetScript("OnMouseWheel", Wheel)

UpdateRows = function()
    local n = #st.entries
    FauxScrollFrame_Update(scroll, n, NUM_ROWS, ROW_H)
    if st.offset > MaxOffset() then
        st.offset = MaxOffset()
    end
    for i = 1, NUM_ROWS do
        local row = rows[i]
        local index = st.offset + i
        local e = st.entries[index]
        row.entry = e
        row.index = index
        if not e then
            row:Hide()
        else
            row:Show()
            row.sel:Hide()
            row.q:Hide()
            row.header:Hide()
            row.icon:Show()
            row.icon:SetDesaturated(false)
            row.name:Show()
            row.right:Show()
            W.Color(row.name, W.TEXT)
            W.Color(row.right, W.MUTED)
            if e.kind == "h" then
                row.icon:Hide()
                row.name:Hide()
                row.right:Hide()
                row.header:SetText(e.name)
                row.header:Show()
                row:EnableMouse(false)
            elseif e.kind == "e" then
                row.icon:Hide()
                row.name:SetText(e.name)
                W.Color(row.name, W.FAINT)
                row.right:SetText("")
                row:EnableMouse(false)
            else
                row:EnableMouse(true)
                if e.kind == "u" then
                    row.icon:SetTexture(0.08, 0.065, 0.05, 1)
                    row.q:Show()
                    row.name:SetText("?")
                    W.Color(row.name, W.FAINT)
                    W.Color(row.right, W.FAINT)
                else
                    row.icon:SetTexture(e.icon or BT.ICON_UNKNOWN)
                    row.name:SetText(e.name)
                    if e.disabled then
                        row.icon:SetDesaturated(true)
                        W.Color(row.name, W.FAINT)
                    elseif e.current then
                        W.Color(row.name, W.GOLD)
                    end
                end
                row.right:SetText(e.right or "")
                if index == st.hl then
                    row.sel:Show()
                end
            end
        end
    end
end

-- ---------------------------------------------------------------- detail + key hint

K.detailIcon = pk:CreateTexture(nil, "ARTWORK")
K.detailIcon:SetWidth(36)
K.detailIcon:SetHeight(36)
K.detailIcon:SetPoint("TOPLEFT", 14, LIST_Y - NUM_ROWS * ROW_H - 8)
K.detailIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
K.detailName = W.Text(pk, "GameFontNormal", W.TEXT)
K.detailName:SetPoint("TOPLEFT", K.detailIcon, "TOPRIGHT", 8, -2)
K.detailName:SetPoint("RIGHT", pk, "RIGHT", -12, 0)
K.detailName:SetHeight(14)
K.detailNote = W.Text(pk, "GameFontHighlightSmall", W.MUTED)
K.detailNote:SetPoint("TOPLEFT", K.detailName, "BOTTOMLEFT", 0, -3)
K.detailNote:SetPoint("RIGHT", pk, "RIGHT", -12, 0)
K.detailNote:SetHeight(24)

local keysText = W.Text(pk, "GameFontDisableSmall", W.FAINT)
keysText:SetPoint("BOTTOMLEFT", 12, 10)
keysText:SetPoint("RIGHT", pk, "RIGHT", -12, 0)
keysText:SetHeight(22)
keysText:SetText(L.keys)

-- ---------------------------------------------------------------- data

local function Rule()
    local rules = BT.Editor.CurrentRules()
    return rules and rules[st.k]
end

local function RuleSide(r)
    local t = r and BT.cat.targetById[r.t]
    return t and t.side
end

-- The value the rule currently holds: { kind, name/entry/id }.
local function CurrentValue(r)
    if not r then
        return nil
    end
    if st.mode == "aura" then
        local c = r.c[st.ci or 1]
        local id = c and tonumber(c.v)
        return id and { kind = "s", name = GetSpellInfo(id) }
    end
    if st.mode == "cancel" then
        return r.a == "cancel" and r.x and { kind = "s", name = GetSpellInfo(r.x) } or nil
    end
    if st.mode == "cond" then
        local c = r.c[st.ci or 1]
        return c and { kind = "c", id = c.id } or nil
    end
    if (r.a == "spell" or r.a == "petspell") and r.x then
        return { kind = "s", name = GetSpellInfo(r.x) }
    elseif r.a == "item" and r.x then
        return { kind = "i", entry = r.x }
    elseif r.a then
        return { kind = "x", id = r.a }
    end
    return nil
end

local function IsCurrent(e, cur)
    if not cur or cur.kind ~= e.kind then
        return false
    end
    if e.kind == "s" then
        return cur.name ~= nil and cur.name == e.name
    elseif e.kind == "i" then
        return cur.entry == e.entry
    end
    return cur.id == e.id
end

local function Matches(name, q)
    return q == "" or string.find(BT.Norm(name), q, 1, true) ~= nil
end

local function CatLabel(book, skill)
    for _, c in ipairs(book.cats) do
        if c.id == skill then
            return BT.Show(c.label)
        end
    end
    return ""
end

local function SpellEntries(book, skill, q)
    local list = {}
    for _, s in ipairs(book.spells) do
        if s.skill == skill then
            if s.known then
                local name, rank, icon = GetSpellInfo(s.id)
                name = name or ("#" .. s.id)
                if Matches(name, q) then
                    local note = CatLabel(book, skill)
                    if rank and rank ~= "" then
                        note = note .. " - " .. rank
                    end
                    list[#list + 1] = {
                        kind = "s", id = s.id, name = name, icon = icon, right = rank or "",
                        level = s.level, late = false, note = note,
                        pet = (skill == K.PET_TAB) or nil,   -- a rule casts it as a=petspell
                    }
                end
            elseif q == "" then
                local right, note
                if s.talent then
                    right, note = L.talent, L.unkTalent
                else
                    right, note = string.format(L.lvlShort, s.level), string.format(L.unkTrainer, s.level)
                end
                list[#list + 1] = { kind = "u", id = s.id, name = "", right = right, note = note, level = s.level, late = s.talent }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.late ~= b.late then
            return b.late
        end
        if a.level ~= b.level then
            return a.level < b.level
        end
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.id < b.id
    end)
    return list
end

local function ItemEntries(book, cat, q)
    local list = {}
    for _, it in ipairs(book.items) do
        if it.cat == cat then
            local name = BT.Show(it.name)
            if name == "" then
                name = GetItemInfo(it.entry) or ("item " .. it.entry)
            end
            if Matches(name, q) then
                list[#list + 1] = {
                    kind = "i", entry = it.entry, name = name,
                    icon = GetItemIcon and GetItemIcon(it.entry) or nil,
                    right = string.format(L.itemCount, it.count), note = string.format(L.inBags, it.count),
                }
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local function SpecialEntries(q, side)
    local list = {}
    for _, sp in ipairs(BT.cat.specials) do
        local name = BT.Show(sp.label)
        if Matches(name, q) then
            list[#list + 1] = {
                kind = "x", id = sp.id, name = name, desc = BT.Show(sp.desc),
                icon = BT.SPECIAL_ICONS[sp.id] or BT.ICON_UNKNOWN, right = "",
                note = BT.Show(sp.desc ~= "" and sp.desc or L.specialNote),
                disabled = sp.side == "foe" and side ~= "foe",
            }
        end
    end
    return list
end

-- The bot's current buffs (mode "cancel"): its party / raid unit, one row per aura name.
local function BotAuraEntries(q)
    local list = {}
    local low = BT.Editor.ui.bot
    local unit = low and BT.Party and BT.Party.Unit and BT.Party.Unit(low)
    if not unit or not UnitBuff then
        return list
    end
    local seen = {}
    for i = 1, 40 do
        local name, rank, icon, _, _, _, _, _, _, _, spellId = UnitBuff(unit, i)
        if not name then
            break
        end
        if spellId and not seen[name] and Matches(name, q) then
            seen[name] = true
            list[#list + 1] = { kind = "s", id = spellId, name = name, icon = icon, right = rank or "", note = L.botAuras }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- Mode "cond": condition groups (tabs). Catalogue ids not listed here land in "other".
local COND_GROUPS = {
    { id = "unit", label = L.cgUnit, icon = "Interface\\Icons\\Spell_Holy_FlashHeal",
      ids = { "any", "hp_lt", "hp_ge", "lowest", "mp_lt", "dead", "dist_gt", "moving", "in_melee", "attacking" } },
    { id = "who", label = L.cgWho, icon = "Interface\\Icons\\INV_Misc_Head_Human_01",
      ids = { "class_is", "caster", "ctype_is" } },
    { id = "aura", label = L.cgAura, icon = "Interface\\Icons\\Spell_Holy_DispelMagic",
      ids = { "no_aura", "has_aura", "no_aura_mine", "dispel", "me_aura", "me_no_aura" } },
    { id = "cast", label = L.cgCast, icon = "Interface\\Icons\\Ability_Kick",
      ids = { "casting", "casting_any", "casting_spell" } },
    { id = "me", label = L.cgMe, icon = "Interface\\Icons\\Ability_Warrior_DefensiveStance",
      ids = { "my_hp_lt", "my_mp_lt", "power_ge", "power_lt", "cd_ready", "stance_is", "autoshooting" } },
    { id = "party", label = L.cgParty, icon = "Interface\\Icons\\Spell_Holy_PrayerOfHealing",
      ids = { "healer_mp_lt", "tank_hp_lt", "near_ge", "foes_ge", "combat_gt" } },
    { id = "pet", label = L.cgPet, icon = "Interface\\Icons\\Ability_Hunter_BeastCall",
      ids = { "has_pet", "pet_hp_lt" } },
}
local condGroupOf = {}
for _, g in ipairs(COND_GROUPS) do
    for _, id in ipairs(g.ids) do
        condGroupOf[id] = g
    end
end
local COND_OTHER = { id = "other", label = L.cgOther, icon = BT.ICON_UNKNOWN }

-- Non-empty groups in the order above, "other" last; conditions keep the catalogue order.
local function CondGroups()
    local lists, out = {}, {}
    for _, def in ipairs(BT.cat.conds) do
        local g = condGroupOf[def.id] or COND_OTHER
        lists[g] = lists[g] or {}
        table.insert(lists[g], def)
    end
    for _, g in ipairs(COND_GROUPS) do
        if lists[g] then
            out[#out + 1] = { g = g, defs = lists[g] }
        end
    end
    if lists[COND_OTHER] then
        out[#out + 1] = { g = COND_OTHER, defs = lists[COND_OTHER] }
    end
    return out
end

local function CondEntries(g, defs, q)
    local list = {}
    local b = BT.bots[BT.Editor.ui.bot]
    local level = b and b.level or 1
    for _, def in ipairs(defs) do
        local name = BT.Show(def.label)
        if Matches(name, q) then
            local locked = BT.IsLocked(def, level)
            list[#list + 1] = {
                kind = "c", id = def.id, name = name, icon = g.icon, disabled = locked,
                right = locked and string.format(L.lvlShort, def.lvl) or "",
                note = locked and string.format(L.fromLvl, def.lvl) or g.label,
            }
        end
    end
    return list
end

local function KnownCount(book, skill)
    local n = 0
    for _, s in ipairs(book.spells) do
        if s.skill == skill and s.known then
            n = n + 1
        end
    end
    return n
end

local function CatIcon(book, skill)
    local best, bestLevel
    for _, s in ipairs(book.spells) do
        if s.skill == skill and s.known and (not bestLevel or s.level < bestLevel) then
            local _, _, icon = GetSpellInfo(s.id)
            if icon then
                best, bestLevel = icon, s.level
            end
        end
    end
    return best
end

local function Tabs(book)
    if st.mode == "cond" then
        local tabs = { { id = "all", label = L.allConds, icon = BT.ICON_ALL, count = #BT.cat.conds } }
        for _, cg in ipairs(CondGroups()) do
            tabs[#tabs + 1] = { id = "g" .. cg.g.id, label = cg.g.label, icon = cg.g.icon, count = #cg.defs }
        end
        return tabs
    end
    local tabs = { { id = "all", label = L.allAbilities, icon = BT.ICON_ALL } }
    if st.mode == "cancel" then
        tabs[#tabs + 1] = { id = "auras", label = L.botAuras, icon = ICON_CANCEL, count = #BotAuraEntries("") }
    end
    if book then
        for _, c in ipairs(book.cats) do
            tabs[#tabs + 1] = { id = "c" .. c.id, label = BT.Show(c.label), icon = CatIcon(book, c.id), count = KnownCount(book, c.id) }
        end
    end
    if st.mode == "action" then
        tabs[#tabs + 1] = { sep = true }
        for _, ic in ipairs(BT.cat.itemcats) do
            local n = 0
            if book then
                for _, it in ipairs(book.items) do
                    if it.cat == ic.id then
                        n = n + 1
                    end
                end
            end
            tabs[#tabs + 1] = { id = "i" .. ic.id, label = BT.Show(ic.label), icon = BT.ITEMCAT_ICONS[ic.id] or BT.ICON_UNKNOWN, count = n }
        end
        tabs[#tabs + 1] = { sep = true }
        tabs[#tabs + 1] = { id = "special", label = L.specials, icon = BT.ICON_SPECIALS, count = #BT.cat.specials }
    end
    return tabs
end

local function BuildEntries(book, r)
    local q = BT.Norm(BT.Trim(st.q))
    local allTabs = st.tab == "all" or q ~= ""
    local out = {}
    local function Group(name, list, emptyText, showEmpty)
        if #list == 0 and not showEmpty then
            return
        end
        out[#out + 1] = { kind = "h", name = name }
        for _, e in ipairs(list) do
            out[#out + 1] = e
        end
        if #list == 0 then
            out[#out + 1] = { kind = "e", name = emptyText }
        end
    end

    if st.mode == "cond" then
        for _, cg in ipairs(CondGroups()) do
            if allTabs or st.tab == "g" .. cg.g.id then
                Group(cg.g.label, CondEntries(cg.g, cg.defs, q), L.nothing, not allTabs)
            end
        end
    elseif st.mode == "cancel" and (allTabs or st.tab == "auras") then
        Group(L.botAuras, BotAuraEntries(q), L.nothing, not allTabs)
    end
    if st.mode == "cond" then
        -- no book needed
    elseif not book then
        out[#out + 1] = { kind = "e", name = L.bookLoading }
    else
        for _, c in ipairs(book.cats) do
            if allTabs or st.tab == "c" .. c.id then
                Group(BT.Show(c.label), SpellEntries(book, c.id, q), L.nothing, not allTabs)
            end
        end
    end
    if st.mode == "action" then
        for _, ic in ipairs(BT.cat.itemcats) do
            if allTabs or st.tab == "i" .. ic.id then
                local list = book and ItemEntries(book, ic.id, q) or {}
                Group(BT.Show(ic.label), list, (q ~= "") and L.nothing or L.emptyBags, not allTabs)
            end
        end
        if allTabs or st.tab == "special" then
            Group(L.specials, SpecialEntries(q, RuleSide(r)), L.nothing, not allTabs)
        end
    end
    if #out == 0 then
        out[#out + 1] = { kind = "e", name = L.nothing }
    end

    local cur = CurrentValue(r)
    local selectable = 0
    for _, e in ipairs(out) do
        if IsSelectable(e) then
            selectable = selectable + 1
        end
        if e.kind ~= "h" and e.kind ~= "e" and e.kind ~= "u" then
            e.current = IsCurrent(e, cur)
        end
    end
    return out, selectable, allTabs, q
end

local function InitialTab(book, r)
    local cur = CurrentValue(r)
    if not cur then
        return "all"
    end
    if cur.kind == "s" and book and cur.name then
        for _, s in ipairs(book.spells) do
            if s.known and GetSpellInfo(s.id) == cur.name then
                return "c" .. s.skill
            end
        end
    elseif cur.kind == "i" and book then
        local it = book.itemByEntry[cur.entry]
        if it then
            return "i" .. it.cat
        end
    elseif cur.kind == "x" and st.mode == "action" then
        return "special"
    end
    return "all"
end

-- ---------------------------------------------------------------- render

local function RenderBubbles(tabs, allTabs)
    local x, y = 12, -32
    local nb, ns = 0, 0
    for _, t in ipairs(tabs) do
        if t.sep then
            ns = ns + 1
            local s = Separator(ns)
            s:ClearAllPoints()
            s:SetPoint("TOPLEFT", pk, "TOPLEFT", x + 2, y - 5)
            s:Show()
            x = x + 6
        else
            if x + 31 > PANEL_W - 8 then
                x = 12
                y = y - BUBBLE_STEP - 2
            end
            nb = nb + 1
            local b = Bubble(nb)
            b.tabId = t.id
            b.label = t.label
            W.SetRoundIcon(b, t.icon or BT.ICON_UNKNOWN)
            local sel = (not allTabs or st.tab == "all") and st.tab == t.id and BT.Trim(st.q) == ""
            b.icon:SetDesaturated(not sel)
            if sel then
                b.border:SetVertexColor(1, 0.85, 0.35)
            else
                b.border:SetVertexColor(0.55, 0.5, 0.45)
            end
            if t.count then
                b.count:SetText(t.count)
            else
                b.count:SetText("")
            end
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", pk, "TOPLEFT", x, y)
            b:Show()
            x = x + BUBBLE_STEP
        end
    end
    for i = nb + 1, #bubbles do
        bubbles[i]:Hide()
    end
    for i = ns + 1, #separators do
        separators[i]:Hide()
    end
end

local function EnsureVisible()
    if not st.hl then
        return
    end
    if st.hl <= st.offset then
        SetOffset(st.hl - 2)
    elseif st.hl > st.offset + NUM_ROWS then
        SetOffset(st.hl - NUM_ROWS)
    end
end

local function Build(keepHl)
    local bot = BT.Editor.ui.bot
    local r = Rule()
    if not bot or not r then
        K.Close()
        return
    end
    local book = BT.books[bot]
    local b = BT.bots[bot]
    if st.mode == "aura" then
        titleText:SetText(L.pickAura)
    elseif st.mode == "cond" then
        titleText:SetText(L.pickCond)
    elseif st.mode == "cancel" then
        titleText:SetText(L.pickCancel)
    else
        titleText:SetText(L.pickAction)
    end
    subText:SetText(string.format(L.pickSub, st.k, BT.Show(b and b.name or "")))

    local tabs = Tabs(book)
    local valid = false
    for _, t in ipairs(tabs) do
        if t.id == st.tab then
            valid = true
        end
    end
    if not valid then
        st.tab = "all"
    end

    local entries, selectable, allTabs, q = BuildEntries(book, r)
    st.entries = entries
    RenderBubbles(tabs, allTabs)

    if q ~= "" then
        tabTitle:SetText(L.searchTitle)
        tabCount:SetText(string.format(L.found, selectable))
    else
        for _, t in ipairs(tabs) do
            if t.id == st.tab then
                tabTitle:SetText(t.label)
            end
        end
        tabCount:SetText(string.format(L.available, selectable))
    end

    if not keepHl or not IsSelectable(entries[st.hl or 0]) then
        st.hl = nil
        for i, e in ipairs(entries) do
            if e.current and IsSelectable(e) then
                st.hl = i
                break
            end
        end
        if not st.hl then
            for i, e in ipairs(entries) do
                if IsSelectable(e) then
                    st.hl = i
                    break
                end
            end
        end
        if not keepHl then
            st.offset = 0
        end
    end
    UpdateRows()
    EnsureVisible()
    ShowDetail(entries[st.hl or 0])
end

local function Move(dir)
    local n = #st.entries
    local i = st.hl or 0
    repeat
        i = i + dir
    until i < 1 or i > n or IsSelectable(st.entries[i])
    if i >= 1 and i <= n then
        st.hl = i
        UpdateRows()
        EnsureVisible()
        ShowDetail(st.entries[i])
    end
end

function K.StepTab(dir)
    local tabs = Tabs(BT.books[BT.Editor.ui.bot])
    local ids = {}
    local cur = 1
    for _, t in ipairs(tabs) do
        if not t.sep then
            ids[#ids + 1] = t.id
            if t.id == st.tab then
                cur = #ids
            end
        end
    end
    local nextIndex = ((cur - 1 + dir) % #ids) + 1
    K.SetTab(ids[nextIndex])
end

function K.SetTab(id)
    st.tab = id
    st.q = ""
    search:SetText("")
    Build(false)
    search:SetFocus()
end

-- ---------------------------------------------------------------- search box scripts

search:SetScript("OnTextChanged", function(self)
    local text = self:GetText()
    if text == "" then
        searchHint:Show()
    else
        searchHint:Hide()
    end
    if text ~= st.q then
        st.q = text
        Build(false)
    end
end)
-- 3.3.5 edit boxes have no OnArrowPressed; OnKeyDown still sees the arrow keys
local function OnArrow(_, key)
    if key == "UP" then
        Move(-1)
    elseif key == "DOWN" then
        Move(1)
    end
end
if search:HasScript("OnArrowPressed") then
    search:SetScript("OnArrowPressed", OnArrow)
elseif search:HasScript("OnKeyDown") then
    search:SetScript("OnKeyDown", OnArrow)
end
search:SetScript("OnTabPressed", function()
    K.StepTab(IsShiftKeyDown() and -1 or 1)
end)
search:SetScript("OnEnterPressed", function()
    local e = st.entries[st.hl or 0]
    if IsSelectable(e) then
        K.Apply(e)
    end
end)
search:SetScript("OnEscapePressed", function()
    K.Close()
    BT.Editor.Refresh()
end)
search:SetScript("OnEditFocusGained", function(self)
    self:HighlightText(0, 0)
end)

-- ---------------------------------------------------------------- public

function K.IsEditing(k)
    return st.open and st.k == k
end

-- onPick(id): mode "cond" only, called with the chosen condition id (the editor applies it).
function K.Open(k, mode, ci, onPick)
    local bot = BT.Editor.ui.bot
    local rules = BT.Editor.CurrentRules()
    if not bot or not rules or not rules[k] then
        return
    end
    CloseDropDownMenus()
    GameTooltip:Hide()
    st.open = true
    st.k = k
    st.mode = mode
    st.ci = ci
    st.onPick = onPick
    st.q = ""
    st.hl = nil
    st.offset = 0
    local book = BT.books[bot]
    if not book or GetTime() - (book.at or 0) > BOOK_MAX_AGE then
        P.Book(bot)
    end
    st.tab = InitialTab(book, rules[k])
    search:SetText("")
    pk:Show()
    Build(false)
    search:SetFocus()
    BT.Editor.Refresh()
end

function K.Close()
    if not st.open then
        return
    end
    st.open = false
    st.k = nil
    st.onPick = nil
    search:ClearFocus()
    pk:Hide()
    GameTooltip:Hide()
end

-- Called by the editor after data changes.
function K.Refresh()
    if st.open then
        Build(true)
    end
end

function K.Apply(e)
    local r = Rule()
    if not r then
        K.Close()
        return
    end
    if st.mode == "cond" then
        if e.kind ~= "c" then
            return
        end
        local onPick = st.onPick
        K.Close()
        if onPick then
            onPick(e.id)   -- may reopen the picker (aura of the new condition)
        end
        BT.Editor.Refresh()
        return
    elseif st.mode == "aura" then
        local c = r.c[st.ci or 1]
        if c and e.kind == "s" then
            c.v = tostring(e.id)
        end
    elseif st.mode == "cancel" then
        if e.kind ~= "s" then
            return
        end
        r.a, r.x = "cancel", e.id
    elseif e.kind == "x" and e.id == "cancel" then
        -- "Cancel own aura...": pick the aura next (same rule, mode "cancel")
        st.mode = "cancel"
        st.tab = "auras"
        st.q = ""
        search:SetText("")
        Build(false)
        search:SetFocus()
        return
    elseif e.kind == "s" then
        r.a, r.x = e.pet and "petspell" or "spell", e.id
    elseif e.kind == "i" then
        r.a, r.x = "item", e.entry
    elseif e.kind == "x" then
        r.a, r.x = e.id, nil
    end
    K.Close()
    BT.Editor.Touch()
end
