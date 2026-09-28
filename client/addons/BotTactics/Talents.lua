-- Tab "Talents" (party-window spec 6.6): the bot's three trees with authentic backgrounds, local
-- editing (LMB +1 / RMB -1 with the rules of spec 5.5), apply, spec switch / dual spec, trainer.

local BT = BotTactics
local L, W, K = BT.L, BT.W, BT.TabKit
local S = BT.S

L.talents_tab = S("Talents", "Таланты")
L.talents_points = S("Spent %s  -  free: %d", "Распределено %s  -  свободно %d")
L.talents_spec = S("Spec %d", "Спек %d")
L.talents_learnDual = S("Second (lvl %d)", "Вторая (%d ур.)")
L.talents_learnDualTip = S("Learn the second talent specialization", "Освоить вторую специализацию талантов")
L.talents_apply = S("Apply", "Применить")
L.talents_revert = S("Revert", "Отменить")
L.talents_revertTip = S("Drop the changes that are not applied yet", "Сбросить изменения, которые ещё не применены")
L.talents_train = S("Learn all from the trainer", "Выучить всё у наставника")
L.talents_trainShort = S("Trainer", "Наставник")
L.talents_trainCount = S("Trainer: learn %d", "Наставник: выучить %d")
L.talents_readOnlyShort = S("view only", "только просмотр")
L.talents_trainInfo = S("%d spells, %s", "%d заклинаний, %s")
L.talents_trainNone = S("No trainer next to the bot", "Рядом с ботом нет наставника")
L.talents_trainNothing = S("Nothing new to learn at %s", "Нечему учиться у: %s")
L.talents_readOnly = S("Switch to this spec to edit it", "Переключите специализацию, чтобы менять")
L.talents_help = S("LMB - add a point, RMB - take it back.", "ЛКМ - вложить очко, ПКМ - забрать.")
L.talents_loading = S("Loading talents...", "Загрузка талантов...")
L.talents_noPoints = S("No free talent points", "Нет свободных очков")
L.talents_locked = S("Requires %d points in the rows above", "Нужно %d очков в рядах выше")
L.talents_needDep = S("Requires another talent first", "Сначала нужен другой талант")
L.talents_cannotRemove = S("Other talents depend on this point", "От этого очка зависят другие таланты")
L.talents_rank = S("Rank %d/%d", "Ранг %d/%d")
L.talents_sent = S("Applying talents...", "Применяю таланты...")
L.talents_dualConfirm = S("Learn the second talent specialization for this bot?", "Освоить боту вторую специализацию талантов?")
-- premade builds and glyphs (party-extras-spec 6.1)
L.talents_premade = S("Premade builds", "Готовые раскладки")
L.talents_premadeNone = S("No premade builds for this class", "Для этого класса нет готовых раскладок")
L.talents_premadeConfirm = S("Replace the current talents of %s with \"%s\" (%s)?", "Заменить текущие таланты %s на «%s» (%s)?")
L.talents_premadeSent = S("Applying the premade build...", "Применяю готовую раскладку...")
L.talents_glyphs = S("Glyphs", "Символы")
L.talents_trees = S("Talents", "Таланты")
L.talents_glyphMajor = S("Major", "Большой")
L.talents_glyphMinor = S("Minor", "Малый")
L.talents_glyphLocked = S("Unlocks at level %d", "Открывается на %d уровне")
L.talents_glyphEmpty = S("Empty socket", "Пустая ячейка")
L.talents_glyphBag = S("Glyphs in the bags", "Символы в сумках")
L.talents_glyphBagNone = S("No glyph items in the bags", "В сумках нет символов")
L.talents_glyphPut = S("Socket %d (%s, lvl %d)", "Ячейка %d (%s, %d ур.)")
L.talents_glyphReplace = S(" - replaces %s", " - заменит %s")
L.talents_glyphNoSocket = S("No free socket of this kind", "Нет свободной ячейки этого вида")
L.talents_glyphRemove = S("Remove glyph", "Убрать символ")
L.talents_glyphRemoveConfirm = S("Remove \"%s\" from socket %d? The glyph item is lost.", "Убрать «%s» из ячейки %d? Предмет-символ пропадёт.")
L.talents_glyphRight = S("Right-click: remove", "ПКМ: убрать")
L.talents_glyphLevel = S("%s - lvl %d", "%s - %d ур.")

local T = {}
BT.Talents = T

-- TTREE cache per class, TALENTS/TRAINER per bot
BT.talentTrees = BT.talentTrees or {}
local trees = BT.talentTrees
local talentState = {}
local trainers = {}
T.state, T.trainers = talentState, trainers
-- PRESPECS / GLYPHS per bot, shown view per bot (party-extras-spec 6.1)
T.premade, T.glyphs, T.view = {}, {}, {}

local TREE_W, TREE_H, HEAD_H, TREE_GAP = 296, 540, 30, 8
local BODY_W = 292
local ALL_W = TREE_W * 3 + TREE_GAP * 2
local ALL_H = TREE_H + HEAD_H + 4
local TOP_H = 58
local POINTS_PER_TIER = 5
local GOLD_C = { 1, 0.82, 0 }
local GREEN_C = { 0.12, 1, 0 }
local GREY_C = { 0.48, 0.48, 0.48 }
local ARROWS = "Interface\\TalentFrame\\UI-TalentArrows"
-- Blizzard TalentFrameBase: TALENT_ARROW_TEXTURECOORDS ([1] = active, [-1] = inactive)
local ARROW_TC = {
    top = { [1] = { 0, 0.5, 0, 0.5 }, [-1] = { 0, 0.5, 0.5, 1.0 } },
    right = { [1] = { 1.0, 0.5, 0, 0.5 }, [-1] = { 1.0, 0.5, 0.5, 1.0 } },
    left = { [1] = { 0.5, 1.0, 0, 0.5 }, [-1] = { 0.5, 1.0, 0.5, 1.0 } },
}

local function X(col) return 30 + col * 62 end
local function Y(row) return 16 + row * 47 end

-- ---------------------------------------------------------------- data

local function ParseTree(f)
    local cls = tonumber(f[2])
    if not cls then
        return
    end
    local t = { rows = {}, byId = {}, tabs = { [0] = {}, [1] = {}, [2] = {} } }
    for _, e in ipairs(BT.List(f[3])) do
        local s = BT.Split(e, ",")
        local id = tonumber(s[1])
        if id then
            local ranks = {}
            for _, r in ipairs(BT.List(s[8], ":")) do
                ranks[#ranks + 1] = tonumber(r)
            end
            local row = {
                id = id, tab = tonumber(s[2]) or 0, row = tonumber(s[3]) or 0, col = tonumber(s[4]) or 0,
                max = tonumber(s[5]) or #ranks, dep = tonumber(s[6]) or 0, depRank = tonumber(s[7]) or 0,
                ranks = ranks,
            }
            if row.max > #ranks then
                row.max = #ranks
            end
            t.rows[#t.rows + 1] = row
            t.byId[id] = row
            local tab = t.tabs[row.tab]
            if tab then
                tab[#tab + 1] = row
            end
        end
    end
    trees[cls] = t
    return cls
end

local function ParseTalents(f)
    local low = tonumber(f[2])
    if not low then
        return
    end
    local st = {
        active = tonumber(f[3]) or 1, count = tonumber(f[4]) or 1, spec = tonumber(f[5]) or 1,
        free = tonumber(f[6]) or 0, total = tonumber(f[7]) or 0, minDual = tonumber(f[8]) or 40,
        server = {}, ranks = {},
    }
    for _, e in ipairs(BT.List(f[9])) do
        local id, r = string.match(e, "^(%d+):(%d+)$")
        if id then
            st.server[tonumber(id)] = tonumber(r)
            st.ranks[tonumber(id)] = tonumber(r)
        end
    end
    talentState[low] = st
    return low
end

local function ParseTrainer(f)
    local low = tonumber(f[2])
    if not low then
        return
    end
    local tr = { npc = BT.Unesc(f[3]), rows = {}, can = 0, cost = 0 }
    for _, e in ipairs(BT.List(f[4])) do
        local s = BT.Split(e, ",")
        local spell = tonumber(s[1])
        if spell then
            local row = { spell = spell, cost = tonumber(s[2]) or 0, can = s[3] == "1" }
            tr.rows[#tr.rows + 1] = row
            if row.can then
                tr.can = tr.can + 1
                tr.cost = tr.cost + row.cost
            end
        end
    end
    trainers[low] = tr
    return low
end

-- PRESPECS <bot> <level> <entries>: no,nameEsc,t0-t1-t2,glyphItems (glyph items joined by ":")
local function ParsePremade(f)
    local low = tonumber(f[2])
    if not low then
        return
    end
    local list = {}
    for _, e in ipairs(BT.List(f[4])) do
        local s = BT.Split(e, ",")
        local no = tonumber(s[1])
        if no then
            local p = BT.Split(s[3] or "", "-")
            local glyphs = {}
            for _, g in ipairs(BT.List(s[4], ":")) do
                glyphs[#glyphs + 1] = tonumber(g)
            end
            list[#list + 1] = {
                no = no, name = BT.Unesc(s[2]), t0 = tonumber(p[1]) or 0, t1 = tonumber(p[2]) or 0,
                t2 = tonumber(p[3]) or 0, glyphs = glyphs,
            }
        end
    end
    T.premade[low] = { level = tonumber(f[3]) or 0, list = list }
    return low
end

-- GLYPHS <bot> <enabled> <slots> <bag>: slots slot,kind,level,glyph,spell (0..5);
-- bag bag,slot,guid,entry,glyph,kind,spell (guid echoed verbatim in GLYPH apply)
local GLYPH_SLOT_LEVEL = { [0] = 15, 15, 50, 30, 70, 80 }
local function ParseGlyphs(f)
    local low = tonumber(f[2])
    if not low then
        return
    end
    local g = { enabled = tonumber(f[3]) or 0, slots = {}, bag = {} }
    for _, e in ipairs(BT.List(f[4])) do
        local s = BT.Split(e, ",")
        local slot = tonumber(s[1])
        if slot and slot >= 0 and slot <= 5 then
            g.slots[slot] = {
                slot = slot, kind = tonumber(s[2]) or 0, level = tonumber(s[3]) or GLYPH_SLOT_LEVEL[slot],
                glyph = tonumber(s[4]) or 0, spell = tonumber(s[5]) or 0,
            }
        end
    end
    for _, e in ipairs(BT.List(f[5])) do
        local s = BT.Split(e, ",")
        local entry = tonumber(s[4])
        if entry then
            g.bag[#g.bag + 1] = {
                bag = tonumber(s[1]) or 0, slot = tonumber(s[2]) or 0, guid = s[3] or "0", entry = entry,
                glyph = tonumber(s[5]) or 0, kind = tonumber(s[6]) or 0, spell = tonumber(s[7]) or 0,
            }
        end
    end
    T.glyphs[low] = g
    return low
end

-- Bit `slot` of the PLAYER_GLYPHS_ENABLED mask.
local function SocketEnabled(g, slot)
    return math.floor((g and g.enabled or 0) / 2 ^ slot) % 2 == 1
end
T.SocketEnabled = SocketEnabled

local function BotClass(low)
    local b = K.Bot(low)
    return b and tonumber(b.class)
end

-- ---------------------------------------------------------------- rules (spec 5.5, same as the server)

local function Spent(tree, ranks, tab)
    local n = 0
    for _, row in ipairs(tab and tree.tabs[tab] or tree.rows) do
        n = n + (ranks[row.id] or 0)
    end
    return n
end

-- Points in rows above `row` of the tree.
local function PointsAbove(tree, ranks, tab, row)
    local n = 0
    for _, t in ipairs(tree.tabs[tab]) do
        if t.row < row then
            n = n + (ranks[t.id] or 0)
        end
    end
    return n
end

-- DependsOnRank in Talent.dbc is 0-based (Player::LearnTalent checks RankID[DependsOnRank..]).
local function DepOk(ranks, t)
    return t.dep == 0 or (ranks[t.dep] or 0) >= t.depRank + 1
end
T.DepOk = DepOk

-- ok, reasonText of a whole build
function T.Validate(tree, ranks, total)
    if Spent(tree, ranks) > total then
        return false, L.talents_noPoints
    end
    for _, t in ipairs(tree.rows) do
        local r = ranks[t.id] or 0
        if r > 0 then
            if r > t.max then
                return false, L.talents_noPoints
            end
            if PointsAbove(tree, ranks, t.tab, t.row) < t.row * POINTS_PER_TIER then
                return false, string.format(L.talents_locked, t.row * POINTS_PER_TIER)
            end
            if not DepOk(ranks, t) then
                return false, L.talents_needDep
            end
        end
    end
    return true
end

local function Editable(st)
    return st and st.spec == st.active
end

local function Dirty(st)
    if not st then
        return false
    end
    for id, r in pairs(st.ranks) do
        if (st.server[id] or 0) ~= r then
            return true
        end
    end
    for id, r in pairs(st.server) do
        if (st.ranks[id] or 0) ~= r then
            return true
        end
    end
    return false
end
T.Dirty = Dirty

-- One point up (dir 1) or down (dir -1) on the local copy; returns ok, reason.
function T.Step(low, id, dir)
    local st = talentState[low]
    local tree = trees[BotClass(low) or 0]
    local t = tree and tree.byId[id]
    if not st or not t then
        return false
    end
    if not Editable(st) then
        return false, L.talents_readOnly
    end
    local r = st.ranks[id] or 0
    local nr = r + dir
    if nr < 0 or nr > t.max then
        return false
    end
    if dir > 0 and Spent(tree, st.ranks) >= st.total then
        return false, L.talents_noPoints
    end
    local copy = {}
    for k, v in pairs(st.ranks) do
        copy[k] = v
    end
    copy[id] = nr
    local ok, why = T.Validate(tree, copy, st.total)
    if not ok then
        if dir < 0 then
            why = L.talents_cannotRemove
        end
        return false, why
    end
    st.ranks[id] = nr > 0 and nr or nil
    return true
end

-- TAPPLY payload field: "id:rank;..." of every talent with rank > 0, in tree order.
function T.RanksText(low)
    local st = talentState[low]
    local tree = trees[BotClass(low) or 0]
    if not st or not tree then
        return nil
    end
    local out = {}
    for _, t in ipairs(tree.rows) do
        local r = st.ranks[t.id] or 0
        if r > 0 then
            out[#out + 1] = t.id .. ":" .. r
        end
    end
    return table.concat(out, ";")
end

-- ---------------------------------------------------------------- pane

local pane
local ui = { trees = {} }
T.ui = ui

local function Render() T.Render() end

local function Request(low)
    local cls = BotClass(low)
    if cls and not trees[cls] then
        K.Send("TTREE", cls)
    end
    K.Send("TALENTS", low, 0)
    K.Send("TRAIN", low, 0)
    K.Send("PRESPECS", low)
    K.Send("GLYPHS", low)
    K.Inspect(low)
end

pane = K.Tab("talents", L.talents_tab, Request, Render)
T.pane = pane

-- header row
ui.points = W.Text(pane, "GameFontHighlight", W.TEXT)
ui.points:SetPoint("TOPLEFT", 4, -6)

ui.spec = {}
for i = 1, 2 do
    local b = W.Tab(pane, 22)
    b:SetScript("OnClick", function() T.SpecClick(i) end)
    ui.spec[i] = b
end

ui.apply = W.Tab(pane, 22)
W.FitTab(ui.apply, L.talents_apply, 90)
ui.apply:SetScript("OnClick", function() T.Apply() end)
ui.revert = W.Tab(pane, 22)
W.FitTab(ui.revert, L.talents_revert, 70)
ui.revert.tip = L.talents_revertTip
ui.revert:SetScript("OnClick", function() T.Revert() end)
W.SetTabSelected(ui.revert, false)

-- trainer: one button, what it would teach is its tooltip (party-ui-audit L2)
ui.train = W.Tab(pane, 22)
W.FitTab(ui.train, L.talents_trainShort, 90)
W.SetTabSelected(ui.train, false)
ui.train:SetScript("OnClick", function()
    local low = K.Current()
    if low then
        K.Send("TRAIN", low, 1)
    end
end)

-- second header line: premade builds, view switch (party-extras-spec 6.1), hint, trainer
ui.premade = W.Pick(pane, 170, 22, false, true)
ui.premade.text:SetText(L.talents_premade)
ui.premade:SetPoint("TOPLEFT", 4, -30)
ui.premade:SetScript("OnClick", function(self)
    T.PremadeMenu(self)
end)
ui.viewTrees = W.Tab(pane, 22)
W.FitTab(ui.viewTrees, L.talents_trees, 70)
ui.viewTrees:SetPoint("LEFT", ui.premade, "RIGHT", 8, 0)
ui.viewTrees:SetScript("OnClick", function() T.SetView("trees") end)
ui.viewGlyphs = W.Tab(pane, 22)
W.FitTab(ui.viewGlyphs, L.talents_glyphs, 70)
ui.viewGlyphs:SetPoint("LEFT", ui.viewTrees, "RIGHT", 2, 0)
ui.viewGlyphs:SetScript("OnClick", function() T.SetView("glyphs") end)


ui.loading = W.Text(pane, "GameFontDisable", W.MUTED, "CENTER")
ui.loading:SetPoint("CENTER")
ui.loading:SetText(L.talents_loading)

-- trees: a scroll frame scaled so the three trees fit the pane width
local scroll, child = K.Scroll(pane, "BotTacticsTalentScroll", ALL_W)
child:SetHeight(ALL_H)
ui.scroll = scroll

local function TalentTooltip(self)
    local low = K.Current()
    local st = talentState[low]
    local t = self.talent
    if not t then
        return
    end
    local r = st and st.ranks[t.id] or 0
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local id = t.ranks[math.max(1, r)] or t.ranks[1]
    if id then
        GameTooltip:SetHyperlink("spell:" .. id)
    end
    GameTooltip:AddLine(string.format(L.talents_rank, r, t.max), 1, 0.82, 0)
    if Editable(st) then
        GameTooltip:AddLine(L.talents_help, 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

local function TalentButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(36)
    b:SetHeight(36)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 2, -2)
    b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    local badge = CreateFrame("Frame", nil, b)
    badge:SetWidth(26)
    badge:SetHeight(14)
    badge:SetPoint("BOTTOMRIGHT", 9, -7)
    badge:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    badge:SetBackdropColor(0, 0, 0, 0.9)
    badge:SetBackdropBorderColor(0.27, 0.27, 0.27)
    b.rank = badge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.rank:SetPoint("CENTER", 0, 0)
    b:SetScript("OnClick", function(self, button)
        T.Click(self.talent, button == "RightButton" and -1 or 1)
    end)
    b:SetScript("OnEnter", TalentTooltip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

for tab = 0, 2 do
    local tr = {}
    local f = CreateFrame("Frame", nil, child)
    f:SetWidth(TREE_W)
    f:SetHeight(ALL_H)
    f:SetPoint("TOPLEFT", tab * (TREE_W + TREE_GAP), 0)
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
    f:SetBackdropColor(0, 0, 0, 1)
    f:SetBackdropBorderColor(0.35, 0.29, 0.18)
    tr.frame = f

    local head = f:CreateTexture(nil, "BACKGROUND")
    head:SetTexture(0.20, 0.15, 0.09, 1)
    head:SetPoint("TOPLEFT", 2, -2)
    head:SetPoint("TOPRIGHT", -2, -2)
    head:SetHeight(HEAD_H)
    tr.icon = f:CreateTexture(nil, "ARTWORK")
    tr.icon:SetWidth(24)
    tr.icon:SetHeight(24)
    tr.icon:SetPoint("TOPLEFT", 8, -5)
    tr.name = W.Text(f, "GameFontNormal", GOLD_C)
    tr.name:SetPoint("LEFT", tr.icon, "RIGHT", 8, 0)
    tr.spent = W.Text(f, "GameFontHighlight", { 1, 1, 1 }, "RIGHT")
    tr.spent:SetPoint("TOPRIGHT", -10, -11)

    local body = CreateFrame("Frame", nil, f)
    body:SetWidth(BODY_W)
    body:SetHeight(TREE_H)
    body:SetPoint("TOPLEFT", 2, -(HEAD_H + 2))
    tr.body = body
    -- background: TopLeft 256x256, TopRight 64x256, BottomLeft 256x128, BottomRight 64x128 stretched to the body
    tr.bg = {}
    local wl, hl = math.floor(BODY_W * 0.8), math.floor(TREE_H * 2 / 3)
    local parts = {
        { "TopLeft", wl, hl, 0, 0 }, { "TopRight", BODY_W - wl, hl, wl, 0 },
        { "BottomLeft", wl, TREE_H - hl, 0, -hl }, { "BottomRight", BODY_W - wl, TREE_H - hl, wl, -hl },
    }
    for i, p in ipairs(parts) do
        local t = body:CreateTexture(nil, "BACKGROUND")
        t:SetWidth(p[2])
        t:SetHeight(p[3])
        t:SetPoint("TOPLEFT", p[4], p[5])
        t.suffix = p[1]
        tr.bg[i] = t
    end
    tr.lines, tr.arrows, tr.buttons = {}, {}, {}
    ui.trees[tab] = tr
end

-- pools
local function Line(tr, i)
    local t = tr.lines[i]
    if not t then
        t = tr.body:CreateTexture(nil, "BORDER")
        t:SetTexture("Interface\\Buttons\\WHITE8X8")
        tr.lines[i] = t
    end
    t:Show()
    return t
end

local function Arrow(tr, i)
    local t = tr.arrows[i]
    if not t then
        t = tr.body:CreateTexture(nil, "OVERLAY")
        t:SetTexture(ARROWS)
        t:SetWidth(24)
        t:SetHeight(24)
        tr.arrows[i] = t
    end
    t:Show()
    return t
end

local function Button(tr, i)
    local b = tr.buttons[i]
    if not b then
        b = TalentButton(tr.body)
        tr.buttons[i] = b
    end
    b:Show()
    return b
end

-- ---------------------------------------------------------------- glyph pane (party-extras-spec 6.1)

local GLYPH_BAG_ROWS, GLYPH_ROW_H = 12, 24
local EMPTY_SOCKET = "Interface\\PaperDoll\\UI-Backpack-EmptySlot"
-- MAJOR column = slots 0, 3, 5; MINOR column = slots 1, 2, 4 (by unlock level, top to bottom)
local SOCKET_POS = { [0] = { 1, 1 }, [3] = { 1, 2 }, [5] = { 1, 3 }, [1] = { 2, 1 }, [2] = { 2, 2 }, [4] = { 2, 3 } }

local function KindLabel(kind)
    return kind == 1 and L.talents_glyphMinor or L.talents_glyphMajor
end

local glyphPane = CreateFrame("Frame", "BotTacticsGlyphPane", pane)
glyphPane:Hide()
ui.glyphPane = glyphPane

local colHead = {}
for c = 1, 2 do
    local fs = W.Text(glyphPane, "GameFontNormalSmall", W.GOLD_DIM, "CENTER")
    fs:SetWidth(110)
    fs:SetPoint("TOP", glyphPane, "TOPLEFT", 70 + (c - 1) * 120, -6)
    fs:SetText(c == 1 and L.talents_glyphMajor or L.talents_glyphMinor)
    colHead[c] = fs
end
ui.glyphHeads = colHead

local function SocketTooltip(self)
    local g = T.glyphs[K.Current()]
    local s = g and g.slots[self.slot]
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if s and s.glyph ~= 0 and s.spell ~= 0 then
        GameTooltip:SetHyperlink("spell:" .. s.spell)
        GameTooltip:AddLine(L.talents_glyphRight, 0.6, 0.6, 0.6)
    elseif s and not SocketEnabled(g, self.slot) then
        GameTooltip:SetText(string.format(L.talents_glyphLocked, s.level), 1, 1, 1)
    else
        GameTooltip:SetText(L.talents_glyphEmpty, 1, 1, 1)
        if s then
            GameTooltip:AddLine(KindLabel(s.kind), 0.6, 0.6, 0.6)
        end
    end
    GameTooltip:Show()
end

local sockets = {}
for slot = 0, 5 do
    local name = "BotTacticsGlyphSocket" .. slot
    local b = CreateFrame("Button", name, glyphPane, "ItemButtonTemplate")
    b.slot = slot
    b:SetWidth(40)
    b:SetHeight(40)
    local pos = SOCKET_POS[slot]
    b:SetPoint("TOP", glyphPane, "TOPLEFT", 70 + (pos[1] - 1) * 120, -26 - (pos[2] - 1) * 76)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.icon = _G[name .. "IconTexture"] or b:CreateTexture(nil, "BORDER")
    b.icon:SetAllPoints(b)
    b.caption = W.Text(glyphPane, "GameFontDisableSmall", W.MUTED, "CENTER")
    b.caption:SetWidth(116)
    b.caption:SetPoint("TOP", b, "BOTTOM", 0, -4)
    b:SetScript("OnEnter", SocketTooltip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            T.RemoveGlyph(self.slot)
        end
    end)
    sockets[slot] = b
end

local glyphCard = K.Card(glyphPane, L.talents_glyphBag)
glyphCard:SetPoint("TOPLEFT", glyphPane, "TOPLEFT", 270, -4)
glyphCard:SetHeight(GLYPH_BAG_ROWS * GLYPH_ROW_H + 36)
glyphCard:EnableMouseWheel(true)
glyphCard:SetScript("OnMouseWheel", function(_, delta) T.ScrollGlyphs(delta) end)
ui.glyphCard = glyphCard
ui.glyphOffset = 0

local glyphNone = W.Text(glyphCard, "GameFontDisableSmall", W.FAINT)
glyphNone:SetPoint("TOPLEFT", 10, -28)
glyphNone:SetText(L.talents_glyphBagNone)

local function GlyphRowTooltip(self)
    local r = self.row
    if not r then
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink("item:" .. r.entry)
    GameTooltip:Show()
end

local glyphRows = {}
for i = 1, GLYPH_BAG_ROWS do
    local r = CreateFrame("Button", nil, glyphCard)
    r:SetHeight(GLYPH_ROW_H - 2)
    r:SetPoint("TOPLEFT", 8, -24 - (i - 1) * GLYPH_ROW_H)
    r:SetPoint("RIGHT", glyphCard, "RIGHT", -8, 0)
    r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetWidth(18)
    r.icon:SetHeight(18)
    r.icon:SetPoint("LEFT", 2, 0)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    r.kind = W.Text(r, "GameFontDisableSmall", W.MUTED, "RIGHT")
    r.kind:SetPoint("RIGHT", -4, 0)
    r.kind:SetWidth(90)
    r.text = W.Text(r, "GameFontHighlightSmall", W.TEXT)
    r.text:SetPoint("LEFT", 26, 0)
    r.text:SetPoint("RIGHT", r.kind, "LEFT", -4, 0)
    r.text:SetHeight(12)
    r:EnableMouseWheel(true)
    r:SetScript("OnMouseWheel", function(_, delta) T.ScrollGlyphs(delta) end)
    r:SetScript("OnEnter", GlyphRowTooltip)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:SetScript("OnClick", function(self)
        T.GlyphMenu(self)
    end)
    r:Hide()
    glyphRows[i] = r
end

local glyphRetry = {}

local function RenderGlyphs(low)
    local g = low and T.glyphs[low]
    for slot = 0, 5 do
        local b = sockets[slot]
        local s = g and g.slots[slot]
        W.Show(b, s ~= nil)
        W.Show(b.caption, s ~= nil)
        if s then
            local enabled = SocketEnabled(g, slot)
            local icon = s.glyph ~= 0 and s.spell ~= 0 and select(3, GetSpellInfo(s.spell))
            if s.glyph ~= 0 then
                b.icon:SetTexture(icon or BT.ICON_UNKNOWN)
                b.icon:SetAlpha(1)
            else
                b.icon:SetTexture(EMPTY_SOCKET)
                b.icon:SetAlpha(0.8)
            end
            if b.icon.SetDesaturated then
                b.icon:SetDesaturated(not enabled)
            end
            if enabled then
                b.caption:SetText(string.format(L.talents_glyphLevel, KindLabel(s.kind), s.level))
                W.Color(b.caption, W.MUTED)
            else
                b.caption:SetText(string.format(L.talents_glyphLocked, s.level))
                W.Color(b.caption, W.FAINT)
            end
        end
    end
    local list = g and g.bag or {}
    local maxOff = math.max(0, #list - GLYPH_BAG_ROWS)
    if ui.glyphOffset > maxOff then
        ui.glyphOffset = maxOff
    end
    local bags = BT.bags and BT.bags[low]
    local missing = false
    for i, r in ipairs(glyphRows) do
        local row = list[i + ui.glyphOffset]
        r.row = row
        if row then
            local name, _, quality = GetItemInfo(row.entry)
            if not name then
                missing = true
            end
            r.icon:SetTexture((GetItemIcon and GetItemIcon(row.entry)) or select(10, GetItemInfo(row.entry)) or BT.ICON_UNKNOWN)
            local pos = bags and bags.byPos and bags.byPos[row.bag .. ":" .. row.slot]
            local count = pos and pos.count or 1
            r.text:SetText((name or ("#" .. row.entry)) .. (count > 1 and (" x" .. count) or ""))
            if quality and GetItemQualityColor then
                local cr, cg, cb = GetItemQualityColor(quality)
                r.text:SetTextColor(cr, cg, cb)
            else
                W.Color(r.text, W.TEXT)
            end
            r.kind:SetText(KindLabel(row.kind))
            r:Show()
        else
            r:Hide()
        end
    end
    W.Show(glyphNone, g ~= nil and #list == 0)
    -- names come from the item cache: one more render a second later
    if missing and low and not glyphRetry[low] then
        glyphRetry[low] = true
        BT.After("glyphcache", 1, function()
            if pane:IsVisible() and K.Current() == low then
                T.Render()
            end
        end)
    end
end

function T.ScrollGlyphs(delta)
    ui.glyphOffset = math.max(0, ui.glyphOffset - delta)
    RenderGlyphs(K.Current())
end

-- bot -> last GLYPH apply sent from the menu { slot, bag, bagSlot, guid, retried }
T.lastGlyphApply = T.lastGlyphApply or {}

-- Target sockets of a bag glyph: every enabled socket of the same kind.
function T.GlyphMenu(rowButton)
    local low = K.Current()
    local row = rowButton and rowButton.row
    local g = low and T.glyphs[low]
    if not row or not g then
        return
    end
    local items = { { text = GetItemInfo(row.entry) or ("#" .. row.entry), isTitle = true, notCheckable = true } }
    for slot = 0, 5 do
        local s = g.slots[slot]
        if s and s.kind == row.kind and SocketEnabled(g, slot) then
            local text = string.format(L.talents_glyphPut, slot + 1, KindLabel(s.kind), s.level)
            if s.glyph ~= 0 then
                text = text .. string.format(L.talents_glyphReplace, GetSpellInfo(s.spell) or "?")
            end
            items[#items + 1] = { text = text, notCheckable = true, func = function()
                if CloseDropDownMenus then
                    CloseDropDownMenus()
                end
                -- remembered for the one automatic retry after a "moving" ACK (see the ACK hook)
                T.lastGlyphApply[low] = { slot = slot, bag = row.bag, bagSlot = row.slot, guid = row.guid }
                K.Send("GLYPH", low, "apply", slot, row.bag, row.slot, row.guid)
            end }
        end
    end
    if #items == 1 then
        items[2] = { text = L.talents_glyphNoSocket, notCheckable = true, disabled = true }
    end
    K.Menu(rowButton, items)
end

function T.RemoveGlyph(slot)
    local low = K.Current()
    local g = low and T.glyphs[low]
    local s = g and g.slots[slot]
    if not s or s.glyph == 0 then
        return
    end
    local name = (s.spell ~= 0 and GetSpellInfo(s.spell)) or ("#" .. s.glyph)
    K.Confirm("glyphdel", string.format(L.talents_glyphRemoveConfirm, name, slot + 1), function()
        K.Send("GLYPH", low, "remove", slot, 0, 0, 0)
    end)
end

-- ---------------------------------------------------------------- premade builds

function T.PremadeMenu(anchor)
    local low = K.Current()
    local st = low and talentState[low]
    if not low or not Editable(st) then
        return
    end
    local pm = T.premade[low]
    local b = K.Bot(low)
    local botName = BT.Show(b and b.name or "")
    local items = { { text = L.talents_premade, isTitle = true, notCheckable = true } }
    if not pm then
        items[2] = { text = L.talents_loading, notCheckable = true, disabled = true }
    else
        for _, e in ipairs(pm.list) do
            local pts = e.t0 .. "/" .. e.t1 .. "/" .. e.t2
            local name, no = BT.Show(e.name), e.no
            items[#items + 1] = {
                text = name .. " (" .. pts .. ")", notCheckable = true, disabled = (e.t0 + e.t1 + e.t2 == 0),
                func = function()
                    if CloseDropDownMenus then
                        CloseDropDownMenus()
                    end
                    K.Confirm("prespec", string.format(L.talents_premadeConfirm, botName, name, pts), function()
                        K.Send("PRESPEC", low, no)
                        K.Status(low, L.talents_premadeSent, "busy")
                    end)
                end,
            }
        end
        if #pm.list == 0 then
            items[2] = { text = L.talents_premadeNone, notCheckable = true, disabled = true }
        end
    end
    K.Menu(anchor, items)
end

function T.SetView(view)
    local low = K.Current()
    if not low then
        return
    end
    T.view[low] = view
    if view == "glyphs" and not T.glyphs[low] then
        K.Send("GLYPHS", low)
    end
    T.Render()
end

-- Widgets for the mock tests (scratchpad bt_test).
function T.ForTest()
    return {
        premadePick = ui.premade, viewGlyphs = ui.viewGlyphs, viewTrees = ui.viewTrees, sockets = sockets,
        glyphRows = glyphRows, glyphCard = glyphCard,
    }
end

-- ---------------------------------------------------------------- render

local function SetArrow(a, kind, active, cx, cy)
    local tc = ARROW_TC[kind][active and 1 or -1]
    a:SetTexCoord(tc[1], tc[2], tc[3], tc[4])
    a:ClearAllPoints()
    a:SetPoint("CENTER", a:GetParent(), "TOPLEFT", cx, -cy)
end

-- prerequisite lines (3 px, gold / grey) and arrow heads
local function RenderBranches(tr, tree, ranks, list)
    local nl, na = 0, 0
    local byId = tree.byId
    for _, t in ipairs(list) do
        local p = t.dep ~= 0 and byId[t.dep]
        if p and p.tab == t.tab then
            local ok = DepOk(ranks, t)
            local c = ok and GOLD_C or GREY_C
            local px, py = X(p.col) + 18, Y(p.row) + 18
            local cx, cy = X(t.col) + 18, Y(t.row) + 18
            if p.row == t.row then
                nl = nl + 1
                local ln = Line(tr, nl)
                ln:SetVertexColor(c[1], c[2], c[3], 0.85)
                ln:ClearAllPoints()
                ln:SetPoint("TOPLEFT", tr.body, "TOPLEFT", math.min(px, cx), -(py - 1))
                ln:SetWidth(math.abs(cx - px))
                ln:SetHeight(3)
                na = na + 1
                if cx > px then
                    SetArrow(Arrow(tr, na), "right", ok, cx - 24, cy)
                else
                    SetArrow(Arrow(tr, na), "left", ok, cx + 24, cy)
                end
            else
                if p.col ~= t.col then
                    nl = nl + 1
                    local h = Line(tr, nl)
                    h:SetVertexColor(c[1], c[2], c[3], 0.85)
                    h:ClearAllPoints()
                    h:SetPoint("TOPLEFT", tr.body, "TOPLEFT", math.min(px, cx) - 1, -(py - 1))
                    h:SetWidth(math.abs(cx - px) + 3)
                    h:SetHeight(3)
                end
                nl = nl + 1
                local v = Line(tr, nl)
                v:SetVertexColor(c[1], c[2], c[3], 0.85)
                v:ClearAllPoints()
                local top = (p.col ~= t.col) and py or (py + 18)
                v:SetPoint("TOPLEFT", tr.body, "TOPLEFT", cx - 1, -top)
                v:SetWidth(3)
                v:SetHeight(math.max(1, (cy - 18) - top))
                na = na + 1
                SetArrow(Arrow(tr, na), "top", ok, cx, cy - 22)
            end
        end
    end
    for i = nl + 1, #tr.lines do
        tr.lines[i]:Hide()
    end
    for i = na + 1, #tr.arrows do
        tr.arrows[i]:Hide()
    end
end

local function RenderTree(tab, tree, st, cls)
    local tr = ui.trees[tab]
    local list = tree.tabs[tab] or {}
    local ranks = st.ranks
    local info = BT.TalentTabInfo(cls, tab)
    local firstIcon = list[1] and list[1].ranks[1] and select(3, GetSpellInfo(list[1].ranks[1]))
    tr.icon:SetTexture(info.icon or firstIcon or BT.ICON_UNKNOWN)
    tr.name:SetText(info.name)
    local inTree = Spent(tree, ranks, tab)
    tr.spent:SetText(inTree)
    for _, t in ipairs(tr.bg) do
        if info.bg then
            t:SetTexture("Interface\\TalentFrame\\" .. info.bg .. "-" .. t.suffix)
            t:Show()
        else
            t:Hide()
        end
    end
    RenderBranches(tr, tree, ranks, list)
    local free = st.total - Spent(tree, ranks)
    local editable = Editable(st)
    for i, t in ipairs(list) do
        local b = Button(tr, i)
        b.talent = t
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", tr.body, "TOPLEFT", X(t.col), -Y(t.row))
        local r = ranks[t.id] or 0
        local icon = t.ranks[1] and select(3, GetSpellInfo(t.ranks[1]))
        b.icon:SetTexture(icon or BT.ICON_UNKNOWN)
        local avail = PointsAbove(tree, ranks, tab, t.row) >= t.row * POINTS_PER_TIER and DepOk(ranks, t)
        local c
        if r >= t.max then
            c = GOLD_C
        elseif r > 0 or (avail and free > 0 and editable) then
            c = GREEN_C
        else
            c = GREY_C
        end
        b:SetBackdropBorderColor(c[1], c[2], c[3])
        b.rank:SetText(r .. "/" .. t.max)
        b.rank:SetTextColor(c[1], c[2], c[3])
        local locked = r == 0 and not avail
        if b.icon.SetDesaturated then
            b.icon:SetDesaturated(locked or (r == 0 and not editable))
        end
        if locked then
            b.icon:SetVertexColor(0.55, 0.55, 0.55)
        else
            b.icon:SetVertexColor(1, 1, 1)
        end
    end
    for i = #list + 1, #tr.buttons do
        tr.buttons[i]:Hide()
    end
end

function T.Layout()
    local w, h = K.PaneSize(pane)
    local scale = math.min(1, (w - 24) / ALL_W)
    scroll:SetScale(scale)
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -TOP_H)
    scroll:SetWidth(ALL_W)
    scroll:SetHeight((h - TOP_H) / scale)
    -- the template draws its scroll bar even when the trees fit (party-ui-audit L3)
    local bar = _G["BotTacticsTalentScrollScrollBar"]
    if bar then
        W.Show(bar, ALL_H > (h - TOP_H) / scale)
    end
    glyphPane:ClearAllPoints()
    glyphPane:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -TOP_H)
    glyphPane:SetWidth(w)
    glyphPane:SetHeight(h - TOP_H)
    glyphCard:SetWidth(math.max(200, math.min(440, w - 280)))
end

function T.Render()
    T.Layout()
    local low = K.Current()
    local cls = BotClass(low)
    local tree = cls and trees[cls]
    local st = low and talentState[low]
    local b = K.Bot(low)
    local ready = tree and st
    local glyphView = low and T.view[low] == "glyphs"
    W.Show(scroll, ready and not glyphView)
    W.Show(glyphPane, glyphView)
    if glyphView then
        W.Show(ui.loading, not T.glyphs[low])
    else
        W.Show(ui.loading, low and not ready)
    end
    W.SetTabSelected(ui.viewTrees, not glyphView)
    W.SetTabSelected(ui.viewGlyphs, glyphView and true or false)
    K.Enable(ui.viewTrees, low ~= nil)
    K.Enable(ui.viewGlyphs, low ~= nil)
    local pm = low and T.premade[low]
    ui.premade.text:SetText(L.talents_premade .. (pm and #pm.list > 0 and (" (" .. #pm.list .. ")") or ""))
    K.Enable(ui.premade, Editable(st) and true or false)

    -- spec buttons
    local x = 4
    ui.points:ClearAllPoints()
    ui.points:SetPoint("TOPLEFT", 4, -8)
    if ready then
        local pts = {}
        for tab = 0, 2 do
            pts[#pts + 1] = Spent(tree, st.ranks, tab)
        end
        local text = string.format(L.talents_points, "|cff1eff00" .. table.concat(pts, "/") .. "|r",
            math.max(0, st.total - Spent(tree, st.ranks)))
        -- the other spec is shown read-only; clicking a talent says why in the status line
        if not Editable(st) then
            text = text .. "  |cffe8a33d(" .. L.talents_readOnlyShort .. ")|r"
        end
        ui.points:SetText(text)
    else
        ui.points:SetText("")
    end
    x = x + math.max(200, ui.points:GetStringWidth() + 16)
    for i = 1, 2 do
        local sb = ui.spec[i]
        local label = string.format(L.talents_spec, i)
        local enabled = st ~= nil
        sb.tip = nil
        if i == 2 and st and st.count < 2 then
            label = string.format(L.talents_learnDual, st.minDual)
            enabled = (b and b.level or 0) >= st.minDual
            sb.tip = L.talents_learnDualTip
        end
        W.FitTab(sb, label, 70)
        W.SetTabSelected(sb, st and st.active == i)
        K.Enable(sb, enabled)
        sb:ClearAllPoints()
        sb:SetPoint("TOPLEFT", x, -4)
        x = x + sb:GetWidth() + 2
    end
    x = x + 12
    local dirty = Dirty(st)
    ui.apply:ClearAllPoints()
    ui.apply:SetPoint("TOPLEFT", x, -4)
    W.SetTabSelected(ui.apply, dirty)
    K.Enable(ui.apply, dirty and Editable(st))
    ui.revert:ClearAllPoints()
    ui.revert:SetPoint("LEFT", ui.apply, "RIGHT", 4, 0)
    K.Enable(ui.revert, dirty)

    -- trainer (second line, right side): one button; the trainer and the cost are its tooltip
    local tr = low and trainers[low]
    ui.train:ClearAllPoints()
    ui.train:SetPoint("TOPRIGHT", pane, "TOPRIGHT", -4, -32)
    local canTrain = tr ~= nil and #tr.rows > 0 and tr.can > 0
    K.Enable(ui.train, canTrain)
    W.FitTab(ui.train, canTrain and string.format(L.talents_trainCount, tr.can) or L.talents_trainShort, 90, 220)
    if not tr then
        ui.train.tip = L.talents_train
    elseif tr.npc == "" and #tr.rows == 0 then
        ui.train.tip = L.talents_trainNone
    elseif tr.can == 0 then
        ui.train.tip = string.format(L.talents_trainNothing, BT.Show(tr.npc))
    else
        ui.train.tip = L.talents_train .. "\n" .. BT.Show(tr.npc) .. ": "
            .. string.format(L.talents_trainInfo, tr.can, K.Money(tr.cost))
    end

    if glyphView then
        RenderGlyphs(low)
    elseif ready then
        for tab = 0, 2 do
            RenderTree(tab, tree, st, cls)
        end
    end
end

-- ---------------------------------------------------------------- actions

function T.Click(t, dir)
    local low = K.Current()
    if not low or not t then
        return
    end
    local ok, why = T.Step(low, t.id, dir)
    if ok then
        T.Render()
        -- keep the tooltip in step with the new rank
        if GameTooltip:IsShown() then
            local focus = GetMouseFocus and GetMouseFocus()
            if focus and focus.talent == t then
                TalentTooltip(focus)
            end
        end
    elseif why then
        K.Status(low, why, "err")
    end
end

function T.Apply()
    local low = K.Current()
    local st = low and talentState[low]
    if not st or not Editable(st) or not Dirty(st) then
        return
    end
    local text = T.RanksText(low)
    if text then
        K.Send("TAPPLY", low, text)
        K.Status(low, L.talents_sent, "busy")
    end
end

function T.Revert()
    local low = K.Current()
    local st = low and talentState[low]
    if st then
        st.ranks = {}
        for id, r in pairs(st.server) do
            st.ranks[id] = r
        end
        T.Render()
        K.Send("TALENTS", low, st.spec)
    end
end

function T.SpecClick(i)
    local low = K.Current()
    local st = low and talentState[low]
    if not st or st.active == i then
        return
    end
    if i == 2 and st.count < 2 then
        K.Confirm("dualspec", L.talents_dualConfirm, function()
            K.Send("TSPEC", low, 2)
        end)
    else
        K.Send("TSPEC", low, i)
    end
end

-- ---------------------------------------------------------------- messages

local function Visible(low)
    return pane:IsVisible() and low and low == K.Current()
end

K.Hook("TTREE", function(f)
    local cls = ParseTree(f)
    if cls and pane:IsVisible() and BotClass(K.Current()) == cls then
        T.Render()
    end
end)

K.Hook("TALENTS", function(f)
    local low = ParseTalents(f)
    if Visible(low) then
        T.Render()
    end
end)

K.Hook("TRAINER", function(f)
    local low = ParseTrainer(f)
    if Visible(low) then
        T.Render()
    end
end)

K.Hook("PRESPECS", function(f)
    local low = ParsePremade(f)
    if Visible(low) then
        T.Render()
    end
end)

K.Hook("GLYPHS", function(f)
    local low = ParseGlyphs(f)
    if low then
        glyphRetry[low] = nil
    end
    if Visible(low) then
        T.Render()
    end
end)

K.Hook("ACK", function(f)
    local low, op, ok, code, text = K.Ack(f)
    if not low then
        return
    end
    -- "moving": the server stopped the bot; re-send the same apply once a second later
    local last = op == "GLYPH" and T.lastGlyphApply[low]
    if last and not ok and code == "moving" and not last.retried then
        last.retried = true
        BT.After("glyphretry" .. low, 1, function()
            K.Send("GLYPH", low, "apply", last.slot, last.bag, last.bagSlot, last.guid)
        end)
    elseif op == "GLYPH" then
        T.lastGlyphApply[low] = nil
    end
    -- an accepted apply may still be casting (glyph_pending): look again a second later
    if op == "GLYPH" then
        BT.After("glyphs", 1, function()
            K.Send("GLYPHS", low)
        end)
    end
    -- errors and the TRAIN text are shown by Protocol.lua when it has the shared ACK handling
    if op == "TAPPLY" or op == "TSPEC" or op == "PRESPEC" or op == "GLYPH" or (op == "TRAIN" and not K.sharedAck) then
        if ok then
            K.Status(low, (text ~= "" and text ~= "ok") and text or L.saved, "ok")
        elseif not K.sharedAck then
            K.Status(low, text, "err")
        end
    end
end)

table.insert(K.onTalentTabs, function(cls)
    if pane:IsVisible() and BotClass(K.Current()) == cls then
        T.Render()
    end
end)
