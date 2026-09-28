-- Tab "Тактика" of the party window (party-window-spec 6.3): preset tabs, combat/non-combat switch,
-- rule rows, AI log. The roster, header and main frame live in Party.lua.

local BT = BotTactics
local L, W, P = BT.L, BT.W, BT.Protocol
local Party = BT.Party

local E = {}
BT.Editor = E

local ui = { bot = nil, mode = "co" }
E.ui = ui

local ROW_W = Party.CONTENT_W
local ROW_H, ROW_GAP = 24, 2
local RULES_Y = -46
local MAX_SLOTS = 11
local MAX_PRESET_TABS = 8
local COND_W = 162
local FLASH_TIME = 1.5
local TRACE_ROWS = 24
local TRACE_EVERY = 5
local LOCK_ICON = "Interface\\LFGFrame\\UI-LFG-ICON-LOCK"
local ROW_BORDER = { 0.24, 0.18, 0.11 }
local ICON_OK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t"
local ICON_FAIL = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:12:12|t"

-- The main window (Picker.lua anchors to it).
local frame = Party.frame
E.frame = frame

E.SavePosition = Party.SavePosition
E.RestorePosition = Party.RestorePosition
E.Toggle = Party.Toggle
E.ShowMenu = W.ShowMenu
local ShowMenu = W.ShowMenu

local LockedText

local function OnShow(low)
    E.Show(low)
end

local function OnHide()
    E.Hide()
end

local function OnData(what, bot)
    E.TabData(what, bot)
end

local pane = Party.RegisterTab("tactics", L.tabTactics, OnShow, OnHide, OnData)
E.pane = pane

LockedText = function(text, lvl)
    return text .. " |cff808080" .. string.format(L.fromLvl, lvl) .. "|r"
end

-- ---------------------------------------------------------------- helpers

local function Bot()
    return ui.bot and BT.bots[ui.bot]
end
E.Bot = Bot

function E.CurrentPreset()
    if not ui.bot then
        return nil
    end
    return BT.ActivePreset(ui.bot)
end

function E.CurrentRules()
    local p = E.CurrentPreset()
    return p and p[ui.mode]
end

local function Touch()
    local _, idx = E.CurrentPreset()
    if idx then
        P.Touch(ui.bot, idx)
    end
end
E.Touch = Touch

local function SlotsOf(b)
    return (b and b.slots) or 3
end

local function UnlockOf(b, k)
    local u = b and b.unlock and b.unlock[k]
    if u then
        return u
    end
    if k <= 3 then
        return 0
    end
    return 10 * (k - 3)
end

-- ---------------------------------------------------------------- editor body

local ed = CreateFrame("Frame", nil, pane)
ed:SetAllPoints(pane)

local message = W.Text(pane, "GameFontNormal", W.MUTED, "CENTER")
message:SetPoint("CENTER", pane, "CENTER", 0, 40)
message:SetWidth(460)

local slotsLabel = W.Text(ed, "GameFontHighlightSmall", W.MUTED, "RIGHT")
slotsLabel:SetPoint("TOPRIGHT", -4 - MAX_SLOTS * 21 - 6, -29)
slotsLabel:SetWidth(360)

local pips = {}
for i = 1, MAX_SLOTS do
    local t = ed:CreateTexture(nil, "ARTWORK")
    t:SetWidth(18)
    t:SetHeight(6)
    t:SetPoint("TOPRIGHT", -4 - (MAX_SLOTS - i) * 21, -32)
    pips[i] = t
end

-- preset tabs
local presetTabs = {}
for i = 1, MAX_PRESET_TABS do
    local t = W.Tab(ed, 22)
    t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    t:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            E.PresetMenu(self)
        else
            E.SelectPreset(self.idx)
        end
    end)
    t:SetScript("OnDoubleClick", function(self)
        E.StartRename(self)
    end)
    t.tip = L.presetTip
    presetTabs[i] = t
end

local newPresetTab = W.Tab(ed, 22)
newPresetTab.text:SetText(L.newPreset)
newPresetTab:SetScript("OnClick", function()
    E.NewPreset()
end)

local modeTabs = {}
for i, m in ipairs({ { "nc", L.noncombat }, { "co", L.combat } }) do
    local t = W.Tab(ed, 22)
    W.FitTab(t, m[2], 90, 140)
    t.mode = m[1]
    if i == 1 then
        t:SetPoint("TOPRIGHT", -4, 0)
    else
        t:SetPoint("TOPRIGHT", modeTabs[1], "TOPLEFT", -2, 0)
    end
    t:SetScript("OnClick", function(self)
        E.SetMode(self.mode)
    end)
    modeTabs[m[1]] = t
    modeTabs[i] = t
end

local renameBox = CreateFrame("EditBox", "BotTacticsRenameBox", ed, "InputBoxTemplate")
renameBox:SetAutoFocus(false)
renameBox:SetMaxLetters(24)
renameBox:SetHeight(20)
renameBox:SetFrameLevel(ed:GetFrameLevel() + 10)
renameBox:Hide()

-- rules area
local rulesArea = CreateFrame("Frame", nil, ed)
rulesArea:SetPoint("TOPLEFT", 0, RULES_Y)
rulesArea:SetWidth(ROW_W)
rulesArea:SetHeight((MAX_SLOTS + 2) * (ROW_H + ROW_GAP))

local function FixedRow(text, tag, color)
    local row = CreateFrame("Frame", nil, rulesArea)
    row:SetWidth(ROW_W)
    row:SetHeight(ROW_H)
    W.Panel(row, { 0, 0, 0, 0.3 }, W.LINE)
    row.lock = row:CreateTexture(nil, "ARTWORK")
    row.lock:SetTexture(LOCK_ICON)
    row.lock:SetWidth(14)
    row.lock:SetHeight(14)
    row.lock:SetPoint("LEFT", 10, 0)
    row.text = W.Text(row, "GameFontNormalSmall", color)
    row.text:SetPoint("LEFT", 32, 0)
    row.text:SetText(text)
    row.tag = W.Text(row, "GameFontDisableSmall", W.FAINT, "RIGHT")
    row.tag:SetPoint("RIGHT", -10, 0)
    row.tag:SetText(tag or "")
    return row
end

local mechRow = FixedRow(L.mechRow, L.mechTag, W.WARN)
local classRow = FixedRow(L.classRow, L.classTag, W.TEXT)

local addRow = CreateFrame("Button", nil, rulesArea)
addRow:SetWidth(ROW_W)
addRow:SetHeight(ROW_H)
W.Panel(addRow, { 0, 0, 0, 0 }, { 0.35, 0.29, 0.18 })
addRow.text = W.Text(addRow, "GameFontNormalSmall", W.GOLD, "CENTER")
addRow.text:SetPoint("CENTER")
addRow:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
addRow:SetScript("OnClick", function()
    E.AddRule()
end)

local lockRows = {}
for k = 1, MAX_SLOTS do
    local row = CreateFrame("Frame", nil, rulesArea)
    row:SetWidth(ROW_W)
    row:SetHeight(ROW_H)
    W.Panel(row, { 0.05, 0.04, 0.03, 0.6 }, { 0.17, 0.14, 0.10 })
    row.n = W.Text(row, "GameFontNormal", W.FAINT, "CENTER")
    row.n:SetPoint("LEFT", 4, 0)
    row.n:SetWidth(28)
    row.n:SetText(k)
    row.lock = row:CreateTexture(nil, "ARTWORK")
    row.lock:SetTexture(LOCK_ICON)
    row.lock:SetWidth(14)
    row.lock:SetHeight(14)
    row.lock:SetPoint("LEFT", 36, 0)
    row.lock:SetAlpha(0.6)
    row.text = W.Text(row, "GameFontDisableSmall", W.FAINT)
    row.text:SetPoint("LEFT", 58, 0)
    lockRows[k] = row
end

-- ---------------------------------------------------------------- rule rows

local rows = {}
E.rows = rows

local function ShowActionTip(owner)
    local row = owner.row
    local r = row and row.rule
    if not r or not r.a then
        return
    end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if r.a == "spell" and r.x then
        GameTooltip:SetHyperlink("spell:" .. (BT.KnownRank(ui.bot, r.x) or r.x))
    elseif (r.a == "cancel" or r.a == "petspell") and r.x then
        GameTooltip:SetHyperlink("spell:" .. r.x)
        local sp = BT.cat.specialById[r.a]
        GameTooltip:AddLine(r.a == "cancel" and BT.Show(sp and sp.label or r.a) or L.petSpellNote, 1, 0.82, 0, 1)
    elseif r.a == "item" and r.x then
        GameTooltip:SetHyperlink("item:" .. r.x)
        local book = BT.books[ui.bot]
        local it = book and book.itemByEntry[r.x]
        GameTooltip:AddLine(string.format(L.inBags, it and it.count or 0), W.MUTED[1], W.MUTED[2], W.MUTED[3])
    else
        local sp = BT.cat.specialById[r.a]
        GameTooltip:SetText(BT.Show(sp and sp.label or r.a), 1, 1, 1)
        if sp and sp.desc and sp.desc ~= "" then
            GameTooltip:AddLine(BT.Show(sp.desc), 1, 0.82, 0, 1)
        end
        GameTooltip:AddLine(L.specialNote, 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

local function ShowAuraTip(owner)
    local v = owner.spellId
    if not v then
        return
    end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink("spell:" .. v)
    GameTooltip:Show()
end

local function SimpleTip(owner, text)
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:SetText(text, 1, 1, 1, 1, 1)
    GameTooltip:Show()
end

-- width of the spell id box of a "spellid" condition
local SID_W = 46

local function CreateCond(row, x, ci)
    local c = CreateFrame("Frame", nil, row)
    c:SetWidth(COND_W)
    c:SetHeight(22)
    c:SetPoint("LEFT", x, 0)
    c.ci = ci

    c.pick = W.Pick(c, 100, 22, false, true)
    c.pick:SetPoint("LEFT")
    c.pick:SetScript("OnClick", function(self)
        E.CondMenu(self, row, ci)
    end)

    c.num = W.Number(c, 46)
    c.num.onChange = function(eb)
        E.NumberChanged(row, ci, eb)
    end
    c.num.onCommit = function(eb, cancel)
        E.NumberCommit(row, ci, eb, cancel)
    end

    c.unit = W.Text(c, "GameFontHighlightSmall", W.MUTED)
    c.unit:SetWidth(22)

    -- param "spellid" (tactics-round2-spec 3): id box (typed or pasted / shift-clicked link) + spell name
    c.sid = W.SpellIdBox(c, SID_W)
    c.sid.onChange = function(eb)
        E.SpellIdChanged(row, ci, eb)
    end
    c.sid.onCommit = function(eb, cancel)
        E.SpellIdCommit(row, ci, eb, cancel)
    end
    c.sid.onEnter = function(self)
        if self.spellId then
            ShowAuraTip(self)
        else
            SimpleTip(self, L.condSpellIdTip)
        end
    end
    c.sid:Hide()
    c.sname = W.Text(c, "GameFontHighlightSmall", W.GOLD)
    c.sname:SetHeight(12)
    c.sname:Hide()

    c.param = W.Pick(c, 80, 22, true, false)
    c.param:SetScript("OnClick", function(self)
        E.ParamClick(self, row, ci)
    end)
    c.param.onEnter = function(self)
        if self.spellId then
            ShowAuraTip(self)
        end
    end

    if ci == 2 then
        c.rm = W.CloseSmall(c, L.removeCond, 14)
        c.rm:SetPoint("RIGHT", 0, 0)
        c.rm:SetScript("OnClick", function()
            E.RemoveCond(row)
        end)
    end
    return c
end

-- Column positions (the tab content is 740 px wide).
local X_TARGET, W_TARGET = 60, 114
local X_COND1, X_COND2 = 178, 344
local X_ARROW, X_ACTION, W_ACTION = 508, 524, 150
local X_UP, X_DOWN, X_DEL = 680, 698, 718

local function CreateRuleRow(k)
    local row = CreateFrame("Frame", nil, rulesArea)
    row:SetWidth(ROW_W)
    row:SetHeight(ROW_H)
    W.Panel(row, { 0.16, 0.13, 0.085, 0.95 }, ROW_BORDER)
    row.k = k

    row.grip = CreateFrame("Button", nil, row)
    row.grip:SetWidth(12)
    row.grip:SetHeight(22)
    row.grip:SetPoint("LEFT", 4, 0)
    row.grip.text = W.Text(row.grip, "GameFontNormalSmall", W.FAINT, "CENTER")
    row.grip.text:SetPoint("CENTER")
    row.grip.text:SetText(":")
    row.grip:RegisterForDrag("LeftButton")
    row.grip:SetScript("OnDragStart", function()
        E.StartDrag(row.k)
    end)
    row.grip:SetScript("OnDragStop", function()
        E.StopDrag()
    end)
    row.grip:SetScript("OnEnter", function(self)
        self.text:SetTextColor(W.GOLD[1], W.GOLD[2], W.GOLD[3])
        SimpleTip(self, L.drag)
    end)
    row.grip:SetScript("OnLeave", function(self)
        W.Color(self.text, W.FAINT)
        GameTooltip:Hide()
    end)

    row.idx = W.Text(row, "GameFontNormal", W.GOLD, "CENTER")
    row.idx:SetPoint("LEFT", 16, 0)
    row.idx:SetWidth(20)

    row.toggle = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.toggle:SetWidth(22)
    row.toggle:SetHeight(22)
    row.toggle:SetPoint("LEFT", 36, 0)
    row.toggle:SetScript("OnClick", function(self)
        if row.rule then
            row.rule.on = self:GetChecked() and true or false
            Touch()
        end
    end)
    row.toggle:SetScript("OnEnter", function(self)
        SimpleTip(self, L.toggle)
    end)
    row.toggle:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    row.target = W.Pick(row, W_TARGET, 22, false, true)
    row.target:SetPoint("LEFT", X_TARGET, 0)
    row.target.side = W.Text(row.target, "GameFontNormalSmall")
    row.target.side:SetPoint("LEFT", 5, 0)
    row.target.side:SetWidth(30)
    row.target.side:SetHeight(12)
    row.target.text:ClearAllPoints()
    row.target.text:SetPoint("LEFT", 36, 0)
    row.target.text:SetPoint("RIGHT", -14, 0)
    row.target:SetScript("OnClick", function(self)
        E.TargetMenu(self, row)
    end)

    row.cond = { CreateCond(row, X_COND1, 1), CreateCond(row, X_COND2, 2) }

    row.addCond = W.Tab(row, 20)
    row.addCond:SetPoint("LEFT", X_COND2, 0)
    row.addCond:SetWidth(COND_W)
    row.addCond:SetScript("OnClick", function()
        E.AddCond(row)
    end)
    row.addCond.tip = L.cond2Tip

    row.arrow = row:CreateTexture(nil, "ARTWORK")
    row.arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
    row.arrow:SetWidth(14)
    row.arrow:SetHeight(14)
    row.arrow:SetPoint("LEFT", X_ARROW, 0)

    row.action = W.Pick(row, W_ACTION, 22, true, false)
    row.action:SetPoint("LEFT", X_ACTION, 0)
    row.action.row = row
    row.action.count = W.Text(row.action, "GameFontHighlightSmall", W.GOLD, "RIGHT")
    row.action.count:SetPoint("RIGHT", -4, 0)
    row.action:SetScript("OnClick", function()
        BT.Picker.Open(row.k, "action")
    end)
    row.action.onEnter = ShowActionTip

    row.up = W.UpButton(row, L.up)
    row.up:SetPoint("LEFT", X_UP, 0)
    row.up:SetScript("OnClick", function()
        E.MoveRule(row.k, -1)
    end)
    row.down = W.DownButton(row, L.down)
    row.down:SetPoint("LEFT", X_DOWN, 0)
    row.down:SetScript("OnClick", function()
        E.MoveRule(row.k, 1)
    end)
    row.del = W.CloseSmall(row, L.delete, 16)
    row.del:SetPoint("LEFT", X_DEL, 0)
    row.del:SetScript("OnClick", function()
        E.DeleteRule(row.k)
    end)

    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if self.overSlots then
            SimpleTip(self, L.overSlots)
        end
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    return row
end

for k = 1, MAX_SLOTS do
    rows[k] = CreateRuleRow(k)
end

-- ---------------------------------------------------------------- rendering a rule row

local function LayoutCond(c, def, v, locked)
    local avail = COND_W - (c.rm and 16 or 0)
    local param = def and def.param or "none"
    c.num:Hide()
    c.unit:Hide()
    c.param:Hide()
    c.param.spellId = nil
    c.sid:Hide()
    c.sid.spellId = nil
    c.sname:Hide()
    c.pick:ClearAllPoints()
    c.pick:SetPoint("LEFT")

    local label
    if def then
        if param ~= "none" and def.prefix and def.prefix ~= "" then
            label = def.prefix
        else
            label = def.label
        end
    else
        label = c.condId or "?"
    end
    c.pick.text:SetText(BT.Show(label))    -- cut to the final width at the end (W.SetPickText)
    if locked or not def then
        W.Color(c.pick.text, W.RED)
    else
        W.Color(c.pick.text, W.TEXT)
    end

    if param == "num" then
        local unit = def.unit and BT.Show(def.unit) or ""
        local unitW = (unit ~= "") and 24 or 0
        c.pick:SetWidth(avail - 56 - unitW)
        c.num:ClearAllPoints()
        c.num:SetPoint("LEFT", c.pick, "RIGHT", 6, 0)
        -- Percentages step by 5, counts and seconds by 1
        c.num.min, c.num.max = def.min, def.max
        c.num.step = (unit == "%") and 5 or 1
        if not c.num.focused then
            c.num:SetText(v or def.default or "")
        end
        c.num:Show()
        if unitW > 0 then
            c.unit:ClearAllPoints()
            c.unit:SetPoint("LEFT", c.num.spin, "RIGHT", 3, 0)
            c.unit:SetText(unit)
            c.unit:Show()
        end
    elseif param == "spellid" then
        -- "<prefix> [id] Spell name": the name comes from the client (GetSpellInfo); empty / unknown id = red
        local pw = 56
        c.pick:SetWidth(pw)
        c.sid:ClearAllPoints()
        c.sid:SetPoint("LEFT", c.pick, "RIGHT", 2, 0)
        if not c.sid.focused then
            c.sid:SetText(v or "")
        end
        c.sid:Show()
        local id = tonumber(v)
        local name = id and GetSpellInfo(id)
        c.sname:ClearAllPoints()
        c.sname:SetPoint("LEFT", c.sid, "RIGHT", 3, 0)
        c.sname:SetWidth(math.max(10, avail - pw - 2 - SID_W - 3))
        if name then
            c.sid.spellId = id
            c.sname:SetText(name)
            W.Color(c.sname, W.GOLD)
        else
            c.sname:SetText(id and L.condSpellUnknown or L.condSpellId)
            W.Color(c.sname, W.RED)
        end
        c.sname:Show()
    elseif param == "spell" or param == "dispel" or param == "enum" then
        local pw = (param == "spell") and 56 or 70
        c.pick:SetWidth(pw)
        c.param:ClearAllPoints()
        c.param:SetPoint("LEFT", c.pick, "RIGHT", 2, 0)
        c.param:SetWidth(avail - pw - 2)
        if param == "spell" then
            local id = tonumber(v)
            local name, _, icon
            if id then
                name, _, icon = GetSpellInfo(id)
            end
            c.param.spellId = id
            c.param.icon:Show()
            c.param.icon:SetTexture(icon or BT.ICON_UNKNOWN)
            c.param.text:ClearAllPoints()
            c.param.text:SetPoint("LEFT", 22, 0)
            c.param.text:SetPoint("RIGHT", -4, 0)
            if id then
                W.SetPickText(c.param, name or ("#" .. id), 26)
                W.Color(c.param.text, W.GOLD)
            else
                W.SetPickText(c.param, L.chooseAura, 26)
                W.Color(c.param.text, W.RED)
            end
        else
            local d
            if param == "enum" then
                d = BT.cat.enumById[def.enum or ""]
                d = d and d[v or ""]
            else
                d = BT.cat.dispelById[v or ""]
            end
            c.param.icon:Hide()
            c.param.text:ClearAllPoints()
            c.param.text:SetPoint("LEFT", 6, 0)
            c.param.text:SetPoint("RIGHT", -4, 0)
            W.SetPickText(c.param, BT.Show(d and d.label or (v or "?")), 10)
            W.Color(c.param.text, W.GOLD)
        end
        c.param:Show()
    else
        c.pick:SetWidth(avail)
    end
    W.SetPickText(c.pick, BT.Show(label))
end

local function RowBorder(row)
    if row.editing then
        return W.GOLD
    elseif row.overSlots then
        return W.RED
    end
    return ROW_BORDER
end

local function RenderRule(row, r, k, b)
    local cat = BT.cat
    local level = b.level or 1
    row.rule = r
    row.k = k
    row.idx:SetText(k)
    row.toggle:SetChecked(r.on)
    row.overSlots = k > SlotsOf(b)
    row.editing = BT.Picker.IsEditing(k)
    local bc = RowBorder(row)
    row:SetBackdropBorderColor(bc[1], bc[2], bc[3])
    if r.on then
        row:SetBackdropColor(0.16, 0.13, 0.085, 0.95)
        row.idx:SetAlpha(1)
    else
        row:SetBackdropColor(0.10, 0.085, 0.06, 0.8)
        row.idx:SetAlpha(0.5)
    end

    -- target
    local t = cat.targetById[r.t]
    local side = t and t.side
    if side == "foe" then
        row.target.side:SetText(L.foe)
        W.Color(row.target.side, W.FOE)
    else
        row.target.side:SetText(L.own)
        W.Color(row.target.side, W.OWN)
    end
    W.SetPickText(row.target, BT.Show(t and BT.TargetLabel(t, ui.bot) or r.t), 50)
    if not t or BT.IsLocked(t, level) then
        W.Color(row.target.text, W.RED)
    else
        W.Color(row.target.text, W.TEXT)
    end

    -- conditions
    for ci = 1, 2 do
        local c = r.c[ci]
        local w = row.cond[ci]
        if c then
            local def = cat.condById[c.id]
            w.condId = c.id
            LayoutCond(w, def, c.v, def and BT.IsLocked(def, level))
            w:Show()
        else
            w:Hide()
        end
    end
    if r.c[2] then
        row.addCond:Hide()
    else
        local lvl2 = b.cond2lvl or 60
        if level >= lvl2 then
            row.addCond.text:SetText(L.addCond)
            row.addCond:Enable()
            W.Color(row.addCond.text, W.MUTED)
        else
            row.addCond.text:SetText(string.format(L.addCondLocked, lvl2))
            row.addCond:Disable()
            W.Color(row.addCond.text, W.FAINT)
        end
        row.addCond:Show()
    end

    -- action
    local name, icon, count = BT.ActionInfo(b.low, r)
    local actionPad = 22 + (count and 30 or 4)
    if name then
        row.action.icon:SetTexture(icon)
        W.SetPickText(row.action, name, actionPad)
        W.Color(row.action.text, W.TEXT)
    else
        row.action.icon:SetTexture(BT.ICON_UNKNOWN)
        W.SetPickText(row.action, L.chooseAction, actionPad)
        W.Color(row.action.text, W.RED)
    end
    if count then
        row.action.count:SetText(string.format(L.itemCount, count))
        row.action.text:SetPoint("RIGHT", -30, 0)
    else
        row.action.count:SetText("")
        row.action.text:SetPoint("RIGHT", -4, 0)
    end
    W.SetPickBorder(row.action, row.editing and W.GOLD or nil)

    W.Enable(row.up, k > 1)
    W.Enable(row.down, k < #(E.CurrentRules() or {}))
end

-- ---------------------------------------------------------------- AI log (TRACE)

local traces = {}      -- low -> { list = { {ago, name, ok, target, rel} } newest last, at }
local traceOpen = false

local traceLine = CreateFrame("Button", nil, ed)
traceLine:SetPoint("TOPLEFT", rulesArea, "BOTTOMLEFT", 0, -4)
traceLine:SetWidth(200)
traceLine:SetHeight(18)
traceLine.text = W.Text(traceLine, "GameFontNormalSmall", W.GOLD)
traceLine.text:SetPoint("LEFT", 4, 0)
traceLine:SetScript("OnClick", function()
    E.ToggleTrace()
end)
traceLine:SetScript("OnEnter", function(self)
    SimpleTip(self, L.traceTip)
end)
traceLine:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

local tracePanel = CreateFrame("Frame", nil, ed)
tracePanel:SetAllPoints(rulesArea)
tracePanel:SetFrameLevel(rulesArea:GetFrameLevel() + 20)
tracePanel:EnableMouse(true)
W.Panel(tracePanel, { 0.06, 0.045, 0.03, 0.98 }, W.GOLD_DIM)
tracePanel:Hide()

local traceTitle = W.Text(tracePanel, "GameFontNormal", W.GOLD)
traceTitle:SetPoint("TOPLEFT", 10, -7)
traceTitle:SetText(L.traceTitle)

local traceClose = CreateFrame("Button", nil, tracePanel, "UIPanelCloseButton")
traceClose:SetPoint("TOPRIGHT", 2, 2)
traceClose:SetScript("OnClick", function()
    E.ToggleTrace(false)
end)

local traceRefresh = W.Button(tracePanel, L.traceRefresh, 80, 20)
traceRefresh:SetPoint("TOPRIGHT", -30, -4)
traceRefresh:SetScript("OnClick", function()
    E.RequestTrace()
end)

local traceLines = {}
for i = 1, TRACE_ROWS do
    local fs = W.Text(tracePanel, "GameFontHighlightSmall", W.TEXT)
    fs:SetPoint("TOPLEFT", 12, -26 - (i - 1) * 12.5)
    fs:SetWidth(ROW_W - 24)
    fs:SetHeight(12)
    traceLines[i] = fs
end

local function RenderTraceLine()
    traceLine.text:SetText(L.traceTitle .. (traceOpen and "  <" or "  >"))
end

function E.RenderTrace()
    RenderTraceLine()
    if not traceOpen then
        return
    end
    local tr = ui.bot and traces[ui.bot]
    local list = tr and tr.list or {}
    local since = tr and (GetTime() - tr.at) or 0
    local n = #list
    for i = 1, TRACE_ROWS do
        local fs = traceLines[i]
        local e = list[n - i + 1]       -- newest first
        if e then
            local ago = math.floor(e.ago / 1000 + since + 0.5)
            local name = BT.Show(e.name)
            if e.kind == "ai" then
                name = L.traceAi .. BT.Show(BT.IntentLabel(e.name))
                if e.score then
                    name = name .. " " .. string.format("%.2f", e.score / 100)
                end
            end
            local parts = { string.format(L.traceAgo, ago), name, e.ok and ICON_OK or ICON_FAIL }
            if e.target ~= "" and e.target ~= "0" then
                parts[#parts + 1] = BT.Show(BT.UnitNameByGuid(e.target))
            end
            fs:SetText(table.concat(parts, L.dot))
            if not e.ok then
                W.Color(fs, W.MUTED)
            elseif e.kind == "ai" then
                W.Color(fs, W.AI)
            elseif e.kind == "rule" then
                W.Color(fs, W.GOLD)
            else
                W.Color(fs, W.TEXT)
            end
        elseif i == 1 and n == 0 then
            fs:SetText(tr and L.traceEmpty or L.loading)
            W.Color(fs, W.FAINT)
        else
            fs:SetText("")
        end
    end
end

local TraceTick
TraceTick = function()
    if not traceOpen or not ed:IsVisible() then
        return
    end
    E.RequestTrace()
    BT.After("trace", TRACE_EVERY, TraceTick)
end

function E.RequestTrace()
    if ui.bot and BT.bots[ui.bot] then
        P.Send("TRACE", ui.bot)
    end
end

function E.ToggleTrace(on)
    if on == nil then
        on = not traceOpen
    end
    traceOpen = on
    W.Show(tracePanel, on)
    if on then
        BT.Picker.Close()
        TraceTick()
    else
        BT.Cancel("trace")
    end
    E.RenderTrace()
end

-- TRACE <bot> <entries>: agoMs,nameEsc,ok,target,relevance,kind,score100 (newest last).
-- kind: "" class AI, "rule" a tactics rule ("co#3"), "ai" the AI layer (name = intent id).
P.Handlers.TRACE = function(f)
    local bot = tonumber(f[2])
    if not bot then
        return
    end
    local list = {}
    for _, e in ipairs(BT.List(f[3])) do
        local s = BT.Split(e, ",")
        list[#list + 1] = {
            ago = tonumber(s[1]) or 0, name = BT.Unesc(s[2]), ok = s[3] == "1",
            target = s[4] or "", rel = tonumber(s[5]), kind = s[6] or "", score = tonumber(s[7]),
        }
    end
    traces[bot] = { list = list, at = GetTime() }
    if bot == ui.bot then
        E.RenderTrace()
    end
end

-- ---------------------------------------------------------------- bottom bar

local legend = W.Text(ed, "GameFontDisableSmall", W.MUTED)
legend:SetPoint("TOPLEFT", rulesArea, "BOTTOMLEFT", 4, -24)
legend:SetWidth(ROW_W - 8)
legend:SetHeight(26)
legend:SetText(L.legend)

local enabledBox = CreateFrame("CheckButton", nil, ed, "UICheckButtonTemplate")
enabledBox:SetWidth(24)
enabledBox:SetHeight(24)
enabledBox:SetPoint("BOTTOMLEFT", 0, 0)
local enabledText = W.Text(ed, "GameFontNormalSmall", W.TEXT)
enabledText:SetPoint("LEFT", enabledBox, "RIGHT", 2, 0)
enabledText:SetText(L.enabled)
enabledBox:SetScript("OnClick", function(self)
    if ui.bot then
        P.Enable(ui.bot, self:GetChecked() and true or false)
        E.Refresh()
    end
end)
enabledBox:SetScript("OnEnter", function(self)
    SimpleTip(self, L.enabledTip)
end)
enabledBox:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

local revertButton = W.Button(ed, L.revert, 90, 22, 160)
revertButton:SetPoint("BOTTOMRIGHT", 0, 1)
revertButton:SetScript("OnClick", function()
    if ui.bot then
        BT.Picker.Close()
        P.Revert(ui.bot)
    end
end)
revertButton.tip = L.revertTip

local statusText = W.Text(ed, "GameFontHighlightSmall", W.MUTED, "RIGHT")
statusText:SetPoint("RIGHT", revertButton, "LEFT", -10, 0)
statusText:SetPoint("LEFT", enabledText, "RIGHT", 20, 0)
statusText:SetHeight(12)
statusText:Hide()   -- the window's status line shows the rule-saving state (party-ui-audit 4.2)

-- ---------------------------------------------------------------- render

local function RenderHeader(b, rules)
    local slots = SlotsOf(b)
    local used = rules and #rules or 0
    local txt = L.slotsLabel .. "  " .. string.format(L.slotsValue, used, slots)
    if slots < MAX_SLOTS then
        txt = txt .. string.format(L.slotsNext, UnlockOf(b, slots + 1))
    end
    slotsLabel:SetText(txt)
    for i = 1, MAX_SLOTS do
        local t = pips[i]
        if i <= used and i <= slots then
            t:SetTexture(W.GOLD[1], W.GOLD[2], W.GOLD[3], 1)
        elseif i <= used then
            t:SetTexture(W.RED[1], W.RED[2], W.RED[3], 1)
        elseif i <= slots then
            t:SetTexture(0.42, 0.35, 0.21, 1)
        else
            t:SetTexture(0.16, 0.13, 0.10, 1)
        end
    end
end

local function RenderTabs(b)
    local pr = BT.presets[b.low]
    local _, activeIdx = BT.ActivePreset(b.low)
    local x, n = 4, 0
    -- tabs share the room left of the mode switch (party-ui-audit T3); a cut name keeps a tooltip
    local total = 1
    for idx = 1, 16 do
        if pr and pr.items[idx] then
            total = total + 1
        end
    end
    local tabMax = math.max(56, math.min(110, math.floor(496 / total)))
    if pr then
        for idx = 1, 16 do
            local p = pr.items[idx]
            if p and n < MAX_PRESET_TABS then
                n = n + 1
                local t = presetTabs[n]
                t.idx = idx
                local name = BT.Show(p.name)
                if p.dirty then
                    name = name .. "*"
                end
                W.FitTab(t, name, 56, tabMax)
                W.SetTabSelected(t, idx == activeIdx)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", x, 0)
                t:Show()
                x = x + t:GetWidth() + 2
            end
        end
    end
    for i = n + 1, MAX_PRESET_TABS do
        presetTabs[i]:Hide()
    end
    local max = (pr and pr.max) or 5
    if pr and pr.loaded and n < max then
        W.FitTab(newPresetTab, L.newPreset, 56, 110)
        newPresetTab:ClearAllPoints()
        newPresetTab:SetPoint("TOPLEFT", x + 4, 0)
        W.SetTabSelected(newPresetTab, false)
        W.Color(newPresetTab.text, W.FAINT)
        newPresetTab:Show()
    else
        newPresetTab:Hide()
    end
    W.SetTabSelected(modeTabs.co, ui.mode == "co")
    W.SetTabSelected(modeTabs.nc, ui.mode == "nc")
end

local styleAsked = {}   -- low -> true: STYLE requested for the manual-mode row (abilities-mirroring-spec 3.5)

local function RenderRules(b, rules)
    local y = 0
    local function Place(f)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", rulesArea, "TOPLEFT", 0, -y)
        f:Show()
        y = y + ROW_H + ROW_GAP
    end

    for k = 1, MAX_SLOTS do
        rows[k]:Hide()
        lockRows[k]:Hide()
    end
    addRow:Hide()

    Place(mechRow)
    local slots = SlotsOf(b)
    local n = #rules
    for k = 1, MAX_SLOTS do
        if k <= n then
            Place(rows[k])
            RenderRule(rows[k], rules[k], k, b)
        elseif k == n + 1 and k <= slots then
            addRow.text:SetText(string.format(L.addRule, slots - n))
            Place(addRow)
        elseif k > slots then
            lockRows[k].text:SetText(string.format(L.slotLocked, k, UnlockOf(b, k)))
            Place(lockRows[k])
        end
    end
    -- manual mode (abilities-mirroring-spec 3.5): the class AI does not run after the rules
    local st = BT.styles and BT.styles[b.low]
    if not st and BT.styles and not styleAsked[b.low] then
        styleAsked[b.low] = true            -- once per bot and session: the mode comes with STYLE field 9
        P.Send("STYLE", b.low)
    end
    local manualOn = st and st.manual and st.manual.on
    classRow.text:SetText(manualOn and L.classRowManual or L.classRow)
    classRow.tag:SetText(manualOn and L.classTagManual or L.classTag)
    Place(classRow)
end

local function RenderStatus(b)
    local st = BT.status[b.low]
    if st then
        statusText:SetText(BT.Show(st.text))
        if st.kind == "err" then
            W.Color(statusText, W.RED)
        elseif st.kind == "ok" then
            W.Color(statusText, W.OWN)
        else
            W.Color(statusText, W.MUTED)
        end
    else
        statusText:SetText("")
    end
    enabledBox:SetChecked(b.enabled)
    W.Enable(revertButton, P.AnyDirty(b.low) or (st and st.kind == "err"))
end

function E.Refresh()
    if not pane:IsVisible() then
        return
    end
    local b = Bot()
    if not b then
        ed:Hide()
        if not BT.gotParty then
            if BT.helloAt and GetTime() - BT.helloAt > 5 then
                message:SetText(L.noServer)
            else
                message:SetText(L.waiting)
            end
        elseif ui.bot then
            message:SetText(L.notInGroup)
        elseif #BT.party == 0 then
            message:SetText(L.noBots)
        else
            message:SetText(L.selectBot)
        end
        message:Show()
        BT.Picker.Close()
        return
    end
    ed:Show()
    local p = E.CurrentPreset()
    local rules = p and p[ui.mode]
    RenderHeader(b, rules)
    RenderTabs(b)
    RenderStatus(b)
    RenderTraceLine()
    if rules then
        message:Hide()
        rulesArea:Show()
        legend:Show()
        RenderRules(b, rules)
    else
        rulesArea:Hide()
        legend:Hide()
        message:SetText(L.loading)
        message:Show()
    end
    BT.Picker.Refresh()
end

-- Protocol callback (Protocol.lua Changed): forwarded to the party window, which refreshes the
-- roster and calls the current tab.
function E.OnData(what, bot, ...)
    Party.OnData(what, bot, ...)
end

-- ---------------------------------------------------------------- actions

local function ClearNumberFocus()
    for k = 1, MAX_SLOTS do
        for ci = 1, 2 do
            local eb = rows[k].cond[ci].num
            if eb.focused then
                eb:ClearFocus()
            end
            local sb = rows[k].cond[ci].sid
            if sb.focused then
                sb:ClearFocus()
            end
        end
    end
    if renameBox:IsShown() then
        renameBox:ClearFocus()
    end
end

-- Kept for callers of the old editor: selecting a bot goes through the party window.
function E.SelectBot(low)
    Party.Select(low)
end

local pendingAdd       -- { bot, a, x } waiting for the bot's presets (AddRuleWithAction)

-- Tab shown / other bot selected.
function E.Show(low)
    ClearNumberFocus()
    if ui.bot ~= low then
        BT.Picker.Close()
        ui.bot = low
    end
    if low and BT.bots[low] then
        if not P.AnyDirty(low) then
            P.Get(low)
        end
        P.Book(low)
    end
    E.Refresh()
    E.RenderTrace()
    if traceOpen then
        TraceTick()
    end
end

function E.Hide()
    ClearNumberFocus()
    BT.Picker.Close()
    BT.Cancel("trace")
end

local function TryPendingAdd()
    local pa = pendingAdd
    if pa and pa.bot == ui.bot and E.CurrentRules() then
        pendingAdd = nil
        E.AddRuleWithAction(pa.a, pa.x)
    end
end

-- Tab data callback.
function E.TabData(what, bot)
    if what == "presets" or what == "rules" then
        TryPendingAdd()
    end
    if bot and bot ~= ui.bot and what ~= "presets" then
        return
    end
    E.Refresh()
end

function E.SetMode(mode)
    ClearNumberFocus()
    if ui.mode ~= mode then
        BT.Picker.Close()
        ui.mode = mode
    end
    E.Refresh()
end

function E.SelectPreset(idx)
    if not ui.bot or not idx then
        return
    end
    ClearNumberFocus()
    local _, cur = E.CurrentPreset()
    if cur ~= idx then
        BT.Picker.Close()
        P.Act(ui.bot, idx)
    end
end

function E.NewPreset()
    local b = Bot()
    if not b then
        return
    end
    local pr = BT.PresetsOf(b.low)
    local max = pr.max or 5
    for idx = 1, max do
        if not pr.items[idx] then
            BT.Picker.Close()
            pr.items[idx] = { name = string.format(L.presetDefault, idx), co = {}, nc = {}, seq = 0, localNew = true }
            pr.active = idx
            P.Touch(b.low, idx, true)
            return
        end
    end
end

StaticPopupDialogs["BOTTACTICS_DELETE_PRESET"] = {
    text = L.deleteConfirm,
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        data = data or self.data
        if data then
            E.DeletePreset(data.bot, data.idx)
        end
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

function E.DeletePreset(bot, idx)
    local pr = BT.presets[bot]
    local p = pr and pr.items[idx]
    if not p then
        return
    end
    BT.Picker.Close()
    if p.localNew then
        pr.items[idx] = nil
        if pr.active == idx then
            pr.active = nil
        end
        E.Refresh()
        return
    end
    P.Del(bot, idx)
end

function E.PresetMenu(tab)
    local bot, idx = ui.bot, tab.idx
    local pr = bot and BT.presets[bot]
    local p = pr and pr.items[idx]
    if not p then
        return
    end
    local n = 0
    for _ in pairs(pr.items) do
        n = n + 1
    end
    ShowMenu(tab, {
        { text = BT.Show(p.name), isTitle = true, notCheckable = true },
        { text = L.rename, notCheckable = true, func = function() E.StartRename(tab) end },
        { text = L.deleteShort, notCheckable = true, disabled = n <= 1, func = function()
            local dialog = StaticPopup_Show("BOTTACTICS_DELETE_PRESET", p.name)
            if dialog then
                dialog.data = { bot = bot, idx = idx }
            end
        end },
    })
end

function E.StartRename(tab)
    local bot, idx = ui.bot, tab.idx
    local pr = bot and BT.presets[bot]
    local p = pr and pr.items[idx]
    if not p then
        return
    end
    renameBox.bot, renameBox.idx = bot, idx
    renameBox:ClearAllPoints()
    renameBox:SetPoint("LEFT", tab, "LEFT", 6, 0)
    renameBox:SetWidth(math.max(120, tab:GetWidth()))
    renameBox:SetText(p.name)
    renameBox:Show()
    renameBox:SetFocus()
    renameBox:HighlightText()
end

renameBox:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
end)
renameBox:SetScript("OnEscapePressed", function(self)
    self.cancel = true
    self:ClearFocus()
end)
renameBox:SetScript("OnEditFocusLost", function(self)
    local cancel = self.cancel
    self.cancel = nil
    self:Hide()
    if cancel then
        return
    end
    local pr = self.bot and BT.presets[self.bot]
    local p = pr and pr.items[self.idx]
    local name = BT.Trim(self:GetText())
    if p and name ~= "" and name ~= p.name then
        p.name = name
        P.Touch(self.bot, self.idx, true)
    end
end)

function E.AddRule()
    local rules = E.CurrentRules()
    local b = Bot()
    if not rules or not b or #rules >= SlotsOf(b) then
        return
    end
    local cat = BT.cat
    local t = cat.targetById.ally and "ally" or (cat.targets[1] and cat.targets[1].id) or "self"
    local cond
    if cat.condById.hp_lt then
        cond = { id = "hp_lt", v = "50" }
    else
        cond = { id = cat.conds[1] and cat.conds[1].id or "any" }
    end
    rules[#rules + 1] = { on = true, t = t, c = { cond }, extra = {} }
    Touch()
    BT.Picker.Open(#rules, "action")
end

-- Adds "t=self, c1=any, a=<a>, x=<x>" to the current list of the selected bot (party-window-spec 6.7,
-- used by the spellbook tab). When the presets are not loaded yet the rule is added once they arrive.
-- Returns true when the rule was added now.
function E.AddRuleWithAction(a, x)
    local low = Party.Current()
    if low and ui.bot ~= low then
        E.Show(low)
    end
    local b = Bot()
    if not b then
        return false
    end
    local rules = E.CurrentRules()
    if not rules then
        pendingAdd = { bot = b.low, a = a, x = x }
        return false
    end
    if #rules >= SlotsOf(b) then
        Party.SetStatus(b.low, L.noFreeSlot, "err")
        return false
    end
    ClearNumberFocus()
    BT.Picker.Close()
    rules[#rules + 1] = { on = true, t = "self", c = { { id = "any" } }, a = a, x = tonumber(x), extra = {} }
    Touch()
    return true
end

function E.DeleteRule(k)
    local rules = E.CurrentRules()
    if not rules or not rules[k] then
        return
    end
    ClearNumberFocus()
    BT.Picker.Close()
    table.remove(rules, k)
    Touch()
end

function E.MoveRule(k, dir)
    local rules = E.CurrentRules()
    local j = k + dir
    if not rules or not rules[k] or not rules[j] then
        return
    end
    ClearNumberFocus()
    BT.Picker.Close()
    rules[k], rules[j] = rules[j], rules[k]
    Touch()
end

function E.AddCond(row)
    local r = row.rule
    local b = Bot()
    if not r or not b or r.c[2] or (b.level or 1) < (b.cond2lvl or 60) then
        return
    end
    local cat = BT.cat
    if cat.condById.hp_lt then
        r.c[2] = { id = "hp_lt", v = cat.condById.hp_lt.default or "50" }
    else
        r.c[2] = { id = cat.conds[1].id }
    end
    Touch()
end

function E.RemoveCond(row)
    local r = row.rule
    if not r or not r.c[2] then
        return
    end
    ClearNumberFocus()
    BT.Picker.Close()
    r.c[2] = nil
    Touch()
end

-- Target dropdown: own targets, then foes; locked ids disabled with their level.
function E.TargetMenu(anchor, row)
    local r, b = row.rule, Bot()
    if not r or not b then
        return
    end
    local groups = { own = {}, foe = {}, other = {} }
    for _, t in ipairs(BT.cat.targets) do
        local g = groups[t.side] or groups.other
        g[#g + 1] = t
    end
    local items = {}
    local function AddGroup(titleText, list)
        if #list == 0 then
            return
        end
        if titleText then
            items[#items + 1] = { text = titleText, isTitle = true, notCheckable = true }
        end
        for _, t in ipairs(list) do
            local locked = BT.IsLocked(t, b.level)
            local label = BT.Show(BT.TargetLabel(t, ui.bot))
            items[#items + 1] = {
                text = locked and LockedText(label, t.lvl) or label,
                checked = r.t == t.id,
                disabled = locked,
                func = function()
                    CloseDropDownMenus()
                    if r.t ~= t.id then
                        r.t = t.id
                        Touch()
                    end
                end,
            }
        end
    end
    AddGroup(L.groupOwn, groups.own)
    AddGroup(L.groupFoe, groups.foe)
    AddGroup(nil, groups.other)
    ShowMenu(anchor, items)
end

function E.CondMenu(_, row, ci)
    local r, b = row.rule, Bot()
    if not r or not b or not r.c[ci] then
        return
    end
    -- the list is too long for a dropdown: pick in the side panel (groups + search)
    if BT.Picker.IsEditing(row.k) and BT.Picker.state.mode == "cond" and BT.Picker.state.ci == ci then
        BT.Picker.Close()
        E.Refresh()
        return
    end
    local c = r.c[ci]
    BT.Picker.Open(row.k, "cond", ci, function(id)
        local def = BT.cat.condById[id]
        if not def or c.id == id then
            return
        end
        ClearNumberFocus()
        c.id = id
        if def.param == "none" or def.param == "spell" or def.param == "spellid" then
            c.v = nil
        else
            c.v = def.default
        end
        Touch()
        if def.param == "spell" then
            BT.Picker.Open(row.k, "aura", ci)
        elseif def.param == "spellid" then
            row.cond[ci].sid:SetFocus()
        end
    end)
end

function E.ParamClick(anchor, row, ci)
    local r = row.rule
    local c = r and r.c[ci]
    if not c then
        return
    end
    local def = BT.cat.condById[c.id]
    if not def then
        return
    end
    if def.param == "spell" then
        GameTooltip:Hide()
        BT.Picker.Open(row.k, "aura", ci)
    elseif def.param == "dispel" or def.param == "enum" then
        local items = {}
        local opts = (def.param == "enum") and (BT.cat.enums[def.enum or ""] or {}) or BT.cat.dispels
        for _, d in ipairs(opts) do
            items[#items + 1] = {
                text = BT.Show(d.label),
                checked = c.v == d.id,
                func = function()
                    CloseDropDownMenus()
                    if c.v ~= d.id then
                        c.v = d.id
                        Touch()
                    end
                end,
            }
        end
        ShowMenu(anchor, items)
    end
end

local function ClampNumber(c, text)
    local v = tonumber(text)
    if not v then
        return nil
    end
    local def = BT.cat.condById[c.id]
    if def then
        if def.min and v < def.min then
            v = def.min
        end
        if def.max and v > def.max then
            v = def.max
        end
    end
    return string.format("%d", v)
end

-- A typed value changed: mark the preset dirty and save after the usual pause.
local function TypedChange()
    local _, idx = E.CurrentPreset()
    if idx then
        local pr = BT.presets[ui.bot]
        local p = pr.items[idx]
        p.dirty = true
        p.seq = (p.seq or 0) + 1
        BT.After("save" .. ui.bot, 1.0, function() P.Save(ui.bot) end)
    end
end

-- While typing: store the clamped value (saved after the usual pause); the box keeps its text.
function E.NumberChanged(row, ci, eb)
    local r = row.rule
    local c = r and r.c[ci]
    if not c then
        return
    end
    local v = ClampNumber(c, eb:GetText())
    if v and v ~= c.v then
        c.v = v
        TypedChange()
    end
end

-- Spell id box ("spellid" condition): digits or a pasted / shift-clicked spell link.
function E.SpellIdChanged(row, ci, eb)
    local r = row.rule
    local c = r and r.c[ci]
    if not c then
        return
    end
    local id = W.SpellIdOf(eb:GetText())
    local v = id and string.format("%d", id) or nil
    if v ~= c.v then
        c.v = v
        TypedChange()
    end
end

function E.SpellIdCommit(row, ci, eb, cancel)
    local r = row.rule
    local c = r and r.c[ci]
    if not c then
        return
    end
    if not cancel then
        E.SpellIdChanged(row, ci, eb)
    end
    eb:SetText(c.v or "")   -- a pasted link shows as its id
    E.Refresh()
end

function E.NumberCommit(row, ci, eb, cancel)
    local r = row.rule
    local c = r and r.c[ci]
    if not c then
        return
    end
    if not cancel then
        E.NumberChanged(row, ci, eb)
    end
    eb:SetText(c.v or "")
    E.Refresh()
end

-- ---------------------------------------------------------------- drag and drop

local drag
local dragFrame = CreateFrame("Frame", nil, ed)
dragFrame:Hide()

local function DropIndex()
    local rules = E.CurrentRules()
    local n = rules and #rules or 0
    if n == 0 then
        return nil
    end
    local _, cy = GetCursorPosition()
    cy = cy / rulesArea:GetEffectiveScale()
    for j = 1, n do
        local top, bottom = rows[j]:GetTop(), rows[j]:GetBottom()
        if top and cy <= top + ROW_GAP and cy >= bottom - ROW_GAP then
            return j
        end
    end
    local firstTop = rows[1]:GetTop()
    if firstTop and cy > firstTop then
        return 1
    end
    return n
end

dragFrame:SetScript("OnUpdate", function()
    if not drag then
        dragFrame:Hide()
        return
    end
    local to = DropIndex()
    for j = 1, MAX_SLOTS do
        local row = rows[j]
        if row:IsShown() then
            local c = (j == to and j ~= drag.from) and W.GOLD or RowBorder(row)
            row:SetBackdropBorderColor(c[1], c[2], c[3])
        end
    end
end)

function E.StartDrag(k)
    local rules = E.CurrentRules()
    if not rules or not rules[k] then
        return
    end
    ClearNumberFocus()
    BT.Picker.Close()
    drag = { from = k }
    rows[k]:SetAlpha(0.4)
    dragFrame:Show()
end

function E.StopDrag()
    if not drag then
        return
    end
    local from = drag.from
    drag = nil
    rows[from]:SetAlpha(1)
    local to = DropIndex()
    local rules = E.CurrentRules()
    if rules and to and to ~= from and rules[from] then
        local r = table.remove(rules, from)
        table.insert(rules, to, r)
        Touch()
    else
        E.Refresh()
    end
end

-- ---------------------------------------------------------------- fired highlight

local flashFrame = CreateFrame("Frame", nil, ed)
flashFrame:Hide()
flashFrame:SetScript("OnUpdate", function(self)
    local now, any = GetTime(), false
    for k = 1, MAX_SLOTS do
        local row = rows[k]
        if row.flashAt then
            local t = (now - row.flashAt) / FLASH_TIME
            local base = RowBorder(row)
            if t >= 1 or not row:IsShown() then
                row.flashAt = nil
                row:SetBackdropBorderColor(base[1], base[2], base[3])
            else
                any = true
                local a = 1 - t
                row:SetBackdropBorderColor(
                    W.FIRED[1] * a + base[1] * t, W.FIRED[2] * a + base[2] * t, W.FIRED[3] * a + base[3] * t)
            end
        end
    end
    if not any then
        self:Hide()
    end
end)

function E.FlashRule(bot, list, slot)
    if not pane:IsVisible() or ui.bot ~= bot or ui.mode ~= list then
        return
    end
    local row = rows[slot]
    if row and row:IsShown() then
        row.flashAt = GetTime()
        flashFrame:Show()
    end
end

-- Old name of the roster button lookup.
function E.PartyButton(bot)
    return Party.RosterButton(bot)
end
