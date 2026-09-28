-- Party window "Отряд" (party-window-spec 6.2): main frame, orders strip, roster, header of the
-- selected bot, tab bar, shared status line and the tab registry the tab files plug into.

local BT = BotTactics
local L, W, P = BT.L, BT.W, BT.Protocol
local S = BT.S

-- party-ui-audit 6.1-6.4: the strip keeps the orders, the group menu holds everything else
L.ordGroup = S("Group", "Группа")
L.ordStayShort = S("Stay", "Стоять")
L.ordMark = S("Default mark", "Метка по умолчанию")
L.ordForAll = S("For every bot", "Всем ботам")
L.lootForAll = S("Loot rule for every bot", "Добыча для всех")
L.headMore = S("More", "Ещё")
L.headMoreTip = S("Other actions for this bot", "Другие действия с этим ботом")
L.pillCall = S("Call", "Позвать")
L.pillCallTip = S("Invite into the group", "Пригласить в группу")
L.pillLoginTip = S("Log the bot in", "Ввести бота в игру")
L.rosterMore = S("%d more below", "ещё %d ниже")
L.showFiredShort = S("Show fired rules", "Показывать сработавшие правила")

local Party = {}
BT.Party = Party

local WIDTH, HEIGHT = 1010, 640
local ROSTER_W = 230
local MAIN_X = 16 + ROSTER_W + 8
local MAIN_W = WIDTH - MAIN_X - 16
local ORDERS_Y = -30
local TOP_Y = -62                   -- roster and header top
local TABS_Y = TOP_Y - 48
local STATUS_Y = TABS_Y - 28
local CONTENT_Y = STATUS_Y - 16
local STATUS_TIME = 6
local HP_TICK = 0.5
local ROW_H = { sect = 20, party = 44, acct = 32, add = 26, empty = 20 }
local MORE_H = 16                   -- "N more below" line under the roster list
local TAB_ORDER = { tactics = 1, book = 2, gear = 3, bags = 4, talents = 5, style = 6, misc = 7 }
local MARK_ICON = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_%d:14:14|t "
local STAR = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:12:12|t"
local ATTACK_ICON = "|TInterface\\Icons\\Ability_SteelMelee:14:14|t "
local TRADE_RANGE = 2               -- CheckInteractDistance index 2: trade, 11.11 yd

local cur                           -- selected bot low
local tabs, tabById = {}, {}
local curTab
local selectHooks = {}
local statusBy = {}                 -- low (0 = group) -> { text, kind, at }
local passiveOn = false
local lootMode

-- ---------------------------------------------------------------- main frame

local frame = CreateFrame("Frame", "BotTacticsFrame", UIParent)
Party.frame = frame
frame:SetWidth(WIDTH)
frame:SetHeight(HEIGHT)
frame:SetPoint("CENTER")
frame:SetFrameStrata("HIGH")
frame:SetToplevel(true)
frame:SetClampedToScreen(true)
frame:EnableMouse(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")
-- opaque background (findings.md: the world and the quest tracker showed through the window)
frame:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
frame:SetBackdropColor(0.09, 0.07, 0.045, 1)
frame:Hide()
tinsert(UISpecialFrames, "BotTacticsFrame")

local tint = frame:CreateTexture(nil, "BACKGROUND")
tint:SetTexture(0.09, 0.07, 0.045, 1)
tint:SetPoint("TOPLEFT", 11, -12)
tint:SetPoint("BOTTOMRIGHT", -12, 11)

local header = frame:CreateTexture(nil, "ARTWORK")
header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
header:SetWidth(340)
header:SetHeight(64)
header:SetPoint("TOP", 0, 12)

local title = W.Text(frame, "GameFontNormal", nil, "CENTER")
title:SetPoint("TOP", header, "TOP", 0, -14)
title:SetText(L.title)

-- Mouse zone over a part of the window that shows a tooltip and still drags the window.
local function TipZone(parent)
    local z = CreateFrame("Frame", nil, parent)
    z:EnableMouse(true)
    z:RegisterForDrag("LeftButton")
    z:SetScript("OnDragStart", function()
        frame:StartMoving()
    end)
    z:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        Party.SavePosition()
    end)
    return z
end
Party.TipZone = TipZone

-- the slash commands are the title's tooltip (they used to sit over the top-left border)
local titleZone = TipZone(frame)
titleZone:SetPoint("TOPLEFT", header, "TOPLEFT", 60, -8)
titleZone:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", -60, 28)
titleZone:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText(L.title, 1, 0.82, 0)
    GameTooltip:AddLine("/party  /bt", 1, 1, 1)
    GameTooltip:Show()
end)
titleZone:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", -4, -4)

frame:SetScript("OnDragStart", function(self)
    self:StartMoving()
end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    Party.SavePosition()
end)

function Party.SavePosition()
    if not BotTacticsDB then
        return
    end
    local point, _, relPoint, x, y = frame:GetPoint(1)
    BotTacticsDB.pos = { point, relPoint, x, y }
end

function Party.RestorePosition()
    local p = BotTacticsDB and BotTacticsDB.pos
    frame:ClearAllPoints()
    if p then
        frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        frame:SetPoint("CENTER")
    end
end

-- ---------------------------------------------------------------- lookups

local function PartyBot(low)
    return low and BT.bots[low]
end

local function AcctBot(low)
    return low and BT.acctByLow and BT.acctByLow[low]
end

-- Entry (party or account) of a low guid.
local function Entry(low)
    return PartyBot(low) or AcctBot(low)
end

local function RoleLabel(role)
    if role == "tank" then
        return L.roleTank
    elseif role == "heal" then
        return L.roleHeal
    elseif role == "dps" then
        return L.roleDps
    end
    return nil
end

local function FavKey(name)
    return BT.Norm(name or "")
end

function Party.IsFavorite(name)
    local fav = BotTacticsDB and BotTacticsDB.favorites
    return fav and fav[FavKey(name)] and true or false
end

function Party.ToggleFavorite(name)
    if not BotTacticsDB or not name or name == "" then
        return
    end
    BotTacticsDB.favorites = BotTacticsDB.favorites or {}
    local k = FavKey(name)
    if BotTacticsDB.favorites[k] then
        BotTacticsDB.favorites[k] = nil
    else
        BotTacticsDB.favorites[k] = true
    end
    Party.Refresh()
end

local function SetClassIcon(tex, class)
    local token = BT.ClassToken(class)
    local coords = token and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[token]
    if coords then
        tex:SetTexture("Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes")
        tex:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    else
        tex:SetTexture(BT.ICON_UNKNOWN)
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end

-- Live health of a party bot: fraction and dead flag (PARTY snapshot when the unit is unknown).
local function Health(b)
    local unit = BT.UnitByLow(b.low)
    if unit then
        local max = UnitHealthMax(unit) or 0
        local hp = (max > 0) and (UnitHealth(unit) or 0) / max or 0
        return hp, UnitIsDeadOrGhost(unit) and true or false
    end
    return (b.hp or 100) / 100, not b.alive
end

-- ---------------------------------------------------------------- group commands

local function CmdAll(text)
    P.CmdAll(text)
end

function Party.Cmd(low, text)
    if low and PartyBot(low) then
        P.Cmd(low, text)
    end
end

-- ---------------------------------------------------------------- role scope ("To whom", multibot-gap P4)

local SCOPE_IDS = { all = true, tank = true, heal = true, dps = true, melee = true, ranged = true }

function Party.Scope()
    local s = BotTacticsDB and BotTacticsDB.orderScope
    return (s and SCOPE_IDS[s]) and s or "all"
end

-- Label of a scope: the server's (PULLSET field 6), else the local table.
function Party.ScopeLabel(id)
    local ps = BT.pullSet
    local label = ps and ps.scopeLabel and ps.scopeLabel[id]
    if label and label ~= "" then
        return label
    end
    for _, s in ipairs(L.scopes) do
        if s.id == id then
            return s.label
        end
    end
    return id
end

local function ScopeList()
    local ps = BT.pullSet
    if ps and ps.scopes and #ps.scopes > 0 then
        return ps.scopes
    end
    return L.scopes
end

-- Order of the strip for the chosen scope: CMDALL for everyone, CMDROLE otherwise.
function Party.Order(text)
    local scope = Party.Scope()
    if scope == "all" then
        CmdAll(text)
    else
        P.CmdRole(scope, text)
    end
end

local function SetGroup(key, value)
    P.Send("GROUP", key, value)
end

-- Current rti value of GROUPSET as a mark entry (value may be the name or the icon index).
local function CurrentMark()
    local v = BT.groupSet and BT.groupSet.rti or ""
    for _, m in ipairs(L.marks) do
        if m.id == v or tostring(m.icon) == v then
            return m
        end
    end
    return nil
end

-- Labels of the stored group settings (nil when unset).
function Party.FormationLabel()
    local v = BT.groupSet and BT.groupSet.formation
    for _, fm in ipairs(L.formations) do
        if fm.id == v then
            return fm.label
        end
    end
    return nil
end

function Party.MarkLabel()
    local m = CurrentMark()
    if not m then
        return nil
    end
    return ((m.icon > 0) and string.format(MARK_ICON, m.icon) or "") .. m.label
end

-- Menu item lists (party-ui-audit 6.1): the same lists serve as a menu of their own and as a submenu of
-- "Group".
function Party.FormationItems()
    local items = {}
    for _, fm in ipairs(L.formations) do
        items[#items + 1] = {
            text = fm.label,
            checked = BT.groupSet and BT.groupSet.formation == fm.id,
            func = function()
                CloseDropDownMenus()
                SetGroup("formation", fm.id)
            end,
        }
    end
    return items
end

function Party.MarkItems()
    local items = {}
    local cm = CurrentMark()
    for _, m in ipairs(L.marks) do
        local icon = (m.icon > 0) and string.format(MARK_ICON, m.icon) or ""
        items[#items + 1] = {
            text = icon .. m.label,
            checked = cm == m,
            func = function()
                CloseDropDownMenus()
                SetGroup("rti", m.id)
            end,
        }
    end
    -- one-off tank orders (ChatTriggerContext "pull" -> pull my target, "pull rti" -> pull rti target)
    items[#items + 1] = { text = L.ordTankPull, notCheckable = true, func = function()
        CloseDropDownMenus()
        P.CmdRole("tank", "pull")
    end }
    items[#items + 1] = { text = L.ordTankPullRti, notCheckable = true, func = function()
        CloseDropDownMenus()
        P.CmdRole("tank", "pull rti")
    end }
    return items
end

local function WithTitle(title, items)
    local out = { { text = title, isTitle = true, notCheckable = true } }
    for _, it in ipairs(items) do
        out[#out + 1] = it
    end
    return out
end

function Party.FormationMenu(anchor)
    W.ShowMenu(anchor, WithTitle(L.ordFormation, Party.FormationItems()))
end

function Party.MarksMenu(anchor)
    W.ShowMenu(anchor, WithTitle(L.defaultMark, Party.MarkItems()))
end

function Party.ReviveItems()
    return {
        { text = L.ordRelease, notCheckable = true, func = function() CloseDropDownMenus() Party.Order("release") end },
        { text = L.ordSpirit, notCheckable = true, func = function() CloseDropDownMenus() Party.Order("revive") end },
        { text = L.autoRelease, checked = BotTacticsDB and BotTacticsDB.autoRelease and true or false,
          tooltipTitle = L.autoRelease, tooltipText = L.autoReleaseTip, func = function()
            CloseDropDownMenus()
            Party.SetAutoRelease(not (BotTacticsDB and BotTacticsDB.autoRelease))
        end },
    }
end

local LayoutOrders

local function ScopeMenu(anchor)
    local items = { { text = L.ordWhoTip, isTitle = true, notCheckable = true } }
    local now = Party.Scope()
    for _, s in ipairs(ScopeList()) do
        local id = s.id
        items[#items + 1] = {
            text = Party.ScopeLabel(id),
            checked = id == now,
            func = function()
                CloseDropDownMenus()
                Party.SetScope(id)
            end,
        }
    end
    W.ShowMenu(anchor, items)
end

function Party.SetScope(id)
    if not SCOPE_IDS[id] or not BotTacticsDB then
        return
    end
    BotTacticsDB.orderScope = id
    LayoutOrders()
    if Party.pullCard and Party.pullCard:IsShown() then
        Party.RenderPull()
    end
end

function Party.LootItems()
    local items = {}
    for _, m in ipairs(L.lootModes) do
        items[#items + 1] = {
            text = m.label,
            checked = lootMode == m.id,
            tooltipTitle = m.label, tooltipText = m.desc, tooltipOnButton = m.desc and true or nil,
            func = function()
                CloseDropDownMenus()
                lootMode = m.id
                for _, b in ipairs(BT.party) do
                    P.Send("SETLOOT", b.low, "mode", m.id)
                end
            end,
        }
    end
    return items
end

-- ---------------------------------------------------------------- group actions (multibot-gap C2 #7, #8, #10)
-- Every item of the "Group" menu below the orders: all bots, whatever the strip's "To whom" scope is.

local grindOn = false
local pendingInvite = {}      -- low -> time of the LOGIN sent by "call favourites" (invite when it is online)
local INVITE_WAIT = 30
local DISPERSE_YD = { 5, 10, 15, 20 }
local LOGIN_AT_ONCE = 4

function Party.AllLogout()
    local list = {}
    for _, b in ipairs(BT.party) do
        list[#list + 1] = b.low
    end
    if #list == 0 then
        return
    end
    BT.Confirm("alllogout", string.format(L.confirmAllLogout, #list), function()
        for _, low in ipairs(list) do
            P.Send("LOGOUT", BT.GuidField(low))
        end
    end)
end

function Party.AllSellGrey()
    for _, b in ipairs(BT.party) do
        P.Send("SELLGREY", b.low)
    end
end

-- Offline account bots (state 0), up to LOGIN_AT_ONCE of them.
function Party.AnyOffline()
    for _, a in ipairs(BT.acct) do
        if a.state == 0 then
            return true
        end
    end
    return false
end

function Party.AllLogin()
    local n = 0
    for _, a in ipairs(BT.acct) do
        if a.state == 0 and n < LOGIN_AT_ONCE then
            n = n + 1
            P.Send("LOGIN", a.id or BT.GuidField(a.low))
        end
    end
end

-- Free places of the group (a party of 5; a raid of 40).
local function FreeSlots()
    local raid = GetNumRaidMembers and GetNumRaidMembers() or 0
    if raid > 0 then
        return 40 - raid
    end
    local party = GetNumPartyMembers and GetNumPartyMembers() or #BT.party
    return 4 - party
end

-- Favourites not in the group: online ones are invited, offline ones logged in and invited when BOTS
-- reports them online.
function Party.CallFavorites()
    local free, n = FreeSlots(), 0
    local now = GetTime()
    for _, a in ipairs(BT.acct) do
        if n >= free then
            break
        end
        if not BT.bots[a.low] and Party.IsFavorite(a.name) then
            if a.state == 1 then
                InviteUnit(a.name)
                n = n + 1
            elseif a.state == 0 then
                P.Send("LOGIN", a.id or BT.GuidField(a.low))
                pendingInvite[a.low] = now
                n = n + 1
            end
        end
    end
    if n == 0 then
        Party.SetStatus(0, L.noFavs, "err")
    end
end

-- BOTS arrived: invite the favourites that came online.
local function InvitePending()
    local now = GetTime()
    for low, at in pairs(pendingInvite) do
        local a = BT.acctByLow[low]
        if now - at > INVITE_WAIT or (a and a.state >= 2) then
            pendingInvite[low] = nil
        elseif a and a.state == 1 then
            pendingInvite[low] = nil
            InviteUnit(a.name)
        end
    end
end

P.Handlers.BOTS = function()
    InvitePending()
end

-- Roll link in the whitelist form "|Hitem:<entry>:0|h[x]|h|r" (loot.lua, protocol.lua ITEM_LINK).
function Party.RollLink(entry)
    return "roll |Hitem:" .. entry .. ":0|h[x]|h|r"
end

function Party.RollPrompt()
    BT.Prompt("roll", L.rollPrompt, "", function(text)
        local entry = tonumber(string.match(text or "", "item:(%d+)") or BT.Trim(text or ""))
        if entry and entry > 0 then
            P.CmdAll(Party.RollLink(entry))
        end
    end)
end

function Party.SetGrind(on)
    grindOn = on and true or false
    P.CmdAll(grindOn and "grind" or "follow")
end

function Party.SetAutoRelease(on)
    if BotTacticsDB then
        BotTacticsDB.autoRelease = on and true or false
    end
end

function Party.SetShowFired(on)
    if BotTacticsDB then
        BotTacticsDB.showFired = on and true or false
    end
    P.UpdateWatch()
end

local function DisperseItems()
    local items = {}
    for _, yd in ipairs(DISPERSE_YD) do
        items[#items + 1] = { text = string.format(L.disperseYd, yd), notCheckable = true, func = function()
            CloseDropDownMenus()
            P.CmdAll("disperse set " .. yd)
        end }
    end
    items[#items + 1] = { text = L.disperseOff, notCheckable = true, func = function()
        CloseDropDownMenus()
        P.CmdAll("disperse disable")
    end }
    return items
end

-- Items of the "Group" menu of the strip.
function Party.GroupItems()
    local function Do(fn)
        return function()
            CloseDropDownMenus()
            fn()
        end
    end
    return {
        { text = L.ordGroup, isTitle = true, notCheckable = true },
        { text = L.ordFormation, notCheckable = true, hasArrow = true, menuList = Party.FormationItems() },
        { text = L.ordMark, notCheckable = true, hasArrow = true, menuList = Party.MarkItems() },
        { text = L.ordRevive, notCheckable = true, hasArrow = true, menuList = Party.ReviveItems() },
        { text = L.ordDrink, notCheckable = true, func = Do(function() Party.Order("drink") end) },
        { text = L.lootForAll, notCheckable = true, hasArrow = true, menuList = Party.LootItems() },
        { text = L.ordForAll, isTitle = true, notCheckable = true },
        { text = L.allMaint, notCheckable = true, func = Do(function() P.CmdAll("maintenance") end) },
        { text = L.allSellGrey, notCheckable = true, func = Do(Party.AllSellGrey) },
        { text = L.callFavs, notCheckable = true, tooltipTitle = L.callFavs, tooltipText = L.callFavsTip,
          func = Do(Party.CallFavorites) },
        { text = L.allLogin, notCheckable = true, disabled = not Party.AnyOffline(), tooltipTitle = L.allLogin,
          tooltipText = L.allLoginTip, func = Do(Party.AllLogin) },
        { text = L.rollItem, notCheckable = true, func = Do(Party.RollPrompt) },
        { text = L.disperse, notCheckable = true, hasArrow = true, menuList = DisperseItems() },
        { text = L.grindMode, checked = grindOn, tooltipTitle = L.grindMode, tooltipText = L.grindTip,
          func = Do(function() Party.SetGrind(not grindOn) end) },
        { text = L.showFiredShort, checked = BotTacticsDB and BotTacticsDB.showFired and true or false,
          tooltipTitle = L.showFiredShort, tooltipText = L.showFired,
          func = Do(function() Party.SetShowFired(not (BotTacticsDB and BotTacticsDB.showFired)) end) },
        { text = L.allLogout, notCheckable = true, func = Do(Party.AllLogout) },
    }
end

local function GroupMenu(anchor)
    W.ShowMenu(anchor, Party.GroupItems())
end
Party.GroupMenu = GroupMenu

-- Auto-release (addon option): a party bot lying dead (not a ghost yet) gets "release" once; again after
-- RELEASE_RETRY s if it is still a corpse.
local RELEASE_TICK, RELEASE_RETRY = 1, 30
local released = {}
local releaser = CreateFrame("Frame")
releaser.t = 0
releaser:SetScript("OnUpdate", function(self, elapsed)
    self.t = self.t + (elapsed or 0)
    if self.t < RELEASE_TICK then
        return
    end
    self.t = 0
    if not (BotTacticsDB and BotTacticsDB.autoRelease) or not UnitIsDead then
        return
    end
    local now = GetTime()
    for _, b in ipairs(BT.party) do
        local unit = BT.UnitByLow(b.low)
        local corpse = unit and UnitIsDead(unit) and not (UnitIsGhost and UnitIsGhost(unit))
        if not corpse then
            released[b.low] = nil
        elseif not released[b.low] or now - released[b.low] > RELEASE_RETRY then
            released[b.low] = now
            P.Cmd(b.low, "release")
        end
    end
end)
Party.releaser = releaser

-- ---------------------------------------------------------------- orders strip

local orders = CreateFrame("Frame", nil, frame)
orders:SetPoint("TOPLEFT", 14, ORDERS_Y)
orders:SetPoint("TOPRIGHT", -14, ORDERS_Y)
orders:SetHeight(28)
W.Panel(orders, { 0.08, 0.06, 0.045, 0.9 }, W.LINE)
Party.orders = orders

local function PullToggle(anchor)
    Party.TogglePull(anchor)
end

local ORDERS = {
    { label = L.ordWho },
    { scope = true, menu = ScopeMenu, tip = L.ordWhoTip },
    { text = ATTACK_ICON .. L.ordAttackShort, cmd = "attack my target", tip = L.ordAttack },
    { text = L.ordFollow, cmd = "follow" },
    { text = L.ordStayShort, cmd = "stay", tip = L.ordStay },
    { text = L.ordFlee, cmd = "flee" },
    { text = L.ordPassive, toggle = true, tip = L.ordPassiveTip },
    { sep = true },
    { text = L.ordGroup .. W.CARET, menu = GroupMenu, group = true },
    { sep = true },
    { text = L.ordPull .. W.CARET, menu = PullToggle, pull = true },
}

local orderButtons = {}
local orderItems = {}               -- every widget of the strip in ORDERS order (for LayoutOrders)
local passiveButton, scopeButton
do
    for _, o in ipairs(ORDERS) do
        if o.label then
            local fs = W.Text(orders, "GameFontNormalSmall", W.GOLD_DIM)
            fs:SetText(o.label)
            orderItems[#orderItems + 1] = { w = fs, gap = 6, fs = true }
        elseif o.sep then
            local t = orders:CreateTexture(nil, "ARTWORK")
            t:SetTexture(W.LINE[1], W.LINE[2], W.LINE[3], 1)
            t:SetWidth(1)
            t:SetHeight(18)
            orderItems[#orderItems + 1] = { w = t, sep = true }
        else
            local b = W.Tab(orders, 20)
            if o.text then
                W.FitTab(b, o.text, 40, 160)
            end
            b.tip = o.tip
            b.def = o
            b:SetScript("OnClick", function(self)
                local d = self.def
                if d.cmd then
                    Party.Order(d.cmd)
                elseif d.toggle then
                    passiveOn = not passiveOn
                    W.SetTabSelected(self, passiveOn)
                    -- one flag for the whole group, so the order ignores the scope (like grind)
                    CmdAll(passiveOn and "co +passive" or "co -passive")
                elseif d.menu then
                    d.menu(self)
                end
            end)
            if o.toggle then
                passiveButton = b
            elseif o.scope then
                scopeButton = b
            end
            orderButtons[#orderButtons + 1] = b
            orderItems[#orderItems + 1] = { w = b, gap = 3 }
        end
    end
end

-- Positions the strip left to right (the scope button changes width with its label).
LayoutOrders = function()
    W.FitTab(scopeButton, Party.ScopeLabel(Party.Scope()) .. W.CARET, 40, 150)
    W.SetTabSelected(scopeButton, Party.Scope() ~= "all")
    local x = 8
    for _, it in ipairs(orderItems) do
        it.w:ClearAllPoints()
        if it.sep then
            it.w:SetPoint("LEFT", orders, "LEFT", x + 2, 0)
            x = x + 6
        else
            it.w:SetPoint("LEFT", orders, "LEFT", x, 0)
            x = x + (it.fs and it.w:GetStringWidth() or it.w:GetWidth()) + it.gap
        end
    end
end
LayoutOrders()

-- The strip's "Passive" follows the selected bot's STYLE (the flag is the same for the whole group).
function Party.SyncPassive(low)
    if low ~= cur then
        return
    end
    local st = BT.styles and BT.styles[low]
    if not st or not st.toggles then
        return
    end
    for _, t in ipairs(st.toggles) do
        if t.key == "passive" then
            passiveOn = t.on and true or false
            W.SetTabSelected(passiveButton, passiveOn)
            return
        end
    end
end

-- ---------------------------------------------------------------- pull card (multibot-gap P5)
-- A small card under the "Pull" button: wait slider (PULL wait) and presets (PULL preset; a preset also
-- switches focus / the target choice of the scope on the server). Uses the strip's scope. Focus and the
-- target choice of one bot are on its Style tab (party-ui-audit 2.2).

local PULL_W = 350
local PULL_PRESETS_MAX = 6
local PULL_WAIT_MAX = 10            -- catalog.pull.waitMax of the server
local pull = CreateFrame("Frame", nil, frame)
Party.pullCard = pull
pull:SetWidth(PULL_W)
pull:SetHeight(130)
pull:SetFrameStrata("DIALOG")
pull:EnableMouse(true)
W.Panel(pull, { 0.07, 0.055, 0.04, 0.97 }, W.GOLD_DIM)
pull:Hide()

local pullUi = { presets = {} }
Party.pullUi = pullUi
local sliderLock = false

pullUi.title = W.Text(pull, "GameFontNormal", W.GOLD)
pullUi.title:SetPoint("TOPLEFT", 12, -10)
pullUi.title:SetPoint("RIGHT", -30, 0)
pullUi.title:SetHeight(14)
pullUi.close = W.CloseSmall(pull, nil, 16)
pullUi.close:SetPoint("TOPRIGHT", -8, -8)
pullUi.close:SetScript("OnClick", function()
    pull:Hide()
end)

pullUi.waitText = W.Text(pull, "GameFontHighlightSmall", W.TEXT)
pullUi.waitText:SetPoint("TOPLEFT", 12, -32)
pullUi.slider = CreateFrame("Slider", "BotTacticsPullSlider", pull, "OptionsSliderTemplate")
pullUi.slider:SetWidth(PULL_W - 36)
pullUi.slider:SetHeight(16)
pullUi.slider:SetPoint("TOPLEFT", 18, -50)
pullUi.slider:SetMinMaxValues(0, PULL_WAIT_MAX)
pullUi.slider:SetValueStep(1)
do
    local low, high, text = _G["BotTacticsPullSliderLow"], _G["BotTacticsPullSliderHigh"], _G["BotTacticsPullSliderText"]
    if low then low:SetText("0") end
    if high then high:SetText(tostring(PULL_WAIT_MAX)) end
    if text then text:SetText("") end
end
pullUi.slider.tooltipText = L.pullWaitTip

local function SetWaitText(n)
    pullUi.waitText:SetText(string.format(L.pullWait, n or 0))
end

-- slider moved by the player: show the number now, send once it rests for half a second
function Party.PullWaitChanged(value)
    local n = math.floor((tonumber(value) or 0) + 0.5)
    n = math.max(0, math.min(PULL_WAIT_MAX, n))
    pullUi.wait = n
    SetWaitText(n)
    if sliderLock then
        return
    end
    local scope = Party.Scope()
    BT.After("pullwait", 0.5, function()
        P.Pull(scope, "wait", n)
    end)
end
pullUi.slider:SetScript("OnValueChanged", function(_, value)
    Party.PullWaitChanged(value)
end)

pullUi.presetLabel = W.Text(pull, "GameFontNormalSmall", W.GOLD_DIM)
pullUi.presetLabel:SetPoint("TOPLEFT", 12, -84)
pullUi.presetLabel:SetText(L.pullPresets)
for i = 1, PULL_PRESETS_MAX do
    local b = W.Tab(pull, 20)
    b:SetScript("OnClick", function(self)
        Party.PullPreset(self.preset)
    end)
    b:Hide()
    pullUi.presets[i] = b
end

-- Presets: the server's (PULLSET) or the local table.
local function PullPresets()
    local ps = BT.pullSet
    if ps and ps.presets and #ps.presets > 0 then
        return ps.presets
    end
    return L.pullPresetList
end

function Party.PullPreset(p)
    if not p then
        return
    end
    if p.wait then
        sliderLock = true
        pullUi.slider:SetValue(p.wait)
        sliderLock = false
        pullUi.wait = p.wait
    end
    BT.Cancel("pullwait")
    P.Pull(Party.Scope(), "preset", p.id)
    Party.RenderPull()
end

-- Card height follows the preset rows (party-ui-audit 2.1).
function Party.RenderPull()
    local ps = BT.pullSet
    pullUi.title:SetText(L.pullTitle .. L.dot .. Party.ScopeLabel(Party.Scope()))
    if pullUi.wait == nil and ps and ps.wait then
        pullUi.wait = ps.wait
        sliderLock = true
        pullUi.slider:SetValue(ps.wait)
        sliderLock = false
    end
    SetWaitText(pullUi.wait or 0)
    local list = PullPresets()
    local x, y = 12, -100
    for i, b in ipairs(pullUi.presets) do
        local p = list[i]
        b.preset = p
        if p then
            W.FitTab(b, BT.Show(p.label), 50, PULL_W - 24)
            b.tip = (p.hint and p.hint ~= "") and BT.Show(p.hint) or nil
            if x > 12 and x + b:GetWidth() > PULL_W - 12 then
                x = 12
                y = y - 22
            end
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", pull, "TOPLEFT", x, y)
            W.SetTabSelected(b, ps ~= nil and ps.preset == p.id)
            b:Show()
            x = x + b:GetWidth() + 3
        else
            b:Hide()
        end
    end
    pull:SetHeight(-y + 20 + 12)
end

function Party.TogglePull(anchor)
    if pull:IsShown() then
        pull:Hide()
        return
    end
    CloseDropDownMenus()
    pull:ClearAllPoints()
    pull:SetPoint("TOPLEFT", anchor or orders, "BOTTOMLEFT", 0, -2)
    Party.RenderPull()
    pull:Show()
    P.RequestPullSet()
end

-- ---------------------------------------------------------------- roster

local roster = CreateFrame("Frame", nil, frame)
roster:SetPoint("TOPLEFT", 16, TOP_Y)
roster:SetPoint("BOTTOMLEFT", 16, 16)
roster:SetWidth(ROSTER_W)
W.Panel(roster, { 0.13, 0.10, 0.07, 0.9 }, W.LINE)
roster.offset = 0
local LIST_H = HEIGHT + TOP_Y - 16 - 6 - MORE_H - 4

local rosterRows = {}
local rosterEntries = {}

local function RowMenu(row)
    local e = row.entry
    if not e or not e.b then
        return
    end
    local b = e.b
    local fav = Party.IsFavorite(b.name)
    local items = {
        { text = BT.Show(b.name), isTitle = true, notCheckable = true },
        { text = fav and L.favDel or L.favAdd, notCheckable = true, func = function()
            CloseDropDownMenus()
            Party.ToggleFavorite(b.name)
        end },
    }
    if e.kind == "party" then
        items[#items + 1] = { text = L.summon, notCheckable = true, func = function()
            CloseDropDownMenus()
            Party.Cmd(b.low, "summon")
        end }
        items[#items + 1] = { text = L.trade, notCheckable = true, func = function()
            CloseDropDownMenus()
            Party.Trade(b.low)
        end }
        items[#items + 1] = { text = L.kick, notCheckable = true, func = function()
            CloseDropDownMenus()
            UninviteUnit(b.name)
        end }
    end
    local a = AcctBot(b.low)
    if e.kind == "party" or (a and a.state == 1) then
        items[#items + 1] = { text = L.logout, notCheckable = true, func = function()
            CloseDropDownMenus()
            P.Send("LOGOUT", BT.GuidField(b.low))
        end }
    elseif a and a.state == 0 then
        items[#items + 1] = { text = L.pillLogin, notCheckable = true, func = function()
            CloseDropDownMenus()
            P.Send("LOGIN", BT.GuidField(b.low))
        end }
    end
    W.ShowMenu(row, items)
end

local function PillClick(self)
    local row = self.row
    local e = row and row.entry
    local a = e and e.b
    if not a then
        return
    end
    if a.state == 1 then
        InviteUnit(a.name)
    elseif a.state == 0 then
        P.Send("LOGIN", a.id or BT.GuidField(a.low))
        Party.SetStatus(a.low, L.botsLoading, "busy")
    end
end

local function CreateRosterRow()
    local b = CreateFrame("Button", nil, roster)
    b:SetWidth(ROSTER_W - 12)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    W.Panel(b, { 0.17, 0.13, 0.09, 0 }, { 0, 0, 0, 0 })
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("LEFT", 5, 0)
    b.name = W.Text(b, "GameFontNormalSmall")
    b.name:SetHeight(12)
    b.sub = W.Text(b, "GameFontHighlightSmall", W.MUTED)
    b.sub:SetHeight(11)
    b.head = W.Text(b, "GameFontNormalSmall", W.GOLD_DIM)
    b.head:SetPoint("LEFT", 4, -2)
    b.head:SetPoint("RIGHT", -4, 0)
    b.barBg = b:CreateTexture(nil, "ARTWORK")
    b.barBg:SetTexture(0.04, 0.03, 0.02, 1)
    b.barBg:SetHeight(4)
    b.barBg:SetPoint("BOTTOMLEFT", 42, 6)
    b.barBg:SetPoint("RIGHT", -8, 0)
    b.bar = b:CreateTexture(nil, "OVERLAY")
    b.bar:SetTexture(0.25, 0.82, 0.31, 1)
    b.bar:SetHeight(4)
    b.bar:SetPoint("TOPLEFT", b.barBg, "TOPLEFT", 0, 0)
    b.pill = CreateFrame("Button", nil, b)
    b.pill.row = b
    b.pill:SetHeight(16)
    b.pill:SetPoint("RIGHT", -4, 0)
    W.Panel(b.pill, { 0.10, 0.08, 0.05, 0.9 }, W.LINE)
    b.pill.text = W.Text(b.pill, "GameFontHighlightSmall", W.MUTED, "CENTER")
    b.pill.text:SetPoint("CENTER")
    b.pill:SetScript("OnClick", PillClick)
    b.pill:SetScript("OnEnter", function(self)
        if self.tip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.tip, 1, 1, 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    b.pill:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    b:SetScript("OnClick", function(self, button)
        local e = self.entry
        if not e then
            return
        end
        if e.kind == "sect" and e.toggle then
            BotTacticsDB.rosterClosed = not BotTacticsDB.rosterClosed
            if not BotTacticsDB.rosterClosed then
                P.RequestBots()
            end
            Party.RenderRoster()
        elseif e.kind == "add" then
            BotTacticsDB.rosterClosed = false
            P.RequestBots()
            Party.RenderRoster()
        elseif e.b then
            if button == "RightButton" then
                RowMenu(self)
            else
                Party.Select(e.b.low)
            end
        end
    end)
    b:EnableMouseWheel(true)
    b:SetScript("OnMouseWheel", function(_, delta)
        Party.ScrollRoster(delta)
    end)
    return b
end

local function RosterRow(i)
    local r = rosterRows[i]
    if not r then
        r = CreateRosterRow()
        rosterRows[i] = r
    end
    return r
end

-- Flat list: "In group" section, party bots, "My bots" section (collapsible), account bots not in
-- the group (favourites first), "+ Call a bot" when the list is collapsed.
local function BuildEntries()
    local out = {}
    out[#out + 1] = { kind = "sect", text = L.inGroup }
    for _, b in ipairs(BT.party) do
        out[#out + 1] = { kind = "party", b = b }
    end
    if #BT.party == 0 then
        out[#out + 1] = { kind = "empty", text = BT.gotParty and L.noGroupBots or L.waiting }
    end
    local closed = BotTacticsDB and BotTacticsDB.rosterClosed
    out[#out + 1] = { kind = "sect", text = L.myBots, toggle = true, closed = closed }
    if closed then
        out[#out + 1] = { kind = "add" }
        return out
    end
    local fav, rest = {}, {}
    for _, a in ipairs(BT.acct) do
        if a.state ~= 3 and not BT.bots[a.low] then
            if Party.IsFavorite(a.name) then
                fav[#fav + 1] = a
            else
                rest[#rest + 1] = a
            end
        end
    end
    for _, a in ipairs(fav) do
        out[#out + 1] = { kind = "acct", b = a, fav = true }
    end
    for _, a in ipairs(rest) do
        out[#out + 1] = { kind = "acct", b = a }
    end
    if #fav + #rest == 0 then
        out[#out + 1] = { kind = "empty", text = BT.gotBots and L.noAcctBots or L.botsLoading }
    end
    return out
end

-- Second line of a roster row; account bots put the level first (it matters more when calling one).
local function Sub(b, extra, levelFirst)
    local lvl, cls = string.format(L.lvl, b.level or 1), BT.ClassName(b.class)
    local s = levelFirst and (lvl .. L.dot .. cls) or (cls .. L.dot .. lvl)
    if extra and extra ~= "" then
        s = s .. L.dot .. extra
    end
    return s
end

local function RenderHp(row)
    local e = row.entry
    if not e or e.kind ~= "party" then
        return
    end
    local hp, dead = Health(e.b)
    local w = (ROSTER_W - 12 - 42 - 8) * math.max(0, math.min(1, hp))
    row.bar:SetWidth(math.max(1, w))
    if dead then
        row.bar:SetTexture(0.4, 0.4, 0.4, 1)
    else
        row.bar:SetTexture(0.25, 0.82, 0.31, 1)
    end
    W.Show(row.bar, hp > 0 and not dead)
    row.icon:SetDesaturated(dead)
    if dead then
        row.name:SetTextColor(0.5, 0.5, 0.5)
    else
        row.name:SetTextColor(BT.ClassColor(e.b.class))
    end
end

local function LayoutRow(row, e)
    local h = ROW_H[e.kind]
    row:SetHeight(h)
    row.entry = e
    row.icon:Hide()
    row.name:Hide()
    row.sub:Hide()
    row.head:Hide()
    row.bar:Hide()
    row.barBg:Hide()
    row.pill:Hide()
    row:SetBackdropColor(0, 0, 0, 0)
    row:SetBackdropBorderColor(0, 0, 0, 0)
    if e.kind == "sect" then
        local t = e.text
        if e.toggle then
            t = t .. (e.closed and "  +" or "  -")
        end
        row.head:SetText(t)
        W.Color(row.head, W.GOLD_DIM)
        row.head:Show()
        return
    elseif e.kind == "empty" then
        row.head:SetText(e.text)
        W.Color(row.head, W.FAINT)
        row.head:Show()
        return
    elseif e.kind == "add" then
        row.head:SetText(L.callBot)
        W.Color(row.head, W.GOLD)
        row.head:Show()
        row:SetBackdropBorderColor(0.35, 0.29, 0.18, 1)
        return
    end
    local b = e.b
    local big = e.kind == "party"
    local size = big and 32 or 24
    row.icon:SetWidth(size)
    row.icon:SetHeight(size)
    SetClassIcon(row.icon, b.class)
    row.icon:SetDesaturated(false)
    row.icon:Show()
    local nameText = BT.Show(b.name)
    if Party.IsFavorite(b.name) then
        nameText = STAR .. " " .. nameText
    end
    row.name:ClearAllPoints()
    row.sub:ClearAllPoints()
    local left = size + 10
    row.name:SetPoint("TOPLEFT", left, big and -5 or -3)
    row.sub:SetPoint("TOPLEFT", left, big and -18 or -16)
    row.name:SetTextColor(BT.ClassColor(b.class))
    row.name:Show()
    row.sub:Show()
    -- one line each: a long name or class is cut with "...", never wrapped (party-ui-audit 3.1)
    local textW = ROSTER_W - 12 - left - 4
    if big then
        row.name:SetPoint("RIGHT", -4, 0)
        row.sub:SetPoint("RIGHT", -4, 0)
        W.FitText(row.name, nameText, textW, row)
        W.FitText(row.sub, Sub(b, RoleLabel(b.role)), textW, row)
        row.barBg:Show()
        row.bar:Show()
        RenderHp(row)
    else
        local pill, color, enabled, tip
        if b.state == 1 then
            pill, color, enabled, tip = L.pillCall, W.OWN, true, L.pillCallTip
        elseif b.state == 0 then
            pill, color, enabled, tip = L.pillLogin, W.OWN, true, L.pillLoginTip
        else
            pill, color, enabled = L.pillBusy, W.FAINT, false
        end
        row.pill.text:SetText(pill)
        row.pill.tip = tip
        W.Color(row.pill.text, color)
        local pw = row.pill.text:GetStringWidth() + 14
        row.pill:SetWidth(pw)
        W.Enable(row.pill, enabled)
        row.pill:Show()
        row.name:SetPoint("RIGHT", row.pill, "LEFT", -4, 0)
        row.sub:SetPoint("RIGHT", row.pill, "LEFT", -4, 0)
        textW = textW - pw - 4
        W.FitText(row.name, nameText, textW, row)
        W.FitText(row.sub, Sub(b, nil, true), textW, row)
        if b.state ~= 1 then
            row.name:SetTextColor(0.6, 0.6, 0.6)
            row.icon:SetDesaturated(true)
        end
    end
    if b.low == cur then
        row:SetBackdropColor(0.17, 0.13, 0.09, 0.95)
        row:SetBackdropBorderColor(W.GOLD_DIM[1], W.GOLD_DIM[2], W.GOLD_DIM[3], 1)
    end
end

function Party.RenderRoster()
    rosterEntries = BuildEntries()
    local n = #rosterEntries
    if roster.offset > n - 1 then
        roster.offset = math.max(0, n - 1)
    end
    local y, used = 6, 0
    for i = roster.offset + 1, n do
        local e = rosterEntries[i]
        local h = ROW_H[e.kind]
        if y + h > LIST_H + 6 then
            break
        end
        used = used + 1
        local row = RosterRow(used)
        LayoutRow(row, e)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 6, -y)
        row:Show()
        y = y + h + 2
    end
    for i = used + 1, #rosterRows do
        rosterRows[i].entry = nil
        rosterRows[i]:Hide()
    end
    -- the list scrolls with the wheel; the line under it says so (party-ui-audit 3.2)
    local below = n - roster.offset - used
    if below > 0 then
        roster.more.text:SetText(string.format(L.rosterMore, below) .. W.CARET)
        roster.more:Show()
    else
        roster.more:Hide()
    end
end

function Party.ScrollRoster(delta)
    local n = #rosterEntries
    roster.offset = math.max(0, math.min(math.max(0, n - 4), roster.offset - delta))
    Party.RenderRoster()
end

roster:EnableMouseWheel(true)
roster:SetScript("OnMouseWheel", function(_, delta)
    Party.ScrollRoster(delta)
end)

-- Roster row of a party bot (fired-rule float anchor, Feedback.lua).
function Party.RosterButton(low)
    if not frame:IsShown() then
        return nil
    end
    for _, row in ipairs(rosterRows) do
        local e = row.entry
        if row:IsShown() and e and e.kind == "party" and e.b.low == low then
            return row
        end
    end
    return nil
end

roster.more = CreateFrame("Button", nil, roster)
roster.more:SetHeight(MORE_H)
roster.more:SetPoint("BOTTOMLEFT", 6, 6)
roster.more:SetPoint("BOTTOMRIGHT", -6, 6)
roster.more.text = W.Text(roster.more, "GameFontDisableSmall", W.MUTED, "CENTER")
roster.more.text:SetAllPoints(roster.more)
roster.more:SetScript("OnClick", function()
    Party.ScrollRoster(-3)
end)
roster.more:EnableMouseWheel(true)
roster.more:SetScript("OnMouseWheel", function(_, delta)
    Party.ScrollRoster(delta)
end)
roster.more:Hide()

-- ---------------------------------------------------------------- header of the selected bot

local head = CreateFrame("Frame", nil, frame)
head:SetPoint("TOPLEFT", MAIN_X, TOP_Y)
head:SetWidth(MAIN_W)
head:SetHeight(44)

local portrait = head:CreateTexture(nil, "ARTWORK")
portrait:SetWidth(40)
portrait:SetHeight(40)
portrait:SetPoint("LEFT", 0, 0)

local headName = W.Text(head, "GameFontNormalLarge")
headName:SetPoint("TOPLEFT", 48, -3)
headName:SetHeight(18)
local headSub = W.Text(head, "GameFontHighlightSmall", W.MUTED)
headSub:SetPoint("TOPLEFT", 48, -25)
headSub:SetHeight(12)

-- Quick actions of the selected bot (party-ui-audit 6.4): three flat buttons and "More" with the rest;
-- the Other tab no longer repeats them.
function Party.Trade(low)
    local unit = Party.Unit(low)
    if unit and CheckInteractDistance(unit, TRADE_RANGE) then
        InitiateTrade(unit)
    else
        Party.SetStatus(low, L.tooFar, "err")
    end
end

-- Items of the header's "More" menu for bot `low` (a party bot of the player).
function Party.BotItems(low)
    local b = PartyBot(low)
    if not b then
        return {}
    end
    local function Do(fn)
        return function()
            CloseDropDownMenus()
            fn()
        end
    end
    local fav = Party.IsFavorite(b.name)
    return {
        { text = BT.Show(b.name), isTitle = true, notCheckable = true },
        { text = L.repair, notCheckable = true, tooltipTitle = L.repair, tooltipText = L.repairTip,
          func = Do(function() Party.Cmd(low, "repair") end) },
        { text = L.openItems, notCheckable = true, tooltipTitle = L.openItems, tooltipText = L.openItemsTip,
          func = Do(function() Party.Cmd(low, "open items") end) },
        { text = L.resetAI, notCheckable = true, func = Do(function() Party.Cmd(low, "reset botAI") end) },
        -- "reset" (PlayerbotAI::HandleCommand): drops the current actions, keeps the strategies
        { text = L.resetActions, notCheckable = true, tooltipTitle = L.resetActions, tooltipText = L.resetActionsTip,
          func = Do(function() Party.Cmd(low, "reset") end) },
        { text = fav and L.favDel or L.favAdd, notCheckable = true,
          func = Do(function() Party.ToggleFavorite(b.name) end) },
        { text = L.kick, notCheckable = true, func = Do(function() UninviteUnit(b.name) end) },
        { text = L.logout, notCheckable = true, func = Do(function() P.Send("LOGOUT", BT.GuidField(low)) end) },
    }
end

local quick = {}
local function QuickButton(text, fn, tip)
    local b = W.Tab(head, 22)
    W.FitTab(b, text, 50, 130)
    b.tip = tip
    b:SetScript("OnClick", fn)
    quick[#quick + 1] = b
    return b
end

local moreButton = QuickButton(L.headMore .. W.CARET, function(self)
    if PartyBot(cur) then
        W.ShowMenu(self, Party.BotItems(cur))
    end
end, L.headMoreTip)
local maintButton = QuickButton(L.maintenance, function()
    Party.Cmd(cur, "maintenance")
end, L.maintNote)
local tradeButton = QuickButton(L.trade, function()
    Party.Trade(cur)
end)
local summonButton = QuickButton(L.summon, function()
    Party.Cmd(cur, "summon")
end)
moreButton:SetPoint("RIGHT", 0, 0)
maintButton:SetPoint("RIGHT", moreButton, "LEFT", -3, 0)
tradeButton:SetPoint("RIGHT", maintButton, "LEFT", -3, 0)
summonButton:SetPoint("RIGHT", tradeButton, "LEFT", -3, 0)
headName:SetPoint("RIGHT", summonButton, "LEFT", -8, 0)
headSub:SetPoint("RIGHT", summonButton, "LEFT", -8, 0)
-- room of the name / subline left of the quick buttons; a cut one is the tooltip of the name area
local HEAD_TEXT_W = MAIN_W - 48 - 8 - (summonButton:GetWidth() + tradeButton:GetWidth() + maintButton:GetWidth()
    + moreButton:GetWidth() + 9)
Party.HEAD_TEXT_W = HEAD_TEXT_W
local headZone = TipZone(head)
headZone:SetPoint("TOPLEFT", head, "TOPLEFT", 48, 0)
headZone:SetPoint("BOTTOM", head, "BOTTOM", 0, 0)
headZone:SetPoint("RIGHT", summonButton, "LEFT", -8, 0)

local function EnableQuick(on)
    for _, b in ipairs(quick) do
        W.Enable(b, on)
        b:SetAlpha(on and 1 or 0.45)
    end
end

local function RenderHeader()
    local e = Entry(cur)
    if not e then
        portrait:Hide()
        W.FitText(headName, BT.gotParty and L.selectBot or L.waiting, HEAD_TEXT_W, headZone)
        headName:SetTextColor(W.MUTED[1], W.MUTED[2], W.MUTED[3])
        W.FitText(headSub, "", HEAD_TEXT_W, headZone)
        EnableQuick(false)
        return
    end
    portrait:Show()
    local unit = BT.UnitByLow(cur)
    if unit then
        portrait:SetTexCoord(0, 1, 0, 1)
        SetPortraitTexture(portrait, unit)
    else
        SetClassIcon(portrait, e.class)
    end
    W.FitText(headName, BT.Show(e.name), HEAD_TEXT_W, headZone)
    headName:SetTextColor(BT.ClassColor(e.class))
    local parts = { BT.ClassName(e.class), string.format(L.levelLong, e.level or 1) }
    local pb = PartyBot(cur)
    local role = pb and RoleLabel(pb.role)
    if role then
        parts[#parts + 1] = role
    end
    local a = AcctBot(cur)
    if not pb and a then
        if a.state == 0 then
            parts[#parts + 1] = L.notInGame
        elseif a.state == 2 then
            parts[#parts + 1] = L.inUse
        end
    end
    W.FitText(headSub, table.concat(parts, L.dot), HEAD_TEXT_W, headZone)
    EnableQuick(pb ~= nil)
end

-- ---------------------------------------------------------------- tab bar, status line, content

local tabBar = CreateFrame("Frame", nil, frame)
tabBar:SetPoint("TOPLEFT", MAIN_X, TABS_Y)
tabBar:SetWidth(MAIN_W)
tabBar:SetHeight(24)
local tabLine = tabBar:CreateTexture(nil, "ARTWORK")
tabLine:SetTexture(W.LINE[1], W.LINE[2], W.LINE[3], 1)
tabLine:SetHeight(1)
tabLine:SetPoint("BOTTOMLEFT", 0, -1)
tabLine:SetPoint("BOTTOMRIGHT", 0, -1)

local statusText = W.Text(frame, "GameFontHighlightSmall", W.MUTED)
statusText:SetPoint("TOPLEFT", MAIN_X + 4, STATUS_Y)
statusText:SetWidth(MAIN_W - 8)
statusText:SetHeight(14)
local statusZone = TipZone(frame)
statusZone:SetPoint("TOPLEFT", statusText, "TOPLEFT", 0, 0)
statusZone:SetPoint("BOTTOMRIGHT", statusText, "BOTTOMRIGHT", 0, 0)

local content = CreateFrame("Frame", nil, frame)
content:SetPoint("TOPLEFT", MAIN_X, CONTENT_Y)
content:SetPoint("BOTTOMRIGHT", -16, 16)
Party.content = content
Party.CONTENT_W = MAIN_W
Party.CONTENT_H = HEIGHT + CONTENT_Y - 16

local function LayoutTabs()
    local x = 0
    for _, t in ipairs(tabs) do
        W.FitTab(t.button, t.label, 70, 150)
        t.button:ClearAllPoints()
        t.button:SetPoint("BOTTOMLEFT", tabBar, "BOTTOMLEFT", x, 0)
        W.SetTabSelected(t.button, t == curTab)
        t.button:Show()
        x = x + t.button:GetWidth() + 3
    end
end

local function RenderStatus()
    local st, g = statusBy[cur or -1], statusBy[0]
    if g and (not st or g.at > st.at) then
        st = g
    end
    if not st then
        W.FitText(statusText, "", MAIN_W - 8, statusZone)
        return
    end
    W.FitText(statusText, BT.Show(st.text), MAIN_W - 8, statusZone)
    if st.kind == "err" then
        W.Color(statusText, W.RED)
    elseif st.kind == "ok" then
        W.Color(statusText, W.OWN)
    else
        W.Color(statusText, W.MUTED)
    end
end

-- ---------------------------------------------------------------- public API (6.2)

-- Registers a tab; returns its pane (child of the content area, hidden). onShow(low, pane) runs when
-- the tab is shown or another bot is selected while it is shown; onHide(low, pane) when it is left;
-- onData(what, bot, ...) (5th argument or pane.onData) after every protocol data change.
function Party.RegisterTab(id, label, onShow, onHide, onData)
    if tabById[id] then
        return tabById[id].pane
    end
    local pane = CreateFrame("Frame", nil, content)
    pane:SetAllPoints(content)
    pane:Hide()
    local t = { id = id, label = label or id, pane = pane, onShow = onShow, onHide = onHide, onData = onData }
    t.button = W.Tab(tabBar, 24)
    t.button.tabId = id
    t.button:SetScript("OnClick", function(self)
        Party.SelectTab(self.tabId)
    end)
    tabById[id] = t
    tabs[#tabs + 1] = t
    table.sort(tabs, function(a, b)
        return (TAB_ORDER[a.id] or 100) < (TAB_ORDER[b.id] or 100)
    end)
    LayoutTabs()
    return pane
end

function Party.CurrentTab()
    return curTab and curTab.id
end

function Party.SelectTab(id)
    local t = tabById[id]
    if not t then
        return
    end
    if curTab == t then
        if not t.pane:IsShown() then
            t.pane:Show()
        end
        return
    end
    local old = curTab
    CloseDropDownMenus()
    if old then
        old.pane:Hide()
        if old.onHide then
            old.onHide(cur, old.pane)
        end
    end
    curTab = t
    if BotTacticsDB then
        BotTacticsDB.lastTab = id
    end
    t.pane:Show()
    LayoutTabs()
    if frame:IsShown() and t.onShow then
        t.onShow(cur, t.pane)
    end
end

function Party.Current()
    return cur
end

function Party.Unit(low)
    return BT.UnitByLow(low or cur)
end

-- True when the bot is one of the player's bots in the group (the server accepts requests for it).
function Party.IsOwned(low)
    return PartyBot(low or cur) ~= nil
end

function Party.OnSelect(fn)
    selectHooks[#selectHooks + 1] = fn
end

function Party.Select(low)
    if low ~= cur then
        CloseDropDownMenus()
    end
    cur = low
    for _, fn in ipairs(selectHooks) do
        fn(low)
    end
    if frame:IsShown() then
        Party.RenderRoster()
        RenderHeader()
        RenderStatus()
        if curTab and curTab.onShow then
            curTab.onShow(low, curTab.pane)
        end
    end
end

-- Shared status line under the tabs; low 0 = group-level. kind: "ok" | "err" | "busy".
function Party.SetStatus(low, text, kind)
    low = low or 0
    local st = { text = text or "", kind = kind or "busy", at = GetTime() }
    statusBy[low] = st
    BT.After("pstatus" .. low, STATUS_TIME, function()
        if statusBy[low] == st then
            statusBy[low] = nil
            RenderStatus()
        end
    end)
    RenderStatus()
end

-- Widget lists for the mock tests (scratchpad bt_test).
function Party.RosterRowsForTest()
    return rosterRows
end

function Party.OrderButtonsForTest()
    return orderButtons
end

function Party.HeaderForTest()
    return { summon = summonButton, trade = tradeButton, maint = maintButton, more = moreButton, roster = roster,
        name = headName, sub = headSub, zone = headZone, status = statusText, statusZone = statusZone,
        titleZone = titleZone }
end

-- Layout of the strip and the tab bar for the layout test: items in order { w = widget, fs, sep, gap }.
function Party.LayoutForTest()
    local tabButtons = {}
    for _, t in ipairs(tabs) do
        tabButtons[#tabButtons + 1] = t.button
    end
    return { orderItems = orderItems, ordersW = WIDTH - 28, tabs = tabButtons, mainW = MAIN_W, rosterW = ROSTER_W }
end

-- Current status entry { text, kind, at } of a bot (0 = group), or nil.
function Party.GetStatus(low)
    return statusBy[low or 0]
end

function Party.Refresh()
    if not frame:IsShown() then
        return
    end
    Party.RenderRoster()
    RenderHeader()
    RenderStatus()
    Party.SyncPassive(cur)
    W.SetTabSelected(passiveButton, passiveOn)
    LayoutOrders()
end

-- Selection after a data change: keep a bot that still exists, else the first party bot.
local function EnsureSelection()
    if cur and Entry(cur) then
        return
    end
    local first = BT.party[1]
    if first then
        Party.Select(first.low)
    elseif cur and BT.gotParty and BT.gotBots then
        Party.Select(nil)
    end
end

-- A bot that newly joined gets the stored group settings (party-window-spec 5.8).
local knownParty
local function CheckNewMembers()
    local now, fresh = {}, false
    for _, b in ipairs(BT.party) do
        now[b.low] = true
        if knownParty and not knownParty[b.low] then
            fresh = true
        end
    end
    knownParty = now
    local gs = BT.groupSet
    if fresh and gs then
        if gs.formation ~= "" then
            SetGroup("formation", gs.formation)
        end
        if gs.rti ~= "" then
            SetGroup("rti", gs.rti)
        end
    end
end

-- Protocol data change (via BT.Editor.OnData): roster/header, then the current tab.
function Party.OnData(what, bot, ...)
    if what == "party" then
        CheckNewMembers()
        EnsureSelection()
    elseif what == "bots" then
        EnsureSelection()
    elseif what == "pullset" then
        if not pull:IsShown() then
            pullUi.wait = nil       -- take the stored wait the next time the card opens
        end
        LayoutOrders()
        if pull:IsShown() then
            Party.RenderPull()
        end
    end
    if not frame:IsShown() then
        return
    end
    Party.Refresh()
    local t = curTab
    local fn = t and (t.onData or t.pane.onData)
    if fn then
        fn(what, bot, ...)
    end
end

function Party.Toggle()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end

-- ---------------------------------------------------------------- open / close, live health

local ticker = CreateFrame("Frame", nil, frame)
ticker.t = 0
ticker:SetScript("OnUpdate", function(self, elapsed)
    self.t = self.t + (elapsed or 0)
    if self.t < HP_TICK then
        return
    end
    self.t = 0
    for _, row in ipairs(rosterRows) do
        if row:IsShown() then
            RenderHp(row)
        end
    end
end)

frame:SetScript("OnShow", function()
    PlaySound("igCharacterInfoOpen")
    P.Hello()
    P.RequestBots()
    BT.After("noServer", 5.5, function() Party.OnData("refresh") end)
    if not cur and BT.party[1] then
        cur = BT.party[1].low
    end
    Party.Refresh()
    if not curTab then
        local want = BotTacticsDB and BotTacticsDB.lastTab
        if not tabById[want or ""] then
            want = "tactics"
        end
        Party.SelectTab(want)
    else
        curTab.pane:Show()
        if curTab.onShow then
            curTab.onShow(cur, curTab.pane)
        end
    end
end)

frame:SetScript("OnHide", function()
    PlaySound("igCharacterInfoClose")
    CloseDropDownMenus()
    pull:Hide()
    if curTab and curTab.onHide then
        curTab.onHide(cur, curTab.pane)
    end
    P.UpdateWatch()
end)
