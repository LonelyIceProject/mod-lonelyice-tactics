-- Tab "Добыча и задания" (party-window-spec 6.8, party-ui-audit 6.7): the Loot card (mode, pick up,
-- always-loot list) and the Quests card (log / completed, accept all, talk). The other actions that used
-- to live here moved: bot actions to the header ("More"), group actions to the strip's "Group" menu,
-- outfits to the Gear tab ("Outfit"). Data = LOOT, QUESTS and QDONE (parsed here).

local BT = BotTactics
local L, W, P = BT.L, BT.W, BT.Protocol
local Party = BT.Party
local S = BT.S

L.tabLootQuests = S("Loot & quests", "Добыча и задания")
-- quests card views (party-extras-spec 6.4)
L.questLog = S("In the log", "В журнале")
L.questsDone = S("Completed", "Выполнено")
L.questsDoneRange = S("%d-%d of %d", "%d-%d из %d")
L.questsDoneNone = S("No completed quests", "Выполненных заданий нет")
L.lootModeFmt = S("Mode: %s", "Режим: %s")
L.lootModeTip = S("Loot rule of this bot. The strip's Group menu sets it for every bot.",
    "Правило добычи этого бота. Для всех ботов - меню «Группа» на полосе приказов.")

local M = {}
BT.Misc = M

local GAP = 10
local LOOT_W = math.floor((Party.CONTENT_W - GAP) / 3)
local QUEST_W = Party.CONTENT_W - LOOT_W - GAP
local CARD_H = Party.CONTENT_H
local QUEST_TOP = -52
local QUEST_ROW_H = 20
local QUEST_ROWS = math.floor((CARD_H + QUEST_TOP - 34) / QUEST_ROW_H)
local QDONE_PAGE = 50         -- client copy of config.QDONE_PAGE (the server's offset echo wins)
local PILLS_MAX = 24

BT.loot = BT.loot or {}       -- low -> { mode, on, items = { {entry, name}, ... } }
BT.quests = BT.quests or {}   -- low -> { {id, level, complete, title}, ... }
BT.questsDone = BT.questsDone or {}   -- low -> { total, offset, rows = { {id, level, title}, ... } }

local cur
local questView = "log"                        -- "log" | "done"
local questOffsets = { log = 0, done = 0 }     -- wheel offset inside the list of each view

local pane = Party.RegisterTab("misc", L.tabLootQuests,
    function(low) M.Show(low) end,
    function() M.Hide() end,
    function(what, bot) M.OnData(what, bot) end)
M.pane = pane

local body = CreateFrame("Frame", nil, pane)
body:SetAllPoints(pane)

local message = W.Text(pane, "GameFontNormal", W.MUTED, "CENTER")
message:SetPoint("CENTER", pane, "CENTER", 0, 40)
message:SetWidth(460)

local function Cmd(text)
    Party.Cmd(cur, text)
end

local function FlatButton(parent, text, h, maxW)
    local b = W.Tab(parent, h or 22)
    W.FitTab(b, text, 40, maxW)
    W.SetTabSelected(b, false)
    return b
end

local lootCard = W.Card(body, L.cardLoot, LOOT_W, CARD_H)
lootCard:SetPoint("TOPLEFT", 0, 0)
local questCard = W.Card(body, L.cardQuests, QUEST_W, CARD_H)
questCard:SetPoint("TOPLEFT", lootCard, "TOPRIGHT", GAP, 0)
if BT.MirrorUI then BT.MirrorUI.Attach(questCard) end   -- "Like an RPG" (MirrorUI.lua, abilities-mirroring-spec 5.5)

-- ---------------------------------------------------------------- loot

local function ModeLabel(id)
    for _, m in ipairs(L.lootModes) do
        if m.id == id then
            return m.label
        end
    end
    return id or "-"
end

local lootModePick = W.Pick(lootCard, LOOT_W - 20, 22, false, true)
lootModePick:SetPoint("TOPLEFT", 10, -26)
lootModePick.onEnter = function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L.lootModeTip, 1, 1, 1, 1, 1)
    local lt = BT.loot[cur]
    for _, m in ipairs(L.lootModes) do
        if lt and m.id == lt.mode and m.desc then
            GameTooltip:AddLine(m.desc, W.MUTED[1], W.MUTED[2], W.MUTED[3], 1)
        end
    end
    GameTooltip:Show()
end
lootModePick:SetScript("OnClick", function(self)
    local lt = BT.loot[cur]
    local items = { { text = L.cardLoot, isTitle = true, notCheckable = true } }
    for _, m in ipairs(L.lootModes) do
        local id = m.id
        items[#items + 1] = { text = m.label, checked = lt ~= nil and lt.mode == id,
            tooltipTitle = m.label, tooltipText = m.desc, tooltipOnButton = m.desc and true or nil, func = function()
            CloseDropDownMenus()
            P.Send("SETLOOT", cur, "mode", id)
        end }
    end
    W.ShowMenu(self, items)
end)

local lootOnText = W.Text(lootCard, "GameFontHighlightSmall", W.TEXT)
lootOnText:SetPoint("TOPLEFT", 10, -62)
lootOnText:SetText(L.lootOn)
local lootSwitch = W.Switch(lootCard)
lootSwitch:SetPoint("TOPRIGHT", -10, -59)
lootSwitch:SetScript("OnClick", function(self)
    P.Send("SETLOOT", cur, "on", self.on and "0" or "1")
end)

local lootAlways = W.Text(lootCard, "GameFontDisableSmall", W.MUTED)
lootAlways:SetPoint("TOPLEFT", 10, -90)
lootAlways:SetText(L.lootAlways)

local lootPills = {}
for i = 1, PILLS_MAX do
    local t = W.Tab(lootCard, 18)
    t.tip = L.lootDelTip
    t:SetScript("OnClick", function(self)
        if self.entry then
            P.Send("SETLOOT", cur, "del", self.entry)
        end
    end)
    t:Hide()
    lootPills[i] = t
end
local lootAddB = FlatButton(lootCard, L.lootAdd, 18, LOOT_W - 20)
lootAddB:SetScript("OnClick", function()
    local low = cur
    BT.Prompt("lootadd", L.lootAddPrompt, "", function(text)
        local entry = tonumber(string.match(text or "", "item:(%d+)") or BT.Trim(text or ""))
        if entry and entry > 0 then
            P.Send("SETLOOT", low, "add", entry)
        end
    end)
end)
local lootMore = W.Text(lootCard, "GameFontDisableSmall", W.FAINT)

local function RenderLoot()
    local lt = BT.loot[cur]
    W.SetPickText(lootModePick, string.format(L.lootModeFmt, lt and ModeLabel(lt.mode) or "-"))
    W.SetSwitch(lootSwitch, lt and lt.on)
    local items = lt and lt.items or {}
    local right = LOOT_W - 10
    local x, y = 10, -106
    for i = 1, PILLS_MAX do
        local t = lootPills[i]
        local it = items[i]
        if it then
            local name = it.name ~= "" and BT.Show(it.name) or GetItemInfo(it.entry) or ("#" .. it.entry)
            W.FitTab(t, name, 30, LOOT_W - 20)
            t.entry = it.entry
            if x > 10 and x + t:GetWidth() > right then
                x = 10
                y = y - 21
            end
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", lootCard, "TOPLEFT", x, y)
            t:Show()
            x = x + t:GetWidth() + 3
        else
            t.entry = nil
            t:Hide()
        end
    end
    lootMore:ClearAllPoints()
    if #items > PILLS_MAX then
        lootMore:SetText("+" .. (#items - PILLS_MAX))
        lootMore:SetPoint("TOPLEFT", lootCard, "TOPLEFT", x, y - 3)
        lootMore:Show()
        x = x + 30
    else
        lootMore:Hide()
    end
    if x > 10 and x + lootAddB:GetWidth() > right then
        x = 10
        y = y - 21
    end
    lootAddB:ClearAllPoints()
    lootAddB:SetPoint("TOPLEFT", lootCard, "TOPLEFT", x, y)
end

-- ---------------------------------------------------------------- quests

local acceptB = FlatButton(questCard, L.acceptAll, 22, 160)
acceptB:SetPoint("TOPLEFT", 10, -24)
acceptB:SetScript("OnClick", function()
    P.Send("QUEST", cur, "acceptall", 0)
end)
local talkB = FlatButton(questCard, L.talkNpc, 22, 160)
talkB:SetPoint("LEFT", acceptB, "RIGHT", 3, 0)
talkB:SetScript("OnClick", function()
    Cmd("talk")
end)
talkB.tip = L.talkNpcTip

-- view switch: quest log / completed quests (party-extras-spec 6.4), right side of the same row
local questViewDone = W.Tab(questCard, 22)
W.FitTab(questViewDone, L.questsDone, 60, 110)
questViewDone:SetPoint("TOPRIGHT", -10, -24)
questViewDone:SetScript("OnClick", function() M.SetQuestView("done") end)
local questViewLog = W.Tab(questCard, 22)
W.FitTab(questViewLog, L.questLog, 60, 110)
questViewLog:SetPoint("RIGHT", questViewDone, "LEFT", -2, 0)
questViewLog:SetScript("OnClick", function() M.SetQuestView("log") end)

local questRows = {}
for i = 1, QUEST_ROWS do
    local r = CreateFrame("Frame", nil, questCard)
    r:SetWidth(QUEST_W - 16)
    r:SetHeight(QUEST_ROW_H)
    r:SetPoint("TOPLEFT", 8, QUEST_TOP - (i - 1) * QUEST_ROW_H)
    r.text = W.Text(r, "GameFontHighlightSmall", W.TEXT)
    r.text:SetPoint("LEFT", 2, 0)
    r.text:SetHeight(12)
    r.drop = FlatButton(r, L.questDrop, 18, 90)
    r.drop:SetPoint("RIGHT", 0, 0)
    r.text:SetPoint("RIGHT", r.drop, "LEFT", -4, 0)
    r.drop:SetScript("OnClick", function(self)
        local q = self.quest
        if not q then
            return
        end
        local low = cur
        BT.Confirm("questdrop", string.format(L.confirmQuestDrop, BT.Show(q.title)), function()
            P.Send("QUEST", low, "drop", q.id)
        end)
    end)
    r:EnableMouseWheel(true)
    r:SetScript("OnMouseWheel", function(_, delta)
        M.ScrollQuests(delta)
    end)
    r:Hide()
    questRows[i] = r
end
local questEmpty = W.Text(questCard, "GameFontDisableSmall", W.FAINT)
questEmpty:SetPoint("TOPLEFT", 10, QUEST_TOP - 4)
questEmpty:SetText(L.questNone)
questCard:EnableMouseWheel(true)
questCard:SetScript("OnMouseWheel", function(_, delta)
    M.ScrollQuests(delta)
end)

-- footer of the "completed" view: range and page buttons
local questPrev = FlatButton(questCard, "<", 18)
questPrev:SetWidth(22)
questPrev:SetPoint("BOTTOMLEFT", 10, 10)
questPrev:SetScript("OnClick", function() M.QuestPage(-1) end)
local questNext = FlatButton(questCard, ">", 18)
questNext:SetWidth(22)
questNext:SetPoint("LEFT", questPrev, "RIGHT", 3, 0)
questNext:SetScript("OnClick", function() M.QuestPage(1) end)
local questRange = W.Text(questCard, "GameFontDisableSmall", W.FAINT)
questRange:SetPoint("LEFT", questNext, "RIGHT", 8, 0)
questRange:SetWidth(QUEST_W - 80)

local function EnableFlat(b, on)
    W.Enable(b, on)
    b:SetAlpha(on and 1 or 0.45)
end

local function RenderQuests()
    W.SetTabSelected(questViewLog, questView == "log")
    W.SetTabSelected(questViewDone, questView == "done")
    local done = questView == "done"
    local qd = cur and BT.questsDone[cur]
    local list
    if done then
        list = qd and qd.rows or {}
    else
        list = BT.quests[cur] or {}
    end
    local off = questOffsets[questView] or 0
    local maxOff = math.max(0, #list - QUEST_ROWS)
    if off > maxOff then
        off = maxOff
        questOffsets[questView] = off
    end
    for i = 1, QUEST_ROWS do
        local r = questRows[i]
        local q = list[i + off]
        r.quest = (not done) and q or nil
        r.drop.quest = r.quest
        if q then
            local t = "[" .. q.level .. "] " .. BT.Show(q.title)
            if q.complete and not done then
                t = t .. " |cff62d06d(" .. L.questDone .. ")|r"
            end
            local textW = QUEST_W - 16 - 6 - (done and 0 or (r.drop:GetWidth() + 4))
            -- the right edge follows the width used for the cut: the row end in "done" (no drop button)
            r.text:ClearAllPoints()
            r.text:SetPoint("LEFT", 2, 0)
            if done then
                r.text:SetPoint("RIGHT", r, "RIGHT", -4, 0)
            else
                r.text:SetPoint("RIGHT", r.drop, "LEFT", -4, 0)
            end
            W.FitText(r.text, t, textW, r)
            W.Show(r.drop, not done)
            r:Show()
        else
            r:Hide()
        end
    end
    if done then
        questEmpty:SetText(L.questsDoneNone)
        W.Show(questEmpty, qd ~= nil and qd.total == 0)
        local page = qd ~= nil and qd.total > 0
        W.Show(questPrev, page)
        W.Show(questNext, page)
        W.Show(questRange, page)
        if page then
            local last = math.min(qd.total, qd.offset + #qd.rows)
            questRange:SetText(string.format(L.questsDoneRange, math.min(qd.offset + 1, last), last, qd.total))
            EnableFlat(questPrev, qd.offset > 0)
            EnableFlat(questNext, qd.offset + QDONE_PAGE < qd.total)
        end
    else
        questEmpty:SetText(L.questNone)
        W.Show(questEmpty, BT.quests[cur] ~= nil and #list == 0)
        questPrev:Hide()
        questNext:Hide()
        questRange:Hide()
    end
end

function M.ScrollQuests(delta)
    questOffsets[questView] = math.max(0, (questOffsets[questView] or 0) - delta)
    RenderQuests()
end

function M.SetQuestView(view)
    questView = view
    if view == "done" and cur and Party.IsOwned(cur) then
        questOffsets.done = 0
        P.Send("QDONE", cur, 0)
    end
    RenderQuests()
end

-- Page of completed quests: dir -1 / 1 from the offset the server echoed.
function M.QuestPage(dir)
    local qd = cur and BT.questsDone[cur]
    if not qd then
        return
    end
    local off = qd.offset + dir * QDONE_PAGE
    if off < 0 or off >= qd.total then
        return
    end
    questOffsets.done = 0
    P.Send("QDONE", cur, off)
end

-- ---------------------------------------------------------------- messages (4.2)

-- LOOT <bot> <mode> <on> <items>: items = entry,nameEsc
P.Handlers.LOOT = function(f)
    local bot = tonumber(f[2])
    if not bot then
        return
    end
    local items = {}
    for _, e in ipairs(BT.List(f[5])) do
        local s = BT.Split(e, ",")
        local entry = tonumber(s[1])
        if entry then
            items[#items + 1] = { entry = entry, name = BT.Unesc(s[2]) }
        end
    end
    BT.loot[bot] = { mode = f[3] or "", on = f[4] == "1", items = items }
    P.Changed("loot", bot)
end

-- QUESTS <bot> <entries>: id,level,complete,titleEsc
P.Handlers.QUESTS = function(f)
    local bot = tonumber(f[2])
    if not bot then
        return
    end
    local list = {}
    for _, e in ipairs(BT.List(f[3])) do
        local s = BT.Split(e, ",")
        local id = tonumber(s[1])
        if id then
            list[#list + 1] = { id = id, level = tonumber(s[2]) or 0, complete = s[3] == "1", title = BT.Unesc(s[4]) }
        end
    end
    BT.quests[bot] = list
    P.Changed("quests", bot)
end

-- QDONE <bot> <total> <offset> <rows>: id,level,titleEsc (party-extras-spec 4.2)
P.Handlers.QDONE = function(f)
    local bot = tonumber(f[2])
    if not bot then
        return
    end
    local rows = {}
    for _, e in ipairs(BT.List(f[5])) do
        local s = BT.Split(e, ",")
        local id = tonumber(s[1])
        if id then
            rows[#rows + 1] = { id = id, level = tonumber(s[2]) or 0, title = BT.Unesc(s[3]) }
        end
    end
    BT.questsDone[bot] = { total = tonumber(f[3]) or #rows, offset = tonumber(f[4]) or 0, rows = rows }
    P.Changed("qdone", bot)
end

-- ---------------------------------------------------------------- render / tab hooks

function M.Render()
    if not pane:IsVisible() then
        return
    end
    if not cur or not Party.IsOwned(cur) then
        body:Hide()
        message:SetText(cur and L.notInGroup or L.selectBot)
        message:Show()
        return
    end
    message:Hide()
    body:Show()
    RenderLoot()
    RenderQuests()
end

function M.Show(low)
    local fresh = low ~= cur
    if fresh then
        questOffsets.log, questOffsets.done = 0, 0
    end
    cur = low
    M.Render()
    if cur and Party.IsOwned(cur) then
        P.Send("LOOT", cur)
        P.Send("QUESTS", cur)
        if questView == "done" then
            local qd = BT.questsDone[cur]
            P.Send("QDONE", cur, (not fresh and qd and qd.offset) or 0)
        end
    end
end

function M.Hide()
    CloseDropDownMenus()
end

-- Widgets for the mock tests (scratchpad bt_test).
function M.ForTest()
    return {
        lootModePick = lootModePick, lootSwitch = lootSwitch, lootPills = lootPills, lootAddB = lootAddB,
        acceptB = acceptB, talkB = talkB, questRows = questRows,
        questViewLog = questViewLog, questViewDone = questViewDone, questPrev = questPrev, questNext = questNext,
        questRange = questRange, questEmpty = questEmpty, lootCard = lootCard, questCard = questCard,
        lootOnText = lootOnText, lootW = LOOT_W, questW = QUEST_W,
    }
end

function M.OnData(_, bot)
    if bot == nil or bot == cur then
        M.Render()
    end
end
