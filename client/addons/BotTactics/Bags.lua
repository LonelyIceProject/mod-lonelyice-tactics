-- Tab "Сумки и обмен" (party-window-spec 6.5): the bot's bags, keyring and bank as item buttons,
-- click modes, context menu, drag to move, sell grey, trade and bank cards. Data = BAGS (Protocol.lua).

local BT = BotTactics
local L, W, P = BT.L, BT.W, BT.Protocol
local Party = BT.Party
local S = BT.S

-- vendor card (party-extras-spec 6.3)
L.vendor = S("Vendor", "Торговец")
L.vendorNone = S("Walk the bot up to a vendor to buy or buy back items.", "Подведите бота к торговцу, чтобы покупать и выкупать вещи.")
L.vendorGoods = S("Goods", "Товары")
L.vendorBuyback = S("Buyback", "Выкуп")
L.vendorEmpty = S("Nothing to show", "Пусто")
L.vendorUnlimited = S("unlimited", "без ограничений")
L.vendorStock = S("%d in stock", "в наличии: %d")
L.vendorSpecial = S("Special currency - not supported", "За особую валюту - не поддерживается")
L.vendorBuyTip = S("Click: buy 1. Shift-click: choose the amount.", "Клик: купить 1. Shift-клик: выбрать количество.")
L.vendorCount = S("How many stacks of %s?", "Сколько стопок «%s»?")
L.vendorBuybackTip = S("Click: buy back for %s", "Клик: выкупить за %s")
L.nearby = S("Next to the bot", "Рядом с ботом")
L.tradeOpenShort = S("Open trade", "Открыть обмен")
L.tradeCanOpen = S("can open", "можно открыть")

local B = {}
BT.Bags = B

BT.vendor = BT.vendor or {}     -- low -> { npc, rows = { {slot, entry, price, count, ext}, ... }, trunc }
BT.buyback = BT.buyback or {}   -- low -> { {slot, entry, count, price}, ... }

local CELL = 37
local GAP = 3
-- one column of bags, 8 cells a row; the side column gets the rest (party-ui-audit S1)
local PER_ROW = 8
local BOX_W = PER_ROW * CELL + (PER_ROW - 1) * GAP + 12
local BOX_GAP = 8
local COLS = 1
local SCROLL_W = COLS * BOX_W + (COLS - 1) * BOX_GAP
local TOP_H = 30
local BOTTOM_H = 32
local SIDE_X = SCROLL_W + 30
local SIDE_W = Party.CONTENT_W - SIDE_X
local REFRESH_EVERY = 20
local ACK_REFRESH = 0.8
local GIVE_WAIT = 3
local TRADE_RANGE = 2        -- CheckInteractDistance index 2: trade, 11.11 yd
local BUY_MAX = 20
local EMPTY_ICON = "Interface\\PaperDoll\\UI-Backpack-EmptySlot"
local SHOWN_KINDS = { B = true, G = true, K = true }
local BANK_KINDS = { N = true, H = true }

local MODES = {
    { id = "use", label = L.bmUse },
    { id = "equip", label = L.bmEquip },
    { id = "give", label = L.bmGive },
    { id = "sell", label = L.bmSell },
    { id = "destroy", label = L.bmDestroy },
    { id = "deposit", label = L.bmDeposit, bank = true },
    { id = "withdraw", label = L.bmWithdraw, bank = true },
}
local MODE_LABEL = {}
for _, m in ipairs(MODES) do
    MODE_LABEL[m.id] = m.label
end

local cur               -- bot shown
local tradeShown = false
local pendingGives = {} -- gives waiting for TRADE_SHOW: { bot, row, at }
local held              -- drag source cell
local cells = {}        -- every cell button created
local retries = 0
local vendorFollows       -- bot whose next BAGS is the follow-up of a BUY (the server sends VENDOR itself)

local pane = Party.RegisterTab("bags", L.tabBags,
    function(low) B.Show(low) end,
    function() B.Hide() end,
    function(what, bot, op, ok, code) B.OnData(what, bot, op, ok, code) end)
B.pane = pane

local body = CreateFrame("Frame", nil, pane)
body:SetAllPoints(pane)

local message = W.Text(pane, "GameFontNormal", W.MUTED, "CENTER")
message:SetPoint("CENTER", pane, "CENTER", 0, 40)
message:SetWidth(460)

-- ---------------------------------------------------------------- data helpers

local function Data()
    return cur and BT.bags[cur]
end

local function Mode()
    local m = BotTacticsDB and BotTacticsDB.bagMode or "use"
    local d = Data()
    if (m == "deposit" or m == "withdraw") and not (d and d.flag.b) then
        return "use"
    end
    return m
end

local function IsBankPos(bag, slot)
    return (bag == 255 and slot >= 39 and slot <= 66) or (bag >= 67 and bag <= 73)
end

local function Quality(row)
    local _, _, q = GetItemInfo(row.entry)
    return q
end

local function ItemText(row)
    local name, link = GetItemInfo(row.entry)
    local s = link or name or ("item #" .. row.entry)
    if (row.count or 1) > 1 then
        s = s .. " x" .. row.count
    end
    return s
end

local function TradeOpen()
    return tradeShown and TradeFrame and TradeFrame:IsShown() and true or false
end

-- ---------------------------------------------------------------- actions

local function SendItem(bot, op, row, a, b)
    P.Send("ITEM", bot, op, row.bag, row.slot, row.guid, a or 0, b or 0)
end

local function Give(row)
    local bot = cur
    if TradeOpen() then
        SendItem(bot, "give", row)
        return
    end
    local unit = Party.Unit(bot)
    if not unit or not CheckInteractDistance(unit, TRADE_RANGE) then
        Party.SetStatus(bot, L.tradeNear, "err")
        return
    end
    pendingGives[#pendingGives + 1] = { bot = bot, row = row, at = GetTime() }
    if #pendingGives == 1 then
        InitiateTrade(unit)
    end
    BT.After("bagsgive", GIVE_WAIT, function()
        pendingGives = {}
    end)
end

-- Runs one op on an item row (confirmations of 6.5: destroy always, sell of quality >= rare).
function B.DoOp(op, row)
    local bot = cur
    if not bot or not row then
        return
    end
    if op == "give" then
        Give(row)
    elseif op == "destroy" then
        BT.Confirm("destroy", string.format(L.confirmDestroy, ItemText(row)), function()
            SendItem(bot, "destroy", row)
        end)
    elseif op == "sell" and (Quality(row) or 0) >= 3 then
        BT.Confirm("sell", string.format(L.confirmSell, ItemText(row)), function()
            SendItem(bot, "sell", row)
        end)
    else
        SendItem(bot, op, row)
    end
end

local function ContextMenu(cell)
    local row = cell.row
    local d = Data()
    if not row or not d then
        return
    end
    local f = row.flag
    local items = { { text = ItemText(row), isTitle = true, notCheckable = true } }
    local function Add(op)
        items[#items + 1] = { text = MODE_LABEL[op], notCheckable = true, func = function()
            CloseDropDownMenus()
            B.DoOp(op, row)
        end }
    end
    if f.u then
        Add("use")
    end
    if #row.fits > 0 then
        Add("equip")
    end
    if not f.x then
        Add("give")
    end
    if f.p and not f.q and not f.k and not f.h then
        Add("sell")
    end
    if d.flag.b then
        if IsBankPos(row.bag, row.slot) then
            Add("withdraw")
        else
            Add("deposit")
        end
    end
    if not f.n and not f.e then
        Add("destroy")
    end
    W.ShowMenu(cell, items)
end

-- ---------------------------------------------------------------- top row: modes and money

local modeButtons = {}
for i, m in ipairs(MODES) do
    local b = W.Tab(body, 22)
    W.FitTab(b, m.label, 60, 130)
    b.mode = m.id
    b:SetScript("OnClick", function(self)
        BotTacticsDB.bagMode = self.mode
        B.Render()
    end)
    modeButtons[i] = b
end

local moneyText = W.Text(body, "GameFontHighlight", W.TEXT, "RIGHT")
moneyText:SetPoint("TOPRIGHT", -4, -4)
moneyText:SetWidth(180)

local function RenderModes(d)
    local x = 0
    local mode = Mode()
    for i, m in ipairs(MODES) do
        local b = modeButtons[i]
        if m.bank and not (d and d.flag.b) then
            b:Hide()
        else
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", x, 0)
            W.SetTabSelected(b, m.id == mode)
            b:Show()
            x = x + b:GetWidth() + 3
        end
    end
    moneyText:SetText(d and BT.Money(d.money) or "")
end

-- ---------------------------------------------------------------- scroll area with the bag boxes

local scroll = CreateFrame("ScrollFrame", "BotTacticsBagsScroll", body, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 0, -TOP_H)
scroll:SetWidth(SCROLL_W)
scroll:SetHeight(Party.CONTENT_H - TOP_H - BOTTOM_H)
local child = CreateFrame("Frame", nil, scroll)
child:SetWidth(SCROLL_W)
child:SetHeight(10)
scroll:SetScrollChild(child)

local boxes = {}

local function Box(i)
    local box = boxes[i]
    if not box then
        box = CreateFrame("Frame", nil, child)
        box:SetWidth(BOX_W)
        W.Panel(box, { 0.07, 0.055, 0.04, 0.95 }, W.LINE)
        box.title = W.Text(box, "GameFontNormalSmall", W.GOLD)
        box.title:SetPoint("TOPLEFT", 6, -5)
        box.title:SetWidth(BOX_W - 56)
        box.title:SetHeight(12)
        box.titleZone = W.TextZone(box, box.title)
        box.count = W.Text(box, "GameFontDisableSmall", W.FAINT, "RIGHT")
        box.count:SetPoint("TOPRIGHT", -6, -5)
        box.count:SetWidth(46)
        boxes[i] = box
    end
    return box
end

-- Cell under the cursor (drag target).
local function CellUnderCursor()
    for _, c in ipairs(cells) do
        if c:IsVisible() then
            if MouseIsOver then
                if MouseIsOver(c) then
                    return c
                end
            else
                local l, r, t, bm = c:GetLeft(), c:GetRight(), c:GetTop(), c:GetBottom()
                if l and r and t and bm then
                    local x, y = GetCursorPosition()
                    local s = c:GetEffectiveScale()
                    x, y = x / s, y / s
                    if x >= l and x <= r and y >= bm and y <= t then
                        return c
                    end
                end
            end
        end
    end
    return nil
end

local function CellEnter(self)
    local row = self.row
    if not row then
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(BT.ItemLink(row))
    GameTooltip:AddLine(string.format(L.clickDoes, MODE_LABEL[Mode()] or ""), W.MUTED[1], W.MUTED[2], W.MUTED[3])
    GameTooltip:Show()
end

local function CellClick(self, button)
    if not self.row then
        return
    end
    if button == "RightButton" then
        ContextMenu(self)
    else
        B.DoOp(Mode(), self.row)
    end
end

local function CellDragStart(self)
    if not self.row then
        return
    end
    GameTooltip:Hide()
    held = self
    self.heldTex:Show()
end

local function CellDragStop(self)
    local src = held
    held = nil
    self.heldTex:Hide()
    if not src or not src.row then
        return
    end
    local dst = CellUnderCursor()
    if dst and dst ~= src and cur then
        SendItem(cur, "move", src.row, dst.bag, dst.slot)
    end
end

-- Item button of a position; named BotTacticsBag<bag>_<slot> (ItemButtonTemplate needs a name).
local function Cell(bag, slot)
    local name = "BotTacticsBag" .. bag .. "_" .. slot
    local c = _G[name]
    if c and c.isBTCell then
        return c
    end
    c = CreateFrame("Button", name, child, "ItemButtonTemplate")
    c.isBTCell = true
    c.bag, c.slot = bag, slot
    c:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    c:RegisterForDrag("LeftButton")
    c.glow = c:CreateTexture(nil, "OVERLAY")
    c.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    c.glow:SetBlendMode("ADD")
    c.glow:SetWidth(66)
    c.glow:SetHeight(66)
    c.glow:SetPoint("CENTER", 0, 0)
    c.glow:Hide()
    c.heldTex = c:CreateTexture(nil, "OVERLAY")
    c.heldTex:SetTexture("Interface\\Buttons\\CheckButtonHilight")
    c.heldTex:SetBlendMode("ADD")
    c.heldTex:SetAllPoints(c)
    c.heldTex:Hide()
    c:SetScript("OnClick", CellClick)
    c:SetScript("OnEnter", CellEnter)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    c:SetScript("OnDragStart", CellDragStart)
    c:SetScript("OnDragStop", CellDragStop)
    cells[#cells + 1] = c
    return c
end

local function RenderCell(c, row)
    c.row = row
    if row then
        local _, _, q = GetItemInfo(row.entry)
        SetItemButtonTexture(c, GetItemIcon(row.entry) or BT.ICON_UNKNOWN)
        SetItemButtonCount(c, row.count or 1)
        if row.maxdur > 0 and row.dur < row.maxdur * 0.2 then
            SetItemButtonTextureVertexColor(c, 1, 0.3, 0.3)
        else
            SetItemButtonTextureVertexColor(c, 1, 1, 1)
        end
        if q and q >= 2 then
            local r, g, b = GetItemQualityColor(q)
            c.glow:SetVertexColor(r, g, b)
            c.glow:Show()
        else
            c.glow:Hide()
        end
        return q ~= nil
    end
    SetItemButtonTexture(c, EMPTY_ICON)
    SetItemButtonTextureVertexColor(c, 1, 1, 1)
    SetItemButtonCount(c, 0)
    c.glow:Hide()
    return true
end

local function BoxTitle(c)
    if c.kind == "B" then
        return L.backpack
    elseif c.kind == "K" then
        return L.keyring
    elseif c.kind == "N" then
        return L.bank
    end
    local name = c.entry > 0 and GetItemInfo(c.entry)
    return name or (c.kind == "H" and L.bankBag or L.bag)
end

local function RenderBoxes(d)
    local list = {}
    for _, c in ipairs(d.containers) do
        if SHOWN_KINDS[c.kind] or (BANK_KINDS[c.kind] and d.flag.b) then
            if c.size > 0 then
                list[#list + 1] = c
            end
        end
    end
    local used = {}
    local colH = {}
    for i = 1, COLS do
        colH[i] = 0
    end
    local complete = true
    for i, c in ipairs(list) do
        local box = Box(i)
        local nrows = math.ceil(c.size / PER_ROW)
        local h = 22 + nrows * (CELL + GAP) + 3
        local col = 1
        for k = 2, COLS do
            if colH[k] < colH[col] then
                col = k
            end
        end
        box:SetHeight(h)
        box:ClearAllPoints()
        box:SetPoint("TOPLEFT", child, "TOPLEFT", (col - 1) * (BOX_W + BOX_GAP), -colH[col])
        colH[col] = colH[col] + h + BOX_GAP
        W.FitText(box.title, BoxTitle(c), BOX_W - 56, box.titleZone)
        local n = 0
        for k = 0, c.size - 1 do
            local slot = c.start + k
            local cell = Cell(c.bag, slot)
            used[cell] = true
            cell:SetParent(box)
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", box, "TOPLEFT", 6 + (k % PER_ROW) * (CELL + GAP), -20 - math.floor(k / PER_ROW) * (CELL + GAP))
            local row = d.byPos[c.bag .. ":" .. slot]
            if row then
                n = n + 1
            end
            if not RenderCell(cell, row) then
                complete = false
            end
            cell:Show()
        end
        box.count:SetText(n .. " / " .. c.size)
        box:Show()
    end
    for i = #list + 1, #boxes do
        boxes[i]:Hide()
    end
    for _, cell in ipairs(cells) do
        if not used[cell] then
            cell.row = nil
            cell:Hide()
        end
    end
    local maxH = 10
    for i = 1, COLS do
        maxH = math.max(maxH, colH[i])
    end
    child:SetHeight(maxH)
    -- names and qualities come from the item cache: render again once it has them
    if not complete and retries < 5 then
        retries = retries + 1
        BT.After("bagscache", 1, function() B.Render() end)
    end
end

-- ---------------------------------------------------------------- bottom row

local sellGrey = W.Tab(body, 22)
W.FitTab(sellGrey, L.sellGrey, 90, 160)
W.SetTabSelected(sellGrey, false)
sellGrey:SetPoint("BOTTOMLEFT", 0, 4)
sellGrey.tip = L.sellGreyTip
sellGrey:SetScript("OnClick", function()
    if cur then
        P.Send("SELLGREY", cur)
    end
end)

local hintText = W.Text(body, "GameFontDisableSmall", W.FAINT)
hintText:SetPoint("LEFT", sellGrey, "RIGHT", 10, 0)
hintText:SetWidth(Party.CONTENT_W - 180)
hintText:SetHeight(12)
W.FitText(hintText, L.bagsHint, Party.CONTENT_W - 180, W.TextZone(body, hintText))

-- ---------------------------------------------------------------- side card "Nearby": trade, bank, vendor
-- One card with a line per place (party-ui-audit S2): trade (button when the bot is close), bank (state),
-- vendor (name, goods / buyback, the list under it). The long explanations are tooltips.

local NEAR_H = Party.CONTENT_H - TOP_H - BOTTOM_H + 4
local nearCard = W.Card(body, L.nearby, SIDE_W, NEAR_H)
nearCard:SetPoint("TOPLEFT", SIDE_X, -TOP_H)

local function LineLabel(text, y)
    local fs = W.Text(nearCard, "GameFontNormalSmall", W.GOLD_DIM)
    fs:SetPoint("TOPLEFT", 10, y)
    fs:SetText(text)
    return fs
end

local function LineRule(y)
    local t = nearCard:CreateTexture(nil, "ARTWORK")
    t:SetTexture(W.LINE[1], W.LINE[2], W.LINE[3], 1)
    t:SetHeight(1)
    t:SetPoint("TOPLEFT", 8, y)
    t:SetPoint("TOPRIGHT", -8, y)
end

-- trade line
local tradeLabel = LineLabel(L.trade, -30)
local tradeButton = W.Tab(nearCard, 20)
tradeButton:SetPoint("TOPRIGHT", -8, -26)
W.SetTabSelected(tradeButton, false)
tradeButton.tip = L.tradeNote
tradeButton:SetScript("OnClick", function()
    local unit = Party.Unit(cur)
    if unit and CheckInteractDistance(unit, TRADE_RANGE) then
        InitiateTrade(unit)
    else
        Party.SetStatus(cur, L.tradeNear, "err")
    end
end)
local tradeState = W.Text(nearCard, "GameFontHighlightSmall", W.MUTED)
tradeState:SetPoint("LEFT", tradeLabel, "RIGHT", 8, 0)
-- a right edge (follows the button's FitTab width), so the client's "..." stops before the button
tradeState:SetPoint("RIGHT", tradeButton, "LEFT", -8, 0)
tradeState:SetHeight(12)
local tradeStateZone = W.TextZone(nearCard, tradeState)

-- bank line (the state text is the whole explanation; it is cut to one line, the tooltip has it all)
LineRule(-50)
local bankLabel = LineLabel(L.bank, -58)
local bankLine = CreateFrame("Frame", nil, nearCard)
bankLine:SetPoint("LEFT", bankLabel, "RIGHT", 8, 0)
bankLine:SetPoint("RIGHT", nearCard, "RIGHT", -10, 0)
bankLine:SetHeight(14)
local bankNote = W.Text(bankLine, "GameFontHighlightSmall", W.FAINT)
bankNote:SetPoint("LEFT", 0, 0)
bankNote:SetPoint("RIGHT", 0, 0)
bankNote:SetHeight(12)

-- vendor (party-extras-spec 6.3)
LineRule(-76)
local vendorMode = "goods"
local vendorOffset = 0
local vendorRetries = 0
local VENDOR_TOP = -106
local VENDOR_ROWS = math.floor((NEAR_H + VENDOR_TOP - 8) / 20)

local vendorCard = nearCard
vendorCard:EnableMouseWheel(true)
vendorCard:SetScript("OnMouseWheel", function(_, delta) B.ScrollVendor(delta) end)
local vendorLabel = LineLabel(L.vendor, -84)

local vendorModeTabs = {}
for i, m in ipairs({ { id = "goods", label = L.vendorGoods }, { id = "buyback", label = L.vendorBuyback } }) do
    local t = W.Tab(vendorCard, 18)
    W.FitTab(t, m.label, 50, 110)
    t.mode = m.id
    t:SetScript("OnClick", function(self)
        B.SetVendorMode(self.mode)
    end)
    vendorModeTabs[i] = t
end
vendorModeTabs[2]:SetPoint("TOPRIGHT", -8, -81)
vendorModeTabs[1]:SetPoint("RIGHT", vendorModeTabs[2], "LEFT", -2, 0)

local vendorNpc = W.Text(vendorCard, "GameFontHighlightSmall", W.TEXT)
vendorNpc:SetPoint("LEFT", vendorLabel, "RIGHT", 8, 0)
-- a right edge, so the client's own "..." (SetWordWrap(false) branch of BT.OneLine) stops at the tabs
vendorNpc:SetPoint("RIGHT", vendorModeTabs[1], "LEFT", -6, 0)
vendorNpc:SetHeight(12)
local vendorNpcZone = W.TextZone(vendorCard, vendorNpc)

local vendorNote = W.Text(vendorCard, "GameFontDisableSmall", W.FAINT)
vendorNote:SetPoint("TOPLEFT", 10, VENDOR_TOP - 2)
vendorNote:SetWidth(SIDE_W - 20)
vendorNote:SetHeight(40)
vendorNote:SetJustifyV("TOP")

-- item name (quality coloured), or nil + "#entry" while the client has no cache entry
local function VendorItemName(entry)
    local name, _, q = GetItemInfo(entry)
    if not name then
        return "#" .. entry, false
    end
    if q and GetItemQualityColor then
        local r, g, b = GetItemQualityColor(q)
        return string.format("|cff%02x%02x%02x%s|r", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), name), true
    end
    return name, true
end

local function VendorRowEnter(self)
    local v = self.vrow
    if not v then
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink("item:" .. v.entry)
    local c = W.MUTED
    if self.mode == "buyback" then
        GameTooltip:AddLine(string.format(L.vendorBuybackTip, BT.Money(v.price)), c[1], c[2], c[3])
    elseif (v.ext or 0) > 0 then
        GameTooltip:AddLine(L.vendorSpecial, W.RED[1], W.RED[2], W.RED[3])
    else
        GameTooltip:AddLine(v.count == 0 and L.vendorUnlimited or string.format(L.vendorStock, v.count), c[1], c[2], c[3])
        GameTooltip:AddLine(L.vendorBuyTip, c[1], c[2], c[3])
    end
    GameTooltip:Show()
end

local function VendorRowClick(self)
    local v, bot = self.vrow, cur
    if not v or not bot then
        return
    end
    if self.mode == "buyback" then
        P.Send("BUYBACKBUY", bot, v.slot, v.entry)
        return
    end
    if (v.ext or 0) > 0 then
        return
    end
    if IsShiftKeyDown and IsShiftKeyDown() then
        -- TalentData.lua (the kit) loads after this file: resolve it at click time
        local K = BT.TabKit
        local name = GetItemInfo(v.entry) or ("#" .. v.entry)
        local slot, entry = v.slot, v.entry
        K.Prompt("buycount", string.format(L.vendorCount, name), "1", function(text)
            local n = tonumber(BT.Trim(text or ""))
            if n then
                n = math.max(1, math.min(BUY_MAX, math.floor(n)))
                P.Send("BUY", bot, slot, entry, n)
            end
        end)
        return
    end
    P.Send("BUY", bot, v.slot, v.entry, 1)
end

local vendorRows = {}
for i = 1, VENDOR_ROWS do
    local r = CreateFrame("Button", nil, vendorCard)
    r:SetHeight(19)
    r:SetPoint("TOPLEFT", 6, VENDOR_TOP - (i - 1) * 20)
    r:SetPoint("RIGHT", vendorCard, "RIGHT", -6, 0)
    r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetWidth(16)
    r.icon:SetHeight(16)
    r.icon:SetPoint("LEFT", 2, 0)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    r.price = W.Text(r, "GameFontHighlightSmall", W.TEXT, "RIGHT")
    r.price:SetPoint("RIGHT", -2, 0)
    r.text = W.Text(r, "GameFontHighlightSmall", W.TEXT)
    r.text:SetPoint("LEFT", 22, 0)
    r.text:SetPoint("RIGHT", r.price, "LEFT", -4, 0)
    r.text:SetHeight(12)
    r:EnableMouseWheel(true)
    r:SetScript("OnMouseWheel", function(_, delta) B.ScrollVendor(delta) end)
    r:SetScript("OnEnter", VendorRowEnter)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:SetScript("OnClick", VendorRowClick)
    r:Hide()
    vendorRows[i] = r
end

-- room of a vendor row's item name left of its price
local function VendorTextW(r)
    return SIDE_W - 12 - 22 - 4 - r.price:GetStringWidth() - 2
end

local function RenderVendor(d)
    for _, t in ipairs(vendorModeTabs) do
        W.SetTabSelected(t, t.mode == vendorMode)
    end
    local near = d and d.flag.v
    local vd = cur and BT.vendor[cur]
    W.FitText(vendorNpc, near and vd and BT.Show(vd.npc) or "", SIDE_W - 90 - 190, vendorNpcZone)
    local list
    if vendorMode == "buyback" then
        list = cur and BT.buyback[cur] or {}
    else
        list = (near and vd and vd.rows) or {}
    end
    local maxOff = math.max(0, #list - VENDOR_ROWS)
    if vendorOffset > maxOff then
        vendorOffset = maxOff
    end
    local complete = true
    for i, r in ipairs(vendorRows) do
        local v = list[i + vendorOffset]
        r.vrow, r.mode = v, vendorMode
        if v then
            local name, cached = VendorItemName(v.entry)
            complete = complete and cached
            r.icon:SetTexture((GetItemIcon and GetItemIcon(v.entry)) or BT.ICON_UNKNOWN)
            if vendorMode == "buyback" then
                r.price:SetText(BT.Money(v.price))
                -- one line; the item tooltip of the row shows the whole name
                W.FitText(r.text, name .. ((v.count or 1) > 1 and (" x" .. v.count) or ""), VendorTextW(r))
                r:SetAlpha(1)
                r:Enable()
            elseif (v.ext or 0) > 0 then
                r.price:SetText("")
                W.FitText(r.text, name, VendorTextW(r))
                r:SetAlpha(0.45)
                r:Enable()        -- keeps the tooltip; the click does nothing
            else
                r.price:SetText(v.price > 0 and BT.Money(v.price) or "")
                W.FitText(r.text, name, VendorTextW(r))
                r:SetAlpha(1)
                r:Enable()
            end
            r:Show()
        else
            r:Hide()
        end
    end
    if vendorMode == "goods" and not near then
        vendorNote:SetText(L.vendorNone)
        vendorNote:Show()
    elseif #list == 0 then
        vendorNote:SetText(L.vendorEmpty)
        vendorNote:Show()
    else
        vendorNote:Hide()
    end
    if not complete and vendorRetries < 3 then
        vendorRetries = vendorRetries + 1
        BT.After("vendorcache", 1, function()
            if pane:IsVisible() and cur then
                RenderVendor(Data())
            end
        end)
    end
end

function B.SetVendorMode(mode)
    vendorMode = mode
    vendorOffset = 0
    if mode == "buyback" and cur and Party.IsOwned(cur) then
        P.Send("BUYBACK", cur)
    end
    RenderVendor(Data())
end

function B.ScrollVendor(delta)
    vendorOffset = math.max(0, vendorOffset - delta)
    RenderVendor(Data())
end

local function RenderSide(d)
    local b = BT.bots[cur]
    W.FitTab(tradeButton, L.tradeOpenShort, 90, 160)
    tradeButton.tip = string.format(L.openTrade, BT.Show(b and b.name or "")) .. "\n" .. L.tradeNote
    local unit = Party.Unit(cur)
    local near = unit and CheckInteractDistance(unit, TRADE_RANGE) and true or false
    local can = near and not TradeOpen()
    W.Enable(tradeButton, can)
    tradeButton:SetAlpha(can and 1 or 0.45)
    local stateW = SIDE_W - 20 - tradeLabel:GetStringWidth() - 8 - tradeButton:GetWidth() - 8
    if TradeOpen() then
        W.FitText(tradeState, L.tradeIsOpen, stateW, tradeStateZone)
        W.Color(tradeState, W.OWN)
    elseif not near then
        W.FitText(tradeState, L.tradeNear, stateW, tradeStateZone)
        W.Color(tradeState, W.MUTED)
    else
        W.FitText(tradeState, L.tradeCanOpen, stateW, tradeStateZone)
        W.Color(tradeState, W.OWN)
    end
    local bankW = SIDE_W - 20 - bankLabel:GetStringWidth() - 8
    if d and d.flag.b then
        W.FitText(bankNote, L.bankOn, bankW, bankLine)
        W.Color(bankNote, W.OWN)
    else
        W.FitText(bankNote, L.bankNote, bankW, bankLine)
        W.Color(bankNote, W.FAINT)
    end
    local sell = d and d.flag.v and true or false
    W.Enable(sellGrey, sell)
    sellGrey:SetAlpha(sell and 1 or 0.45)
end

-- ---------------------------------------------------------------- render / tab hooks

function B.Render()
    if not pane:IsVisible() then
        return
    end
    if not cur or not Party.IsOwned(cur) then
        body:Hide()
        message:SetText(cur and L.notInGroup or L.selectBot)
        message:Show()
        return
    end
    local d = Data()
    body:Show()
    RenderModes(d)
    RenderSide(d)
    RenderVendor(d)
    if not d then
        message:SetText(L.loading)
        message:Show()
        scroll:Hide()
        return
    end
    message:Hide()
    scroll:Show()
    RenderBoxes(d)
end

local function Request()
    if cur and Party.IsOwned(cur) then
        P.Send("INV", cur)
        P.Send("BUYBACK", cur)
    end
end

local Tick
Tick = function()
    if not pane:IsVisible() then
        return
    end
    Request()
    BT.After("bagsrefresh", REFRESH_EVERY, Tick)
end

function B.Show(low)
    if low ~= cur then
        held = nil
        vendorOffset = 0
    end
    vendorRetries = 0
    cur = low
    retries = 0
    B.Render()
    Request()
    BT.After("bagsrefresh", REFRESH_EVERY, Tick)
end

function B.Hide()
    held = nil
    BT.Cancel("bagsrefresh")
    BT.Cancel("bagsack")
    CloseDropDownMenus()
end

function B.OnData(what, bot, op, ok, code)
    if what == "bags" then
        if bot == cur then
            BT.Cancel("bagsack")
            retries = 0
            -- a vendor next to the bot: its goods with every BAGS (also on the 20 s tick); the BAGS
            -- that follows a successful BUY is itself followed by the server's VENDOR, so no request
            local d = Data()
            if vendorFollows == cur then
                vendorFollows = nil
            elseif d and d.flag.v and Party.IsOwned(cur) then
                P.Send("VENDOR", cur)
            end
            B.Render()
        end
    elseif what == "vendor" then
        if bot == cur then
            vendorRetries = 0
            B.Render()
        end
    elseif what == "ack" then
        -- no client event tells about the bot's bags: refresh after every answer (unless the BAGS
        -- that follows a successful op arrives first, or Protocol already re-requested on "stale")
        if bot == cur and code ~= "stale" then
            BT.After("bagsack", ACK_REFRESH, Request)
        end
        -- server order after a successful BUY: ACK, BAGS, VENDOR (vendor.lua handlers.BUY)
        vendorFollows = (bot == cur and op == "BUY" and ok) and cur or nil
    elseif bot == nil or bot == cur then
        B.Render()
    end
end

-- ---------------------------------------------------------------- vendor messages (party-extras-spec 4.2)

-- VENDOR <bot> <npcNameEsc> <flags> <rows>: slot,entry,price,count,ext (empty name + rows = no vendor)
P.Handlers.VENDOR = function(f)
    local bot = tonumber(f[2])
    if not bot then
        return
    end
    local rows = {}
    for _, e in ipairs(BT.List(f[5])) do
        local s = BT.Split(e, ",")
        local slot, entry = tonumber(s[1]), tonumber(s[2])
        if slot and entry then
            rows[#rows + 1] = {
                slot = slot, entry = entry, price = tonumber(s[3]) or 0, count = tonumber(s[4]) or 0, ext = tonumber(s[5]) or 0,
            }
        end
    end
    BT.vendor[bot] = { npc = BT.Unesc(f[3]), rows = rows, trunc = f[4] == "T" }
    P.Changed("vendor", bot)
end

-- BUYBACK <bot> <rows>: slot,entry,count,price
P.Handlers.BUYBACK = function(f)
    local bot = tonumber(f[2])
    if not bot then
        return
    end
    local rows = {}
    for _, e in ipairs(BT.List(f[3])) do
        local s = BT.Split(e, ",")
        local slot, entry = tonumber(s[1]), tonumber(s[2])
        if slot and entry then
            rows[#rows + 1] = { slot = slot, entry = entry, count = tonumber(s[3]) or 1, price = tonumber(s[4]) or 0 }
        end
    end
    BT.buyback[bot] = rows
    P.Changed("vendor", bot)
end

-- ok texts of the purchases (errors: the shared ACK handling of Protocol.lua)
P.Handlers.ACK = function(f)
    local op = f[3]
    if f[4] == "ok" and (op == "BUY" or op == "BUYBACKBUY") then
        local bot = tonumber(f[2])
        local text = BT.Unesc(f[6])
        if bot then
            Party.SetStatus(bot, text ~= "" and text or (f[5] or ""), "ok")
        end
    end
end

-- Widgets for the mock tests (scratchpad bt_test).
function B.ForTest()
    return { vendorCard = vendorCard, vendorRows = vendorRows, vendorModeTabs = vendorModeTabs, vendorNote = vendorNote,
        tradeButton = tradeButton, sellGrey = sellGrey }
end

-- ---------------------------------------------------------------- trade events and range ticker

local events = CreateFrame("Frame")
events:RegisterEvent("TRADE_SHOW")
events:RegisterEvent("TRADE_CLOSED")
events:SetScript("OnEvent", function(_, event)
    if event == "TRADE_SHOW" then
        tradeShown = true
        local list = pendingGives
        pendingGives = {}
        BT.Cancel("bagsgive")
        for _, g in ipairs(list) do
            if GetTime() - g.at <= GIVE_WAIT then
                SendItem(g.bot, "give", g.row)
            end
        end
    elseif event == "TRADE_CLOSED" then
        tradeShown = false
    end
    if pane:IsVisible() then
        RenderSide(Data())
    end
end)

local ticker = CreateFrame("Frame", nil, body)
ticker.t = 0
ticker:SetScript("OnUpdate", function(self, elapsed)
    self.t = self.t + (elapsed or 0)
    if self.t >= 0.5 then
        self.t = 0
        if cur and Party.IsOwned(cur) then
            RenderSide(Data())
        end
    end
end)
