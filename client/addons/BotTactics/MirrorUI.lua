-- "Like an RPG" (abilities-mirroring-spec 5.5): the bots mirror what you do - quests, flights, hearthstone and
-- portals, vendors, trainers - and say so in party chat. Lives in the Quests card of "Loot & quests": the
-- small "Like an RPG" button in the card's title row swaps the quest list for the settings (switches for
-- everyone + the selected bot's opt-outs) and a short feed of what the bots did. Misc.lua calls
-- BT.MirrorUI.Attach(questCard). Texts ru/en here (not in Locale.lua).
-- Messages: MIRROR, SETMIRROR <bot|0> <key> <value>, MIRRORLOG <n> -> MIRRORSET, MIRRORED, MIRRORLOG.

local BT = BotTactics
local L, W, P = BT.L, BT.W, BT.Protocol
local S = BT.S

L.rpgTitle = S("Like an RPG", "Как в RPG")
L.rpgButtonTip = S("The bots do what you do: take and turn in quests, fly, go home, trade, train.",
    "Боты повторяют за вами: берут и сдают задания, летают, возвращаются домой, торгуют, учатся.")
L.rpgAll = S("Everyone", "Все")
L.rpgAllTip = S("For all your bots.", "Для всех ваших ботов.")
L.rpgBotTip = S("For this bot only: off = it does not follow you in this.",
    "Только для этого бота: выкл. = в этом он за вами не повторяет.")
L.rpgReward = S("Reward: %s", "Награда: %s")
L.rpgRewardBest = S("best for the bot", "лучшая для бота")
L.rpgRewardSame = S("the same as yours", "как у вас")
L.rpgRewardTip = S("Which quest reward a bot takes when it turns in a quest with you.",
    "Какую награду бот берёт, когда сдаёт задание вместе с вами.")
L.rpgFeed = S("Latest", "Последнее")
L.rpgFeedNone = S("Nothing yet. Take a quest or fly somewhere.", "Пока ничего. Возьмите задание или слетайте куда-нибудь.")
L.rpgParty = S("Party", "Отряд")
L.rpgOffServer = S("Mirroring is off on the server (Tactics.Mirror.Enable).",
    "Повторение выключено на сервере (Tactics.Mirror.Enable).")
L.rpgAgo = S("%s ago", "%s назад")

-- key, label, hint (tooltip of the row)
local ROWS = {
    { "quest", S("Take quests with you", "Брать задания вместе с вами"),
      S("When you accept a quest, your bots take it too, wherever they are.",
        "Когда вы берёте задание, его берут и боты, где бы они ни были.") },
    { "turnin", S("Turn in quests with you", "Сдавать задания вместе с вами"),
      S("When you turn in a quest, your bots turn it in too.", "Когда вы сдаёте задание, боты сдают его тоже.") },
    { "turnin_force", S("Even without done objectives", "Сдавать даже без выполненных целей"),
      S("A bot that has the quest turns it in with you even without done objectives. Quest items: it gives what it has, missing ones do not block.",
        "Бот, у которого есть это задание, сдаёт его вместе с вами, даже не выполнив цели. Предметы задания отдаёт те, что есть; нехватка не мешает.") },
    { "abandon", S("Abandon quests with you", "Бросать задания вместе с вами"),
      S("When you abandon a quest, your bots abandon it too.", "Когда вы бросаете задание, боты бросают его тоже.") },
    { "taxi", S("Flights after you", "Перелёты за вами"),
      S("Bots near the flight master fly with you; the others join you when you land.",
        "Боты у распорядителя полётов летят с вами, остальные догоняют после посадки.") },
    { "hearth", S("Hearthstone and portals after you", "Камень и порталы за вами"),
      S("After your hearthstone, a portal or a waystone the bots join you.",
        "После камня возвращения, портала или путевого камня боты переносятся к вам.") },
    { "vendor", S("Sell junk and repair at vendors", "Продавать хлам и чиниться"),
      S("Bots near the vendor you talk to sell grey items and repair.",
        "Боты рядом с торговцем, с которым вы говорите, продают серые вещи и чинятся.") },
    { "train", S("Learn at the trainer", "Учиться у наставника"),
      S("Bots near the trainer you visit learn what their class trainer teaches.",
        "Боты рядом с наставником учат всё, чему он учит их класс.") },
    { "talk", S("Talk to the NPCs you talk to", "Говорить с NPC вместе с вами"),
      S("Bots near you also talk to the NPC (quest givers).", "Боты рядом тоже говорят с NPC (квестодатели).") },
    { "chat", S("Say it in party chat", "Говорить об этом в чате группы"),
      S("Bots mention in party chat what they took, turned in or could not do.",
        "Боты пишут в чат группы, что взяли, сдали или не смогли.") },
}

local M = {}
BT.MirrorUI = M

-- Data (MIRRORSET / MIRRORED / MIRRORLOG): set = key -> value, bots = low -> { key = true (opted out) },
-- feed = { { at, bot, event, ok, text }, ... } oldest first.
BT.mirror = BT.mirror or { set = {}, bots = {}, server = { enable = true, radius = 30 }, feed = {}, got = false }
local FEED_MAX = 20

local ROW_H = 20
local COL_W = 64
local FEED_ROW_H = 14
local FEED_ROWS = 8

local ui = {}
local card

local function Cur()
    return BT.Party and BT.Party.Current and BT.Party.Current()
end

local function BotName(low)
    low = tonumber(low)
    if not low or low == 0 then
        return L.rpgParty
    end
    local b = BT.bots and BT.bots[low]
    local a = BT.acctByLow and BT.acctByLow[low]
    return (b and b.name) or (a and a.name) or ("#" .. low)
end

local function Age(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    if seconds < 60 then
        return seconds .. S(" s", " с")
    elseif seconds < 3600 then
        return math.floor(seconds / 60) .. S(" min", " мин")
    end
    return math.floor(seconds / 3600) .. S(" h", " ч")
end

-- ---------------------------------------------------------------- messages

-- MIRRORSET <k=v;...> <bot,k=0,...;...> <enable=0|1,radius=N>
P.Handlers.MIRRORSET = function(f)
    local m = BT.mirror
    local set = {}
    for _, e in ipairs(BT.List(f[2])) do
        local k, v = string.match(e, "^([%w_]+)=([%w]+)$")
        if k then
            set[k] = v
        end
    end
    local bots = {}
    for _, e in ipairs(BT.List(f[3])) do
        local s = BT.Split(e, ",")
        local low = tonumber(s[1])
        if low then
            local o = {}
            for i = 2, #s do
                local k = string.match(s[i], "^([%w_]+)=0$")
                if k then
                    o[k] = true
                end
            end
            bots[low] = o
        end
    end
    local server = { enable = true, radius = 30 }
    for _, e in ipairs(BT.List(f[4], ",")) do
        local k, v = string.match(e, "^(%w+)=(%d+)$")
        if k == "enable" then
            server.enable = v ~= "0"
        elseif k == "radius" then
            server.radius = tonumber(v) or 30
        end
    end
    m.set, m.bots, m.server, m.got = set, bots, server, true
    M.Render()
end

local function AddFeed(entry)
    local feed = BT.mirror.feed
    feed[#feed + 1] = entry
    while #feed > FEED_MAX do
        table.remove(feed, 1)
    end
end

-- MIRRORED <bot|0> <event> <0|1> <textEsc>
P.Handlers.MIRRORED = function(f)
    AddFeed({ at = GetTime(), bot = tonumber(f[2]) or 0, event = f[3] or "", ok = f[4] == "1", text = BT.Unesc(f[5]) })
    M.Render()
end

-- MIRRORLOG <age_s,bot,event,0|1,textEsc;...> (oldest first): replaces the feed
P.Handlers.MIRRORLOG = function(f)
    local now = GetTime()
    local feed = {}
    for _, e in ipairs(BT.List(f[2])) do
        local s = BT.Split(e, ",")
        local age = tonumber(s[1])
        if age then
            feed[#feed + 1] = { at = now - age, bot = tonumber(s[2]) or 0, event = s[3] or "", ok = s[4] == "1",
                text = BT.Unesc(s[5]) }
        end
    end
    while #feed > FEED_MAX do
        table.remove(feed, 1)
    end
    BT.mirror.feed = feed
    M.Render()
end

-- ACK of SETMIRROR for the whole party (bot "0" has no roster entry, so the party status line never shows
-- it): the error text goes under the reward pick until the next ok. Per-bot errors stay in the party status.
P.Handlers.ACK = function(f)
    if f[3] ~= "SETMIRROR" or tonumber(f[2]) ~= 0 then
        return
    end
    if f[4] == "ok" then
        BT.mirror.err = nil
    else
        local text = BT.Unesc(f[6])
        BT.mirror.err = (text ~= "" and text) or f[5] or "?"
    end
    M.Render()
end

-- ---------------------------------------------------------------- state helpers

local function PlayerOn(key)
    return BT.mirror.set[key] == "1"
end

local function BotOn(low, key)
    local o = low and BT.mirror.bots[low]
    return not (o and o[key])
end

-- ---------------------------------------------------------------- widgets

local function RowEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(self.title or "", 1, 0.82, 0, 1, 1)
    if self.tip then
        GameTooltip:AddLine(self.tip, 1, 1, 1, 1)
    end
    GameTooltip:Show()
end

local function RowLeave()
    GameTooltip:Hide()
end

local function SwitchTip(b, text)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(self.tipTitle or "", 1, 0.82, 0, 1, 1)
        GameTooltip:AddLine(text, 1, 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", RowLeave)
end

local function Line(parent)
    local line = parent:CreateTexture(nil, "BACKGROUND")
    line:SetTexture(0.17, 0.14, 0.10, 1)
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT", 0, 0)
    line:SetPoint("BOTTOMRIGHT", 0, 0)
end

local function Build(parent)
    card = parent
    local cardW = card:GetWidth()
    local innerW = cardW - 20

    -- title-row button: swaps the quest list for the settings
    ui.open = W.Tab(card, 18)
    W.FitTab(ui.open, L.rpgTitle, 60, 150)
    ui.open.tip = L.rpgButtonTip
    ui.open:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -4)
    W.SetTabSelected(ui.open, false)
    ui.open:SetScript("OnClick", function()
        M.Toggle()
    end)

    -- the panel covers the card below the title row (quest buttons and list)
    local panel = CreateFrame("Frame", nil, card)
    panel:SetPoint("TOPLEFT", card, "TOPLEFT", 4, -24)
    panel:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -4, 4)
    panel:SetFrameLevel((card:GetFrameLevel() or 1) + 10)
    panel:EnableMouse(true)
    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function() end)
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(panel)
    bg:SetTexture(0.07, 0.055, 0.04, 1)
    panel:Hide()
    ui.panel = panel

    -- column headers: everyone / the selected bot
    ui.headAll = W.Text(panel, "GameFontDisableSmall", W.MUTED, "CENTER")
    ui.headAll:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6 - COL_W, -2)
    ui.headAll:SetWidth(COL_W)
    ui.headAll:SetHeight(12)
    ui.headBot = W.Text(panel, "GameFontDisableSmall", W.MUTED, "CENTER")
    ui.headBot:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -2)
    ui.headBot:SetWidth(COL_W)
    ui.headBot:SetHeight(12)
    ui.headBotZone = W.TextZone(panel, ui.headBot)

    ui.rows = {}
    for i, def in ipairs(ROWS) do
        local r = CreateFrame("Frame", nil, panel)
        r:SetHeight(ROW_H)
        r:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, -16 - (i - 1) * ROW_H)
        r:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -16 - (i - 1) * ROW_H)
        r:SetWidth(innerW)
        r.key, r.title, r.tip = def[1], def[2], def[3]
        r:EnableMouse(true)
        r:SetScript("OnEnter", RowEnter)
        r:SetScript("OnLeave", RowLeave)
        r.label = W.Text(r, "GameFontHighlightSmall", W.TEXT)
        r.label:SetPoint("LEFT", 0, 0)
        r.label:SetPoint("RIGHT", r, "RIGHT", -(2 * COL_W + 8), 0)
        r.label:SetHeight(12)
        r.labelW = innerW - 2 * COL_W - 8
        r.all = W.Switch(r)
        r.all:SetPoint("CENTER", r, "RIGHT", -COL_W - COL_W / 2, 0)
        r.all.tipTitle = def[2]
        SwitchTip(r.all, L.rpgAllTip)
        r.all:SetScript("OnClick", function(self)
            P.Send("SETMIRROR", 0, r.key, self.on and "0" or "1")
        end)
        r.bot = W.Switch(r)
        r.bot:SetPoint("CENTER", r, "RIGHT", -COL_W / 2, 0)
        r.bot.tipTitle = def[2]
        SwitchTip(r.bot, L.rpgBotTip)
        r.bot:SetScript("OnClick", function(self)
            local low = Cur()
            if low and PlayerOn(r.key) then
                P.Send("SETMIRROR", low, r.key, self.on and "0" or "1")
            end
        end)
        Line(r)
        ui.rows[i] = r
    end

    local y = -16 - #ROWS * ROW_H - 6
    ui.reward = W.Pick(panel, 260, 20, false, true)
    ui.reward:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, y)
    ui.reward.onEnter = function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L.rpgRewardTip, 1, 1, 1, 1, 1)
        GameTooltip:Show()
    end
    ui.reward:SetScript("OnClick", function(self)
        local cur = BT.mirror.set.reward
        local items = {}
        for _, o in ipairs({ { "best", L.rpgRewardBest }, { "same", L.rpgRewardSame } }) do
            local id = o[1]
            items[#items + 1] = { text = o[2], checked = cur == id, func = function()
                CloseDropDownMenus()
                P.Send("SETMIRROR", 0, "reward", id)
            end }
        end
        W.ShowMenu(self, items)
    end)

    y = y - 26
    ui.off = W.Text(panel, "GameFontHighlightSmall", W.WARN)
    ui.off:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, y)
    ui.off:SetHeight(12)
    ui.offZone = W.TextZone(panel, ui.off)

    y = y - 18
    ui.feedTitle = W.Text(panel, "GameFontNormalSmall", W.GOLD_DIM)
    ui.feedTitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, y)
    ui.feedTitle:SetText(L.rpgFeed)
    y = y - 16
    ui.feed = {}
    for i = 1, FEED_ROWS do
        local r = CreateFrame("Frame", nil, panel)
        r:SetHeight(FEED_ROW_H)
        r:SetWidth(innerW)
        r:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, y - (i - 1) * FEED_ROW_H)
        r.text = W.Text(r, "GameFontHighlightSmall", W.TEXT)
        r.text:SetPoint("LEFT", 0, 0)
        r.text:SetPoint("RIGHT", 0, 0)
        r.text:SetHeight(12)
        r:EnableMouse(true)
        r:SetScript("OnEnter", function(self)
            if not self.entry then
                return
            end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(self.full or "", 1, 1, 1, 1, 1)
            GameTooltip:AddLine(string.format(L.rpgAgo, Age(GetTime() - (self.entry.at or GetTime()))), 0.6, 0.6, 0.6)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", RowLeave)
        r:Hide()
        ui.feed[i] = r
    end
    ui.feedEmpty = W.Text(panel, "GameFontDisableSmall", W.FAINT)
    ui.feedEmpty:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, y)
    ui.innerW = innerW
end

-- ---------------------------------------------------------------- render

local function EnableSwitch(b, on)
    W.Enable(b, on)
    b:SetAlpha(on and 1 or 0.45)
end

function M.Render()
    if not ui.panel then
        return
    end
    local open = ui.panel:IsShown()
    W.SetTabSelected(ui.open, open)
    if not open then
        return
    end
    local m = BT.mirror
    local low = Cur()
    local owned = low and BT.Party.IsOwned and BT.Party.IsOwned(low)
    ui.headAll:SetText(L.rpgAll)
    W.FitText(ui.headBot, owned and BotName(low) or "-", COL_W, ui.headBotZone)
    for _, r in ipairs(ui.rows) do
        W.FitText(r.label, r.title, r.labelW, r)
        local pOn = PlayerOn(r.key)
        W.SetSwitch(r.all, pOn)
        EnableSwitch(r.all, m.got)
        W.SetSwitch(r.bot, pOn and owned and BotOn(low, r.key))
        EnableSwitch(r.bot, m.got and pOn and owned and true or false)
    end
    local mode = m.set.reward == "same" and L.rpgRewardSame or L.rpgRewardBest
    W.SetPickText(ui.reward, string.format(L.rpgReward, mode))
    W.Enable(ui.reward, m.got)
    if m.err then
        W.FitText(ui.off, BT.Show(m.err), ui.innerW, ui.offZone)
        ui.off:Show()
    elseif m.got and not m.server.enable then
        W.FitText(ui.off, L.rpgOffServer, ui.innerW, ui.offZone)
        ui.off:Show()
    else
        ui.off:Hide()
    end

    local feed = m.feed
    for i = 1, FEED_ROWS do
        local r = ui.feed[i]
        local e = feed[#feed - (i - 1)]      -- newest first
        if e then
            local name = BT.Show(BotName(e.bot))
            local text = BT.Show(e.text)
            local colour = e.ok and "|cffeeddc4" or "|cffe8a33d"
            r.entry = e
            r.full = name .. ": " .. text   -- the row's own tooltip always shows the whole line
            W.FitText(r.text, "|cffd9b566" .. name .. "|r: " .. colour .. text .. "|r", ui.innerW)
            r:Show()
        else
            r.entry = nil
            r:Hide()
        end
    end
    ui.feedEmpty:SetText(L.rpgFeedNone)
    W.Show(ui.feedEmpty, #feed == 0)
end

function M.Toggle(show)
    if not ui.panel then
        return
    end
    if show == nil then
        show = not ui.panel:IsShown()
    end
    CloseDropDownMenus()
    if show then
        BT.mirror.err = nil
        ui.panel:Show()
        P.Send("MIRROR")
        P.Send("MIRRORLOG", FEED_MAX)
    else
        ui.panel:Hide()
    end
    M.Render()
end

-- Called once by Misc.lua with the Quests card.
function M.Attach(questCard)
    if ui.panel or not questCard then
        return
    end
    Build(questCard)
    if BT.Party and BT.Party.OnSelect then
        BT.Party.OnSelect(function()
            M.Render()
        end)
    end
end

-- Widgets for the mock tests (scratchpad bt_test).
function M.ForTest()
    return ui
end
