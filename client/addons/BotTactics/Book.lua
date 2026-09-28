-- Tab "Book" (party-window spec 6.7): the bot's known spells by skill line; per spell a one-shot
-- order ("cast now on X") and the class-AI usage rule (as the AI decides / only on X / never).

local BT = BotTactics
local L, W, K = BT.L, BT.W, BT.TabKit
local S = BT.S

L.book_tab = S("Spellbook", "Книга")
L.book_never = S("never use", "не использовать")
L.book_only = S("only: %s", "только: %s")
L.book_orderTitle = S("Cast now", "Приказ сейчас")
L.book_orderApply = S("Apply", "Применить")
L.book_orderNote = S("One cast with top priority, but never over dungeon mechanics.",
    "Одно применение с наивысшим приоритетом, но не поверх механик подземелий.")
L.book_me = S("%s (you)", "%s (вы)")
L.book_yourTarget = S("Your target", "Ваша цель")
L.book_tankTarget = S("Tank's target", "Цель танка")
L.book_noTarget = S("No such target right now", "Такой цели сейчас нет")
L.book_noTank = S("No tank in the group", "В группе нет танка")
L.book_orderSent = S("Order sent...", "Приказ отдан...")
L.book_done = S("Done", "Выполнено")
L.book_expired = S("Too late (expired after 12 s)", "Не успел (истекло 12 с)")
L.book_failed = S("Failed: %s", "Не вышло: %s")
L.book_useTitle = S("How to use in combat", "Как использовать в бою")
L.book_modeAi = S("As the class AI decides", "Как решит классовый ИИ")
L.book_modeOnly = S("Only on:", "Только на:")
L.book_modeNever = S("Never use", "Никогда не использовать")
L.book_addRule = S("+ Tactics rule with this spell", "+ Правило с этим заклинанием")
L.book_instant = S("instant", "мгновенно")
L.book_cast = S("%.1f s cast", "%.1f сек.")
L.book_cost = S("%d %s", "%d %s")
L.book_empty = S("No known spells yet.", "Известных заклинаний пока нет.")
L.book_vetoSaved = S("Usage rule saved", "Правило использования сохранено")
L.book_noRuleSlot = S("Open the tactics tab to add the rule", "Откройте вкладку «Тактика», чтобы добавить правило")

local POWER_NAMES = {
    [0] = S("mana", "маны"), [1] = S("rage", "ярости"), [2] = S("focus", "концентрации"),
    [3] = S("energy", "энергии"), [6] = S("runic power", "силы рун"),
}

local B = {}
BT.Book = B

BT.vetos = BT.vetos or {}      -- low -> { list = { {spell, mode, target} }, byName = { [name] = entry } }
local vetos = BT.vetos
local toasts = {}              -- low -> { text, color }
local selected = {}            -- low -> spell id
local orderTarget = {}         -- low -> option key
B.selected, B.toasts = selected, toasts

local CARD_W = 320
local SPELL_H, SPELL_GAP = 34, 4
local CAT_H = 22

-- ---------------------------------------------------------------- data

local function ParseVetos(f)
    local low = tonumber(f[2])
    if not low then
        return
    end
    local v = { list = {}, byName = {} }
    for _, e in ipairs(BT.List(f[3])) do
        local s = BT.Split(e, ",")
        local spell = tonumber(s[1])
        if spell and (s[2] == "never" or s[2] == "only") then
            local entry = { spell = spell, mode = s[2], target = s[3] ~= "" and s[3] or nil }
            v.list[#v.list + 1] = entry
            local name = GetSpellInfo(spell)
            if name then
                v.byName[name] = entry
            end
        end
    end
    vetos[low] = v
    return low
end

local function VetoOf(low, id)
    local v = vetos[low]
    local name = id and GetSpellInfo(id)
    return v and name and v.byName[name]
end
B.VetoOf = VetoOf

local function TargetLabel(id, low)
    local t = BT.cat.targetById[id]
    return t and BT.Show(BT.TargetLabel(t, low)) or tostring(id)
end

-- Known spells grouped by the BOOK skill-line tabs, each group sorted by learn level.
local function Groups(book)
    local out = {}
    local byCat = {}
    for _, c in ipairs(book.cats) do
        local g = { id = c.id, label = c.label, spells = {} }
        out[#out + 1] = g
        byCat[c.id] = g
    end
    for _, s in ipairs(book.spells) do
        if s.known then
            local g = byCat[s.skill]
            if not g then
                g = { id = s.skill, label = "?", spells = {} }
                out[#out + 1] = g
                byCat[s.skill] = g
            end
            g.spells[#g.spells + 1] = s
        end
    end
    for _, g in ipairs(out) do
        table.sort(g.spells, function(a, b)
            if a.level ~= b.level then
                return a.level < b.level
            end
            return a.id < b.id
        end)
    end
    return out
end

-- ---------------------------------------------------------------- order targets

-- Tank unit: a bot of the party with role "tank", else a member flagged as tank by the LFG role.
local function TankUnit()
    for _, b in ipairs(BT.party or {}) do
        if b.role == "tank" then
            local u = K.Unit(b.low)
            if u then
                return u
            end
        end
    end
    if UnitGroupRolesAssigned then
        for i = 1, 4 do
            local u = "party" .. i
            if UnitExists(u) and UnitGroupRolesAssigned(u) then
                return u
            end
        end
    end
    return nil
end

-- { key, label, unit } options: me, group members, my target, tank's target
local function OrderOptions()
    local opts = { { key = "player", label = string.format(L.book_me, UnitName("player") or "?"), unit = "player" } }
    local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raid > 0 then
        for i = 1, raid do
            local u = "raid" .. i
            if UnitExists(u) and not UnitIsUnit(u, "player") then
                opts[#opts + 1] = { key = u, label = UnitName(u) or u, unit = u }
            end
        end
    else
        for i = 1, 4 do
            local u = "party" .. i
            if UnitExists(u) then
                opts[#opts + 1] = { key = u, label = UnitName(u) or u, unit = u }
            end
        end
    end
    opts[#opts + 1] = { key = "target", label = L.book_yourTarget, unit = "target" }
    opts[#opts + 1] = { key = "tanktarget", label = L.book_tankTarget }
    return opts
end

local function OptionByKey(key)
    for _, o in ipairs(OrderOptions()) do
        if o.key == key then
            return o
        end
    end
    return nil
end

-- ---------------------------------------------------------------- pane

local pane
local ui = { cats = {}, spells = {} }
B.ui = ui

local function Render() B.Render() end

local function Request(low)
    if BT.Protocol.Book then
        BT.Protocol.Book(low)
    else
        K.Send("BOOK", low)
    end
    K.Send("VETOS", low)
end

pane = K.Tab("book", L.book_tab, Request, Render)
B.pane = pane

-- left: spell list
local listScroll, listChild = K.Scroll(pane, "BotTacticsBookScroll", 400)
ui.listScroll, ui.listChild = listScroll, listChild

ui.empty = W.Text(pane, "GameFontDisable", W.MUTED, "CENTER")
ui.empty:SetPoint("TOPLEFT", 20, -40)

local function SpellEnter(self)
    if self.spell then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink("spell:" .. self.spell.id)
        GameTooltip:Show()
    end
    self:SetBackdropBorderColor(W.GOLD[1], W.GOLD[2], W.GOLD[3])
end

local function SpellLeave(self)
    GameTooltip:Hide()
    local c = self.sel and W.GOLD or W.BORDER_FIELD
    self:SetBackdropBorderColor(c[1], c[2], c[3])
end

local function SpellButton(i)
    local b = ui.spells[i]
    if b then
        return b
    end
    b = CreateFrame("Button", nil, listChild)
    b:SetHeight(SPELL_H)
    W.Panel(b, W.BG_FIELD, W.BORDER_FIELD)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetWidth(SPELL_H - 8)
    b.icon:SetHeight(SPELL_H - 8)
    b.icon:SetPoint("LEFT", 4, 0)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.name = W.Text(b, "GameFontHighlightSmall", W.TEXT)
    b.name:SetPoint("TOPLEFT", SPELL_H, -5)
    b.name:SetPoint("RIGHT", -4, 0)
    b.name:SetHeight(12)
    b.mark = W.Text(b, "GameFontHighlightSmall", W.WARN)
    b.mark:SetPoint("TOPLEFT", SPELL_H, -18)
    b.mark:SetPoint("RIGHT", -4, 0)
    b.mark:SetHeight(11)
    b:SetScript("OnEnter", SpellEnter)
    b:SetScript("OnLeave", SpellLeave)
    b:SetScript("OnClick", function(self)
        local low = K.Current()
        if low and self.spell then
            selected[low] = self.spell.id
            B.Render()
        end
    end)
    ui.spells[i] = b
    return b
end

local function CatHeader(i)
    local fs = ui.cats[i]
    if not fs then
        fs = W.Text(listChild, "GameFontNormal", W.GOLD)
        ui.cats[i] = fs
    end
    fs:Show()
    return fs
end

-- right: card
local card = CreateFrame("Frame", nil, pane)
W.Panel(card, { 0.07, 0.055, 0.04, 0.95 }, { 0.29, 0.23, 0.14 })
card:SetWidth(CARD_W)
ui.card = card

local iconButton = CreateFrame("Button", nil, card)
iconButton:SetWidth(40)
iconButton:SetHeight(40)
iconButton:SetPoint("TOPLEFT", 12, -12)
iconButton.tex = iconButton:CreateTexture(nil, "ARTWORK")
iconButton.tex:SetAllPoints(iconButton)
iconButton:SetScript("OnEnter", function(self)
    if self.spell then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink("spell:" .. self.spell)
        GameTooltip:Show()
    end
end)
iconButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
ui.icon = iconButton

ui.name = W.Text(card, "GameFontNormalLarge", W.GOLD)
ui.name:SetPoint("TOPLEFT", 60, -14)
ui.name:SetPoint("RIGHT", -10, 0)
ui.name:SetHeight(18)
ui.meta = W.Text(card, "GameFontHighlightSmall", W.MUTED)
ui.meta:SetPoint("TOPLEFT", 60, -36)
ui.meta:SetPoint("RIGHT", -10, 0)

local function Caption(text, y)
    local fs = W.Text(card, "GameFontNormalSmall", W.GOLD_DIM)
    fs:SetPoint("TOPLEFT", 12, y)
    fs:SetText(text)
    return fs
end

-- order block
Caption(L.book_orderTitle, -66)
ui.orderPick = W.Pick(card, 180, 22, false, true)
ui.orderPick:SetPoint("TOPLEFT", 12, -82)
ui.orderApply = W.Tab(card, 22)
W.FitTab(ui.orderApply, L.book_orderApply, 90)
W.SetTabSelected(ui.orderApply, true)
ui.orderApply:SetPoint("LEFT", ui.orderPick, "RIGHT", 6, 0)
ui.toast = W.Text(card, "GameFontHighlightSmall", W.TEXT)
ui.toast:SetPoint("TOPLEFT", 12, -110)
ui.toast:SetPoint("RIGHT", -10, 0)
ui.toast:SetHeight(12)
ui.orderNote = W.Text(card, "GameFontDisableSmall", W.FAINT)
ui.orderNote:SetPoint("TOPLEFT", 12, -126)
ui.orderNote:SetPoint("RIGHT", -10, 0)
ui.orderNote:SetHeight(26)
ui.orderNote:SetText(L.book_orderNote)

-- usage block
Caption(L.book_useTitle, -162)
ui.radios = {}
local MODES = { { "ai", L.book_modeAi }, { "only", L.book_modeOnly }, { "never", L.book_modeNever } }
for i, m in ipairs(MODES) do
    local name = "BotTacticsBookUse" .. i
    local r = CreateFrame("CheckButton", name, card, "UIRadioButtonTemplate")
    r:SetPoint("TOPLEFT", 12, -178 - (i - 1) * 24)
    r.mode = m[1]
    local text = _G[name .. "Text"]
    if not text then
        text = W.Text(r, "GameFontHighlightSmall", W.TEXT)
        text:SetPoint("LEFT", r, "RIGHT", 4, 0)
    end
    text:SetText(m[2])
    r.label = text
    r:SetScript("OnClick", function(self)
        B.SetMode(self.mode)
    end)
    ui.radios[i] = r
end
ui.onlyPick = W.Pick(card, 150, 20, false, true)
ui.onlyPick:SetPoint("LEFT", ui.radios[2], "RIGHT", 90, 0)

ui.addRule = W.Tab(card, 22)
W.FitTab(ui.addRule, L.book_addRule, 200, CARD_W - 24)
W.SetTabSelected(ui.addRule, false)
ui.addRule:SetPoint("TOPLEFT", 12, -256)

-- ---------------------------------------------------------------- render

local function SpellMeta(id)
    local _, rank, _, cost, _, powerType, castTime = GetSpellInfo(id)
    local parts = {}
    if rank and rank ~= "" then
        parts[#parts + 1] = rank
    end
    if cost and cost > 0 then
        parts[#parts + 1] = string.format(L.book_cost, cost, POWER_NAMES[powerType or 0] or "")
    end
    if castTime and castTime > 0 then
        parts[#parts + 1] = string.format(L.book_cast, castTime / 1000)
    else
        parts[#parts + 1] = L.book_instant
    end
    return table.concat(parts, L.dot)
end

local function MarkText(low, id)
    local v = VetoOf(low, id)
    if not v then
        return nil
    end
    if v.mode == "never" then
        return L.book_never, W.RED
    end
    return string.format(L.book_only, TargetLabel(v.target, low)), W.WARN
end

local function RenderList(low, book, listW)
    local groups = Groups(book)
    local colW = math.floor((listW - SPELL_GAP) / 2)
    local y, ci, si = 0, 0, 0
    local first
    for _, g in ipairs(groups) do
        if #g.spells > 0 then
            ci = ci + 1
            local h = CatHeader(ci)
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", 2, -y - 4)
            h:SetText(BT.Show(g.label))
            y = y + CAT_H
            for k, s in ipairs(g.spells) do
                si = si + 1
                first = first or s.id
                local b = SpellButton(si)
                b.spell = s
                b:SetWidth(colW)
                b:ClearAllPoints()
                local col = (k - 1) % 2
                b:SetPoint("TOPLEFT", col * (colW + SPELL_GAP), -y)
                local name, _, icon = GetSpellInfo(s.id)
                b.icon:SetTexture(icon or BT.ICON_UNKNOWN)
                BT.OneLine(b.name, name or ("#" .. s.id), colW - SPELL_H - 4)
                local mark, c = MarkText(low, s.id)
                if mark then
                    b.mark:SetText(mark)
                    W.Color(b.mark, c)
                    b.name:ClearAllPoints()
                    b.name:SetPoint("TOPLEFT", SPELL_H, -5)
                    b.name:SetPoint("RIGHT", -4, 0)
                else
                    b.mark:SetText("")
                    b.name:ClearAllPoints()
                    b.name:SetPoint("LEFT", SPELL_H, 0)
                    b.name:SetPoint("RIGHT", -4, 0)
                end
                b.sel = selected[low] == s.id
                local bc = b.sel and W.GOLD or W.BORDER_FIELD
                b:SetBackdropBorderColor(bc[1], bc[2], bc[3])
                b:Show()
                if col == 1 or k == #g.spells then
                    y = y + SPELL_H + SPELL_GAP
                end
            end
            y = y + 4
        end
    end
    for i = ci + 1, #ui.cats do
        ui.cats[i]:Hide()
    end
    for i = si + 1, #ui.spells do
        ui.spells[i]:Hide()
    end
    listChild:SetHeight(math.max(10, y))
    return first
end

-- the selected spell is kept by name across rank changes (the book sends the highest known rank)
local function SelectedSpell(low, book)
    local id = selected[low]
    if not id then
        return nil
    end
    for _, s in ipairs(book.spells) do
        if s.known and s.id == id then
            return id
        end
    end
    local name = GetSpellInfo(id)
    local known = name and book.knownByName and book.knownByName[name]
    if known then
        selected[low] = known
    end
    return known
end

local function RenderCard(low, id)
    local name, _, icon = GetSpellInfo(id)
    ui.icon.spell = id
    ui.icon.tex:SetTexture(icon or BT.ICON_UNKNOWN)
    BT.OneLine(ui.name, name or ("#" .. id), CARD_W - 70)
    ui.meta:SetText(SpellMeta(id))

    local key = orderTarget[low] or "player"
    local opt = OptionByKey(key)
    if not opt then
        key, opt = "player", OptionByKey("player")
        orderTarget[low] = key
    end
    ui.orderPick.text:SetText(opt and opt.label or "?")

    local t = toasts[low]
    if t then
        ui.toast:SetText(t.text)
        W.Color(ui.toast, t.color)
    else
        ui.toast:SetText("")
    end

    local v = VetoOf(low, id)
    local mode = v and v.mode or "ai"
    for _, r in ipairs(ui.radios) do
        r:SetChecked(r.mode == mode)
    end
    local target = (v and v.target) or ui.onlyDefault or "tank"
    ui.onlyPick.target = target
    ui.onlyPick.text:SetText(TargetLabel(target, low))
    K.Enable(ui.addRule, BT.Editor ~= nil and BT.Editor.AddRuleWithAction ~= nil)
end

function B.Layout()
    local w, h = K.PaneSize(pane)
    local listW = w - CARD_W - 12 - 26
    listScroll:ClearAllPoints()
    listScroll:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, 0)
    listScroll:SetWidth(listW)
    listScroll:SetHeight(h)
    listChild:SetWidth(listW)
    card:ClearAllPoints()
    card:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, 0)
    card:SetHeight(math.min(h, 292))
    return listW
end

function B.Render()
    local listW = B.Layout()
    local low = K.Current()
    local book = low and BT.books[low]
    if not book then
        ui.empty:SetText(low and L.bookLoading or "")
        ui.empty:Show()
        listScroll:Hide()
        card:Hide()
        return
    end
    local first = RenderList(low, book, listW)
    if not first then
        ui.empty:SetText(L.book_empty)
        ui.empty:Show()
        listScroll:Hide()
        card:Hide()
        return
    end
    ui.empty:Hide()
    listScroll:Show()
    local id = SelectedSpell(low, book)
    if not id then
        selected[low] = first
        id = first
        RenderList(low, book, listW)
    end
    card:Show()
    RenderCard(low, id)
end

-- ---------------------------------------------------------------- actions

local function Toast(low, text, color)
    toasts[low] = { text = text, color = color }
    if pane:IsVisible() and K.Current() == low then
        ui.toast:SetText(text)
        W.Color(ui.toast, color)
    end
end

function B.Order()
    local low = K.Current()
    local id = low and selected[low]
    if not id then
        return
    end
    local opt = OptionByKey(orderTarget[low] or "player")
    local unit = opt and opt.unit
    if opt and opt.key == "tanktarget" then
        local tank = TankUnit()
        if not tank then
            Toast(low, L.book_noTank, W.RED)
            return
        end
        unit = tank .. "target"
    end
    local guid = unit and UnitExists(unit) and K.GuidHex(unit)
    if not guid then
        Toast(low, L.book_noTarget, W.RED)
        return
    end
    K.Send("ORDER", low, id, guid)
    Toast(low, L.book_orderSent, W.MUTED)
end

function B.SetMode(mode, target)
    local low = K.Current()
    local id = low and selected[low]
    if not id then
        return
    end
    if mode == "only" then
        target = target or ui.onlyPick.target or "tank"
    else
        target = ""
    end
    local cur = VetoOf(low, id)
    if (cur and cur.mode or "ai") == mode and (mode ~= "only" or cur.target == target) then
        B.Render()
        return
    end
    K.Send("VETO", low, id, mode, target)
    -- optimistic: the VETOS reply replaces it
    local v = vetos[low] or { list = {}, byName = {} }
    vetos[low] = v
    local name = GetSpellInfo(id)
    if name then
        if mode == "ai" then
            v.byName[name] = nil
        else
            v.byName[name] = { spell = id, mode = mode, target = target }
        end
    end
    B.Render()
end

ui.orderApply:SetScript("OnClick", function() B.Order() end)

ui.orderPick:SetScript("OnClick", function(self)
    local low = K.Current()
    if not low then
        return
    end
    local items = {}
    for _, o in ipairs(OrderOptions()) do
        local key = o.key
        items[#items + 1] = {
            text = o.label, checked = (orderTarget[low] or "player") == key,
            func = function()
                orderTarget[low] = key
                CloseDropDownMenus()
                B.Render()
            end,
        }
    end
    K.Menu(self, items)
end)

ui.onlyPick:SetScript("OnClick", function(self)
    local low = K.Current()
    if not low then
        return
    end
    local items = {}
    for _, side in ipairs({ "own", "foe" }) do
        items[#items + 1] = { text = side == "own" and L.groupOwn or L.groupFoe, isTitle = true, notCheckable = true }
        for _, t in ipairs(BT.cat.targets) do
            if t.side == side then
                local id = t.id
                local b = K.Bot(low)
                local locked = BT.IsLocked(t, b and b.level)
                items[#items + 1] = {
                    text = BT.Show(BT.TargetLabel(t, low)), checked = self.target == id, disabled = locked,
                    func = function()
                        ui.onlyDefault = id
                        CloseDropDownMenus()
                        B.SetMode("only", id)
                    end,
                }
            end
        end
    end
    K.Menu(self, items)
end)

ui.addRule:SetScript("OnClick", function()
    local low = K.Current()
    local id = low and selected[low]
    if not id or not (BT.Editor and BT.Editor.AddRuleWithAction) then
        return
    end
    if not K.ShowTab("tactics") then
        K.Status(low, L.book_noRuleSlot, "err")
        return
    end
    BT.Editor.AddRuleWithAction("spell", id)
end)

-- ---------------------------------------------------------------- messages

local function Visible(low)
    return pane:IsVisible() and low and low == K.Current()
end

K.Hook("BOOK", function(f)
    local low = tonumber(f[2])
    -- names resolve only now for spells the client had not cached at VETOS time
    if low and vetos[low] then
        for _, e in ipairs(vetos[low].list) do
            local name = GetSpellInfo(e.spell)
            if name then
                vetos[low].byName[name] = e
            end
        end
    end
    if Visible(low) then
        B.Render()
    end
end)

K.Hook("VETOS", function(f)
    local low = ParseVetos(f)
    if Visible(low) then
        B.Render()
    end
end)

K.Hook("ORDER", function(f)
    local low, status, reason = tonumber(f[2]), f[4], BT.Unesc(f[5])
    if not low then
        return
    end
    if status == "done" then
        Toast(low, L.book_done, W.OWN)
    elseif status == "expired" then
        Toast(low, L.book_expired, W.WARN)
    else
        Toast(low, string.format(L.book_failed, BT.Show(reason ~= "" and reason or (status or "?"))), W.RED)
    end
end)

K.Hook("ACK", function(f)
    local low, op, ok, _, text = K.Ack(f)
    if not low then
        return
    end
    if op == "ORDER" then
        if not ok then
            Toast(low, BT.Show(text), W.RED)
        end
    elseif op == "VETO" then
        if ok then
            K.Status(low, L.book_vetoSaved, "ok")
        else
            if not K.sharedAck then
                K.Status(low, text, "err")
            end
            K.Send("VETOS", low)     -- undo the optimistic mark
        end
    end
end)
