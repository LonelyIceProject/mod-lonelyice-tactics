-- Static talent-tree data (party-window spec 6.6) and the small toolkit shared by the P5 tabs
-- (Gear, Talents, Book, Style). The toolkit only wraps the P4 API of spec 6.2 / 6.10 and falls
-- back to local stand-ins when a piece is missing, so these tabs load in any order of delivery.

local BT = BotTactics

BT.S = BT.S or function(en, ru)
    if BT.RU then
        return ru
    end
    return en
end
local S = BT.S

-- ---------------------------------------------------------------- talent tree fallbacks

-- Background file names under Interface\TalentFrame\ (tab order = TalentTab.tabpage 0..2),
-- used until an inspect of the bot fills BotTacticsDB.talentTabs.
BT.TALENT_BG = {
    [1] = { "WarriorArms", "WarriorFury", "WarriorProtection" },
    [2] = { "PaladinHoly", "PaladinProtection", "PaladinCombat" },
    [3] = { "HunterBeastMastery", "HunterMarksmanship", "HunterSurvival" },
    [4] = { "RogueAssassination", "RogueCombat", "RogueSubtlety" },
    [5] = { "PriestDiscipline", "PriestHoly", "PriestShadow" },
    [6] = { "DeathKnightBlood", "DeathKnightFrost", "DeathKnightUnholy" },
    [7] = { "ShamanElementalCombat", "ShamanEnhancement", "ShamanRestoration" },
    [8] = { "MageArcane", "MageFire", "MageFrost" },
    [9] = { "WarlockCurses", "WarlockSummoning", "WarlockDestruction" },
    [11] = { "DruidBalance", "DruidFeralCombat", "DruidRestoration" },
}

BT.TALENT_TAB_NAMES = {
    [1] = { S("Arms", "Оружие"), S("Fury", "Неистовство"), S("Protection", "Защита") },
    [2] = { S("Holy", "Свет"), S("Protection", "Защита"), S("Retribution", "Воздаяние") },
    [3] = { S("Beast Mastery", "Повелитель зверей"), S("Marksmanship", "Стрельба"), S("Survival", "Выживание") },
    [4] = { S("Assassination", "Ликвидация"), S("Combat", "Бой"), S("Subtlety", "Скрытность") },
    [5] = { S("Discipline", "Послушание"), S("Holy", "Свет"), S("Shadow", "Тьма") },
    [6] = { S("Blood", "Кровь"), S("Frost", "Лед"), S("Unholy", "Нечестивость") },
    [7] = { S("Elemental", "Укрощение стихии"), S("Enhancement", "Совершенствование"), S("Restoration", "Исцеление") },
    [8] = { S("Arcane", "Тайная магия"), S("Fire", "Огонь"), S("Frost", "Лед") },
    [9] = { S("Affliction", "Колдовство"), S("Demonology", "Демонология"), S("Destruction", "Разрушение") },
    [11] = { S("Balance", "Баланс"), S("Feral Combat", "Сила зверя"), S("Restoration", "Исцеление") },
}

-- { name, icon, bg } of tree `tab` (0..2) of class `cls`: inspect cache first, then the tables above.
-- icon may be nil here; Talents.lua falls back to the icon of the tree's first talent.
function BT.TalentTabInfo(cls, tab)
    cls = tonumber(cls)
    local db = BotTacticsDB and BotTacticsDB.talentTabs
    local c = db and cls and db[cls]
    local e = c and c[tab]
    local names = cls and BT.TALENT_TAB_NAMES[cls]
    local bgs = cls and BT.TALENT_BG[cls]
    return {
        name = (e and e.name) or (names and names[tab + 1]) or "?",
        icon = e and e.icon,
        bg = (e and e.bg) or (bgs and bgs[tab + 1]),
    }
end

-- ---------------------------------------------------------------- P5 toolkit

local K = {}
BT.TabKit = K

-- Protocol handler table (spec 6.2: P.Handlers = H). Stand-in when Protocol.lua does not expose it
-- yet: a second table consulted after the built-in handlers.
function K.Handlers()
    local P = BT.Protocol
    if not P.Handlers then
        local extra = {}
        P.Handlers = extra
        local orig = P.OnPayload
        local function Dispatch(payload)
            orig(payload)
            local f = BT.Split(payload, "\t")
            local h = extra[f[1]]
            if h then
                h(f)
            end
        end
        P.OnPayload = Dispatch
        BT.Transport.OnPayload = Dispatch
    end
    return P.Handlers
end

-- Adds fn to the handler of message `name`, keeping whatever another file registered before.
-- P4's P.Handlers chains on assignment by itself (metatable); the stand-in table does not.
function K.Hook(name, fn)
    local H = K.Handlers()
    if getmetatable(H) then
        H[name] = fn
        return
    end
    local prev = H[name]
    H[name] = function(f)
        if prev then
            prev(f)
        end
        fn(f)
    end
end

function K.Send(...)
    local P = BT.Protocol
    if P.Send then
        return P.Send(...)
    end
    if not BT.Transport.Send(table.concat({ ... }, "\t")) then
        BT.Print("bad payload")
    end
end

-- bot, op, ok, code, text of an ACK payload
function K.Ack(f)
    local text = BT.Unesc(f[6])
    if text == "" then
        text = f[5] or ""
    end
    return tonumber(f[2]), f[3], f[4] == "ok", f[5], text
end

-- ---------------------------------------------------------------- party shell access (spec 6.2)

-- Minimal stand-in used only while Party.lua (P4) is absent.
if not BT.Party then
    local party = { stub = true, panes = {}, selectHooks = {} }
    BT.Party = party
    function party.RegisterTab(id, label, onShow, onHide)
        local pane = CreateFrame("Frame", nil, BotTacticsFrame)
        pane:SetPoint("TOPLEFT", 250, -150)
        pane:SetPoint("BOTTOMRIGHT", -16, 36)
        pane:Hide()
        pane.tabId, pane.label = id, label
        pane:SetScript("OnShow", function(self) if onShow then onShow(self) end end)
        pane:SetScript("OnHide", function(self) if onHide then onHide(self) end end)
        party.panes[id] = pane
        return pane
    end
    function party.SelectTab(id)
        for pid, pane in pairs(party.panes) do
            if pid ~= id then
                pane:Hide()
            end
        end
        if party.panes[id] then
            party.panes[id]:Show()
        end
    end
    function party.Current()
        return BT.Editor and BT.Editor.ui and BT.Editor.ui.bot
    end
    function party.Unit(low)
        if BT.UnitByLow then
            return BT.UnitByLow(low)
        end
        for i = 1, 4 do
            local u = "party" .. i
            if UnitExists(u) and BT.UnitLow(u) == low then
                return u
            end
        end
        return nil
    end
    function party.Refresh() end
    function party.SetStatus(low, text, kind)
        if BT.Protocol.SetStatus then
            BT.Protocol.SetStatus(low, text, kind)
        end
    end
    function party.OnSelect(fn)
        party.selectHooks[#party.selectHooks + 1] = fn
    end
end

-- True when Protocol.lua (P4) already shows every ACK error in the status line and does the
-- stale/moving follow-ups of ITEM (spec 8); the tabs then only add their own reactions.
K.sharedAck = not BT.Party.stub

function K.Current()
    return BT.Party.Current()
end

function K.Unit(low)
    return low and BT.Party.Unit(low)
end

function K.Status(low, text, kind)
    if low and BT.Party.SetStatus then
        BT.Party.SetStatus(low, text, kind)
    end
end

function K.Bot(low)
    return low and BT.bots[low]
end

-- Switches the window to another tab (the 6.2 API has no name for it; try the likely ones).
function K.ShowTab(id)
    local p = BT.Party
    local fn = p.SelectTab or p.SetTab or p.ShowTab
    if fn then
        fn(id)
        return true
    end
    return false
end

-- Registers a tab; onRequest(low) sends the tab's requests, onRender() redraws it.
-- Requests go out on show and on bot selection (deduplicated: the shell may do both).
function K.Tab(id, label, onRequest, onRender, onHide)
    local lastLow, lastAt
    local pane
    local function Request()
        local low = K.Current()
        if not low then
            onRender()
            return
        end
        local now = GetTime()
        if low ~= lastLow or not lastAt or now - lastAt > 0.5 then
            lastLow, lastAt = low, now
            onRequest(low)
        end
        onRender()
    end
    -- The tab's own message hooks redraw on their data; the shell's data callback only matters for
    -- changes of the party itself (names, levels, roles) and the catalogue.
    local function OnData(what)
        if pane and pane:IsVisible() and (what == "party" or what == "catalog" or what == "refresh") then
            onRender()
        end
    end
    pane = BT.Party.RegisterTab(id, label, Request, onHide, OnData)
    pane.onData = OnData
    -- the real shell calls onShow again on selection; the stand-in needs the hook
    if BT.Party.stub and BT.Party.OnSelect then
        BT.Party.OnSelect(function()
            if pane:IsVisible() then
                Request()
            end
        end)
    end
    return pane
end

-- Usable pane size (the shell sizes the pane; before the first layout GetWidth may be 0).
function K.PaneSize(pane)
    local w, h = pane:GetWidth() or 0, pane:GetHeight() or 0
    if w < 300 then
        w = BT.Party.CONTENT_W or 740
    end
    if h < 200 then
        h = BT.Party.CONTENT_H or 420
    end
    return w, h
end

-- ---------------------------------------------------------------- shared client helpers (spec 6.10)

function K.GuidHex(unit)
    if BT.GuidHex then
        return BT.GuidHex(unit)
    end
    local g = unit and UnitGUID(unit)
    if not g then
        return nil
    end
    return string.upper(string.sub(g, 3))
end

function K.Money(copper)
    if BT.Money then
        return BT.Money(copper)
    end
    copper = math.floor(tonumber(copper) or 0)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local out = {}
    if g > 0 then
        out[#out + 1] = g .. "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t"
    end
    if g > 0 or s > 0 then
        out[#out + 1] = s .. "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t"
    end
    out[#out + 1] = c .. "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t"
    return table.concat(out, " ")
end

StaticPopupDialogs["BOTTACTICS_P5_CONFIRM"] = {
    text = "%s",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        data = data or self.data
        if data then
            data()
        end
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

function K.Confirm(key, text, fn)
    if BT.Confirm then
        return BT.Confirm(key, text, fn)
    end
    local dialog = StaticPopup_Show("BOTTACTICS_P5_CONFIRM", text)
    if dialog then
        dialog.data = fn
    end
end

-- Text prompt; fn(text) on accept (BT.Prompt of Util.lua, else a local dialog).
local promptDefault = ""
StaticPopupDialogs["BOTTACTICS_P5_PROMPT"] = {
    text = "%s",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = 1,
    maxLetters = 64,
    OnShow = function(self)
        local eb = _G[self:GetName() .. "EditBox"]
        if eb then
            eb:SetText(promptDefault)
            eb:SetFocus()
        end
    end,
    OnAccept = function(self, data)
        data = data or self.data
        local eb = _G[self:GetName() .. "EditBox"]
        if type(data) == "function" and eb then
            data(eb:GetText())
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

function K.Prompt(key, text, default, fn)
    if BT.Prompt then
        return BT.Prompt(key, text, default, fn)
    end
    promptDefault = default or ""
    local d = StaticPopup_Show("BOTTACTICS_P5_PROMPT", text)
    if d then
        d.data = fn
    end
    return d
end

local menuFrame
function K.Menu(anchor, items)
    if BT.W.ShowMenu then
        return BT.W.ShowMenu(anchor, items)
    end
    menuFrame = menuFrame or CreateFrame("Frame", "BotTacticsTabMenu", UIParent, "UIDropDownMenuTemplate")
    CloseDropDownMenus()
    EasyMenu(items, menuFrame, anchor, 0, 0, "MENU")
end

-- ---------------------------------------------------------------- widgets

-- On/off switch (34x18): a track and a knob that slides right when on.
function K.Switch(parent)
    local W = BT.W
    if W.Switch then
        return W.Switch(parent)
    end
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(34)
    b:SetHeight(18)
    W.Panel(b, { 0.16, 0.14, 0.11, 1 }, W.LINE)
    b.knob = b:CreateTexture(nil, "OVERLAY")
    b.knob:SetTexture("Interface\\Buttons\\WHITE8X8")
    b.knob:SetWidth(12)
    b.knob:SetHeight(12)
    K.SetSwitch(b, false)
    return b
end

function K.SetSwitch(b, on)
    if BT.W.SetSwitch then
        return BT.W.SetSwitch(b, on)
    end
    b.on = on and true or false
    b.knob:ClearAllPoints()
    if b.on then
        b.knob:SetPoint("RIGHT", -3, 0)
        b.knob:SetVertexColor(0.37, 0.85, 0.40)
        b:SetBackdropColor(0.12, 0.23, 0.13, 1)
        b:SetBackdropBorderColor(0.25, 0.48, 0.27)
    else
        b.knob:SetPoint("LEFT", 3, 0)
        b.knob:SetVertexColor(0.42, 0.37, 0.31)
        b:SetBackdropColor(0.16, 0.14, 0.11, 1)
        b:SetBackdropBorderColor(BT.W.LINE[1], BT.W.LINE[2], BT.W.LINE[3])
    end
end

-- Enable/disable a button and dim it (the flat W.Tab style has no disabled look of its own).
function K.Enable(b, on)
    BT.W.Enable(b, on)
    b:SetAlpha(on and 1 or 0.45)
end

-- Card: panel with a small gold caption at the top. Same look as W.Card (party-ui-audit W3): the caption
-- keeps its case (string.upper does not touch Cyrillic in Lua 5.1, so enGB and ruRU looked different).
function K.Card(parent, caption)
    local W = BT.W
    if W.Card then
        local c = W.Card(parent, caption, 10, 10)
        c.caption = c.title
        return c
    end
    local c = CreateFrame("Frame", nil, parent)
    W.Panel(c, { 0.07, 0.055, 0.04, 0.95 }, { 0.29, 0.23, 0.14 })
    c.caption = W.Text(c, "GameFontNormalSmall", W.GOLD_DIM)
    c.caption:SetPoint("TOPLEFT", 10, -8)
    c.caption:SetText(caption or "")
    return c
end

-- Scroll frame with a scroll child of the given width; returns scroll, child.
function K.Scroll(parent, name, width)
    local scroll = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(width)
    child:SetHeight(10)
    scroll:SetScrollChild(child)
    return scroll, child
end

-- ---------------------------------------------------------------- inspect (model data + talent tab cache)

local inspect = { last = {} }

-- NotifyInspect once per bot and 15 s while the bot is within inspect range (28 yd); never while
-- the player's own inspect window is open (it would switch to the bot).
function K.Inspect(low)
    local unit = K.Unit(low)
    if not unit or not UnitIsVisible(unit) or not CheckInteractDistance(unit, 1) then
        return false
    end
    if InspectFrame and InspectFrame:IsShown() then
        return false
    end
    local now = GetTime()
    if inspect.last[low] and now - inspect.last[low] < 15 then
        return false
    end
    inspect.last[low] = now
    local b = K.Bot(low)
    inspect.pending = { low = low, unit = unit, guid = UnitGUID(unit), class = b and tonumber(b.class), at = now }
    NotifyInspect(unit)
    return true
end

K.onTalentTabs = {}

local inspectEvents = CreateFrame("Frame")
inspectEvents:RegisterEvent("INSPECT_TALENT_READY")
inspectEvents:SetScript("OnEvent", function()
    local p = inspect.pending
    inspect.pending = nil
    if not p or not p.class or GetTime() - p.at > 10 or UnitGUID(p.unit) ~= p.guid or not BotTacticsDB then
        return
    end
    local group = (GetActiveTalentGroup and GetActiveTalentGroup(true)) or 1
    local tabs = {}
    for tab = 1, 3 do
        local name, icon, _, bg = GetTalentTabInfo(tab, true, nil, group)
        if not name or not bg or bg == "" then
            return
        end
        tabs[tab - 1] = { name = name, icon = icon, bg = bg }
    end
    BotTacticsDB.talentTabs = BotTacticsDB.talentTabs or {}
    BotTacticsDB.talentTabs[p.class] = tabs
    for _, fn in ipairs(K.onTalentTabs) do
        fn(p.class)
    end
end)
