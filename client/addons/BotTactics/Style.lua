-- Tab "Style" (party-window spec 6.9): the bot's role and behaviour toggles of the class AI.
-- Roles, toggle labels and hints come from the server (STYLE), so new toggles need no addon change.
-- AI initiative card (ai-layer-spec 9): the slider 0..3 (STYLE fields 6-7, SETSTYLE ai) and the AISTAT
-- summary line, refreshed every 5 s while the tab is visible.
-- Radio groups and the class block (multibot-gap "Протокол (реализация)" P2/P3): toggle subfields 6-7
-- (group, cls) and STYLE field 8 (groups). General groups sit in the "In combat" / "Out of combat" cards,
-- class toggles and class groups in the "Class" card under them, with the pet commands for hunters and
-- warlocks (plain CMD "pet ..." / "tame ..."). The tab content scrolls with the mouse wheel.

local BT = BotTactics
local L, W, K = BT.L, BT.W, BT.TabKit
local S = BT.S

L.style_tab = S("Style", "Стиль")
L.style_role = S("Role", "Роль")
L.style_roleNote = S("Changes the base strategy of the class AI (tank / heal / dps).",
    "Меняет базовую стратегию классового ИИ (tank / heal / dps).")
L.style_combat = S("In combat", "Поведение в бою")
L.style_noncombat = S("Out of combat", "Вне боя")
L.style_note = S("Everything that depends on a specific spell (seals, auras, curses, totems) is set with tactics rules.",
    "Всё, что зависит от конкретного заклинания (печати, ауры, проклятия, тотемы), - правилами тактики.")
L.style_noteClass = S("The class block sets what the class AI keeps up on its own; tactics rules still come first.",
    "Классовый блок задаёт, что классовый ИИ держит сам; правила тактики всё равно важнее.")
L.style_loading = S("Loading...", "Загрузка...")
L.style_none = S("Nothing to switch here.", "Здесь нечего переключать.")
L.style_class = S("Class", "Классовое")
L.style_noneOpt = S("None", "Нет")
L.style_noneTip = S("Switch the whole group off.", "Выключить всю группу.")
L.style_ncTag = S("Out of combat. ", "Вне боя. ")
L.style_more = S("Scroll down: more below", "Прокрутите вниз: ниже есть ещё")
L.style_pet = S("Pet", "Питомец")
L.style_petHint = S("Orders to the bot's pet. The stance is not reported back: the highlight is your last choice.",
    "Приказы питомцу бота. Стойку сервер не сообщает: подсвечен ваш последний выбор.")
L.style_petAggressive = S("Aggressive", "Агрессивная")
L.style_petDefensive = S("Defensive", "Защитная")
L.style_petPassive = S("Passive", "Пассивная")
L.style_petAttack = S("Attack the bot's target", "Атаковать цель бота")
L.style_petAttackTip = S("Only in combat: the pet attacks the bot's current target. Does nothing out of combat or "
    .. "with the passive stance.", "Только в бою: питомец атакует текущую цель бота. Вне боя и в пассивной "
    .. "стойке ничего не делает.")
L.style_petFollow = S("Follow", "За мной")
L.style_petStay = S("Stay", "Стоять")
L.style_petRename = S("Rename...", "Переименовать...")
L.style_petRenamePrompt = S("New pet name (1-12 Latin letters):", "Новое имя питомца (1-12 латинских букв):")
L.style_petBadName = S("Pet name: 1-12 Latin letters only", "Имя питомца: только 1-12 латинских букв")
L.style_petAbandon = S("Abandon pet", "Бросить питомца")
L.style_petAbandonConfirm = S("Abandon the pet of %s? It cannot be undone.",
    "Бросить питомца бота %s? Это нельзя отменить.")
L.style_petOrders = S("Orders", "Приказы")
L.style_aiStatShort = S("AI: %d actions, silent %d%%", "ИИ: %d решений, молчал %d%%")

local St = {}
BT.Style = St

BT.styles = BT.styles or {}    -- low -> { role, roles = { {id, label} }, toggles = { {key, label, hint, on, list, group, cls} },
                               --          groups = { {id, label, hint, none, cls, list} }, groupById,
                               --          ai = { value, stored, max, lvl2, lvl3, names = { [0..3] = {label, hint} } } }
local styles = BT.styles
BT.aistats = BT.aistats or {}  -- low -> { ai, role, threshold, reserve, fires = { {id, n} }, last, fights, switches, silent }
local aistats = BT.aistats

local ROW_H = 26
local CARD_GAP = 12
local MAX_ROLES = 4
local AISTAT_EVERY = 5
local SCROLL_STEP = 40
local CLASS_COLS = 2           -- columns of the class card (switches and dropdown rows)
local PET_CLASSES = { [3] = true, [9] = true }   -- hunter, warlock (PetsAction works for any pet)
local HUNTER = 3

local petStance = {}           -- low -> last stance order sent

-- ---------------------------------------------------------------- data

local function ParseStyle(f)
    local low = tonumber(f[2])
    if not low then
        return
    end
    local st = { role = f[3] or "", roles = {}, toggles = {}, groups = {}, groupById = {} }
    for _, e in ipairs(BT.List(f[4])) do
        local id, label = string.match(e, "^([^:]*):(.*)$")
        if id and id ~= "" then
            st.roles[#st.roles + 1] = { id = id, label = BT.Unesc(label) }
        end
    end
    for _, e in ipairs(BT.List(f[5])) do
        local s = BT.Split(e, ",")
        if s[1] and s[1] ~= "" then
            st.toggles[#st.toggles + 1] = {
                key = s[1], label = BT.Unesc(s[2]), hint = BT.Unesc(s[3]), on = s[4] == "1",
                list = (s[5] == "nc") and "nc" or "co",
                group = (s[6] and s[6] ~= "") and s[6] or nil, cls = s[7] == "1",
            }
        end
    end
    -- field 6: effective,stored,max,lvl2,lvl3; field 7: 0:label:hint;1:... (older servers send neither)
    local a = BT.Split(f[6] or "", ",")
    local value = tonumber(a[1])
    if value then
        local ai = {
            value = value, stored = tonumber(a[2]) or value, max = tonumber(a[3]) or 3,
            lvl2 = tonumber(a[4]) or 20, lvl3 = tonumber(a[5]) or 40, names = {},
        }
        for _, e in ipairs(BT.List(f[7])) do
            local idx, label, hint = string.match(e, "^(%d+):([^:]*):?(.*)$")
            idx = tonumber(idx)
            if idx then
                ai.names[idx] = { label = BT.Unesc(label), hint = BT.Unesc(hint) }
            end
        end
        st.ai = ai
    end
    -- field 8: groups id,labelEsc,hintEsc,none,cls,list (list "both" = the group sets co and nc, e.g. the
    -- mage armor: shown like "co", without the "out of combat" tag)
    for _, e in ipairs(BT.List(f[8])) do
        local s = BT.Split(e, ",")
        if s[1] and s[1] ~= "" and not st.groupById[s[1]] then
            local g = {
                id = s[1], label = BT.Unesc(s[2]), hint = BT.Unesc(s[3]), none = s[4] == "1", cls = s[5] == "1",
                list = (s[6] == "nc") and "nc" or "co", members = {},
            }
            st.groups[#st.groups + 1] = g
            st.groupById[g.id] = g
        end
    end
    -- field 9: manual mode "<on>,<strict>" (abilities-mirroring-spec 3.1; older servers: no field, no block)
    if f[9] then
        local m = BT.Split(f[9], ",")
        st.manual = { on = m[1] == "1", strict = m[2] == "1" }
    end
    -- members in toggle order; a member whose group is unknown stays a plain switch
    for _, t in ipairs(st.toggles) do
        local g = t.group and st.groupById[t.group]
        if g then
            g.members[#g.members + 1] = t
        else
            t.group = nil
        end
    end
    styles[low] = st
    return low
end

-- AISTAT <bot> <ai> <role> <threshold100> <reserve> <fires> <last> <fight>
local function ParseAistat(f)
    local low = tonumber(f[2])
    if not low then
        return
    end
    local s = { ai = tonumber(f[3]) or 0, role = f[4] or "", threshold = tonumber(f[5]) or 0,
        reserve = tonumber(f[6]) or 0, fires = {} }
    for _, e in ipairs(BT.List(f[7])) do
        local id, n = string.match(e, "^([^:]+):(%d+)$")
        if id then
            s.fires[#s.fires + 1] = { id = BT.Unesc(id), n = tonumber(n) }
        end
    end
    local l = BT.Split(f[8] or "", ",")
    if l[1] and l[1] ~= "" then
        s.last = { id = BT.Unesc(l[1]), score = tonumber(l[2]), ago = tonumber(l[3]) }
    end
    local g = BT.Split(f[9] or "", ",")
    s.fights, s.switches, s.silent = tonumber(g[1]) or 0, tonumber(g[2]) or 0, tonumber(g[3]) or 0
    aistats[low] = s
    return low
end

-- "AI: heal 3, interrupt 1; silent 84%"
function St.AistatText(low)
    local s = aistats[low]
    if not s then
        return ""
    end
    if s.ai == 0 then
        return L.style_aiOff
    end
    local parts = {}
    for _, e in ipairs(s.fires) do
        parts[#parts + 1] = BT.IntentLabel(e.id) .. " " .. e.n
    end
    local list = (#parts > 0) and table.concat(parts, ", ") or L.style_aiNone
    return string.format(L.style_aiStat, list, s.silent)
end

-- ---------------------------------------------------------------- pane
-- Layout (party-ui-audit 5.6 / 6.5): left column = "Role + AI initiative" and "Out of combat"; right two
-- thirds = "In combat"; under them the class card over the full width. Every switch is one 26 px row whose
-- hint is its tooltip; a radio group (and the pet) is one row with a dropdown "Label: [value v]".

local pane
local ui = { roles = {}, rows = { co = {}, nc = {}, cls = {} }, boxes = { co = {}, nc = {}, cls = {} }, cards = {} }
St.ui = ui

-- keys that have their own place elsewhere: "passive" is the strip's group-wide button
local HIDDEN = { passive = true }

-- AISTAT on show and every AISTAT_EVERY s while the tab is visible (cancelled on hide).
local AistatTick
AistatTick = function()
    local low = K.Current()
    if not pane or not pane:IsVisible() or not low then
        return
    end
    K.Send("AISTAT", low)
    BT.After("aistat", AISTAT_EVERY, AistatTick)
end

local function Request(low)
    K.Send("STYLE", low)
    K.Send("AISTAT", low)
    BT.After("aistat", AISTAT_EVERY, AistatTick)
end

pane = K.Tab("style", L.style_tab, Request, function() St.Render() end, function()
    BT.Cancel("aistat")
end)
St.pane = pane

-- scroll area: every card lives in `body`, the scroll child
local scroll = CreateFrame("ScrollFrame", nil, pane)
scroll:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, 0)
scroll:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, 0)
local body = CreateFrame("Frame", nil, scroll)
body:SetWidth(BT.Party.CONTENT_W or 740)
body:SetHeight(10)
scroll:SetScrollChild(body)
ui.scroll, ui.body = scroll, body
ui.offset = 0
ui.maxOffset = 0

function St.Scroll(delta)
    local off = math.max(0, math.min(ui.maxOffset, ui.offset - (delta or 0) * SCROLL_STEP))
    ui.offset = off
    scroll:SetVerticalScroll(off)
    W.Show(ui.more, off < ui.maxOffset)
end

scroll:EnableMouseWheel(true)
scroll:SetScript("OnMouseWheel", function(_, delta)
    St.Scroll(delta)
end)

ui.cards.role = K.Card(body, L.style_role)
ui.cards.co = K.Card(body, L.style_combat)
ui.cards.nc = K.Card(body, L.style_noncombat)
ui.cards.cls = K.Card(body, L.style_class)
-- the AI initiative lives in the role card (one card, party-ui-audit 6.5); ui.cards.ai is its block
ui.cards.ai = CreateFrame("Frame", nil, ui.cards.role)
ui.aiCaption = W.Text(ui.cards.ai, "GameFontNormalSmall", W.GOLD_DIM)
ui.aiCaption:SetPoint("TOPLEFT", 0, 0)
ui.aiCaption:SetText(L.style_ai)

for i = 1, MAX_ROLES do
    local b = W.Tab(ui.cards.role, 22)
    b:SetScript("OnClick", function(self)
        St.SetRole(self.role)
    end)
    ui.roles[i] = b
end

-- slider positions 0..3 (ui.ai[1] = position 0)
ui.ai = {}
for i = 1, 4 do
    local b = W.Tab(ui.cards.ai, 22)
    b.idx = i - 1
    b:SetScript("OnClick", function(self)
        St.SetAi(self.idx)
    end)
    ui.ai[i] = b
end
-- short AISTAT line; the per-intent counts are its tooltip (party-ui-audit Y4)
ui.aiStatLine = CreateFrame("Frame", nil, ui.cards.ai)
ui.aiStatLine:SetHeight(14)
ui.aiStatLine:EnableMouse(true)
ui.aiStat = W.Text(ui.aiStatLine, "GameFontDisableSmall", W.FAINT)
ui.aiStat:SetPoint("LEFT", 0, 0)
ui.aiStat:SetPoint("RIGHT", 0, 0)
ui.aiStat:SetHeight(12)
ui.aiStatLine:SetScript("OnEnter", function(self)
    local text = St.AistatText(K.Current())
    if text ~= "" then
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L.style_ai, 1, 0.82, 0)
        GameTooltip:AddLine(BT.Show(text), 1, 1, 1, 1)
        GameTooltip:Show()
    end
end)
ui.aiStatLine:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

ui.note = W.Text(body, "GameFontDisableSmall", W.FAINT)
ui.loading = W.Text(pane, "GameFontDisable", W.MUTED, "CENTER")
ui.loading:SetPoint("CENTER")
ui.more = W.IconButton(pane, 16, "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up",
    "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Down", nil, L.style_more)
ui.more:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -2, 2)
ui.more:SetScript("OnClick", function()
    St.Scroll(-3)
end)
ui.more:Hide()

-- Manual mode of the shown bot (abilities-mirroring-spec 3.5): the class AI cards are dimmed.
function St.ManualOn(low)
    low = low or K.Current()
    local st = low and styles[low]
    return st ~= nil and st.manual ~= nil and st.manual.on
end

-- Row tooltip: the full label (it may be cut to one line) and the hint under it; in manual mode a note that
-- the class AI switches have no effect (not on the manual block's own rows).
local function RowEnter(self)
    local hasTip = self.tip and self.tip ~= ""
    local dim = not self.manualRow and St.ManualOn()
    if hasTip or dim or (self.label and self.label.fullText) then
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(self.title or "", 1, 0.82, 0, 1, 1)
        if hasTip then
            GameTooltip:AddLine(self.tip, 1, 1, 1, 1)
        end
        if dim then
            GameTooltip:AddLine(L.style_manualDim, 1, 0.5, 0.3, 1)
        end
        GameTooltip:Show()
    end
end

local function RowLeave()
    GameTooltip:Hide()
end

local function RowLine(r)
    local line = r:CreateTexture(nil, "BACKGROUND")
    line:SetTexture(0.17, 0.14, 0.10, 1)
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT", 0, 0)
    line:SetPoint("BOTTOMRIGHT", 0, 0)
end

-- Manual mode block of the role card (abilities-mirroring-spec 3.5): caption, "Only my rules" and, while on,
-- "Potions and racials too" (strict). Two switch rows like the toggles; the hint is the row tooltip.
ui.manual = CreateFrame("Frame", nil, ui.cards.role)
ui.manualCaption = W.Text(ui.manual, "GameFontNormalSmall", W.GOLD_DIM)
ui.manualCaption:SetPoint("TOPLEFT", 0, 0)
ui.manualCaption:SetText(L.style_manual)
ui.manualRows = {}
for i = 1, 2 do
    local r = CreateFrame("Frame", nil, ui.manual)
    r:SetHeight(ROW_H)
    r:EnableMouse(true)
    r:SetScript("OnEnter", RowEnter)
    r:SetScript("OnLeave", RowLeave)
    r.manualRow = true
    r.label = W.Text(r, "GameFontHighlightSmall", W.TEXT)
    r.label:SetPoint("LEFT", 0, 0)
    r.label:SetPoint("RIGHT", -40, 0)
    r.label:SetHeight(12)
    r.switch = K.Switch(r)
    r.switch:SetPoint("RIGHT", 0, 0)
    r.strict = i == 2
    r.switch:SetScript("OnClick", function(self)
        if r.strict then
            St.SetManual(true, not self.on)
        else
            St.SetManual(not self.on, false)
        end
    end)
    RowLine(r)
    ui.manualRows[i] = r
end

-- Switch row: label (one line) and the switch; the hint is the row's tooltip.
local function ToggleRow(list, i)
    local rows = ui.rows[list]
    local r = rows[i]
    if r then
        return r
    end
    local card = ui.cards[list]
    r = CreateFrame("Frame", nil, card)
    r:SetHeight(ROW_H)
    r:EnableMouse(true)
    r:SetScript("OnEnter", RowEnter)
    r:SetScript("OnLeave", RowLeave)
    r.label = W.Text(r, "GameFontHighlightSmall", W.TEXT)
    r.label:SetPoint("LEFT", 0, 0)
    r.label:SetPoint("RIGHT", -40, 0)
    r.label:SetHeight(12)
    r.switch = K.Switch(r)
    r.switch:SetPoint("RIGHT", 0, 0)
    r.switch:SetScript("OnClick", function(self)
        St.Toggle(r.key, not self.on)
    end)
    RowLine(r)
    rows[i] = r
    return r
end

-- Radio group row: label and a dropdown with the options (party-ui-audit Y3). bx.opts = the options
-- of the last render { {label, tip, selected, fn, key} }; the dropdown shows the selected one.
local function GroupBox(list, i)
    local boxes = ui.boxes[list]
    local bx = boxes[i]
    if bx then
        return bx
    end
    bx = CreateFrame("Frame", nil, ui.cards[list])
    bx:SetHeight(ROW_H)
    bx:EnableMouse(true)
    bx:SetScript("OnEnter", RowEnter)
    bx:SetScript("OnLeave", RowLeave)
    bx.label = W.Text(bx, "GameFontHighlightSmall", W.TEXT)
    bx.label:SetPoint("LEFT", 0, 0)
    bx.label:SetHeight(12)
    bx.pick = W.Pick(bx, 120, 20, false, true)
    bx.pick:SetPoint("RIGHT", 0, 0)
    bx.label:SetPoint("RIGHT", bx.pick, "LEFT", -6, 0)
    bx.pick.box = bx
    bx.pick:SetScript("OnClick", function(self)
        St.BoxMenu(self.box)
    end)
    bx.opts = {}
    RowLine(bx)
    boxes[i] = bx
    return bx
end

function St.BoxMenu(bx)
    local items = { { text = bx.title or "", isTitle = true, notCheckable = true } }
    for _, o in ipairs(bx.opts or {}) do
        local fn = o.fn
        items[#items + 1] = {
            text = BT.Show(o.label), checked = o.selected and true or false, notCheckable = o.plain,
            tooltipTitle = o.tip and BT.Show(o.label) or nil, tooltipText = o.tip,
            func = function()
                CloseDropDownMenus()
                if fn then
                    fn()
                end
            end,
        }
    end
    W.ShowMenu(bx.pick, items)
end

-- Fills a group row of width w: label, hint (tooltip), options; the dropdown shows the selected
-- option (or `shown` when given).
local function FillBox(bx, w, label, hint, opts, shown)
    bx:SetWidth(w)
    local pickW = math.max(90, math.floor(w * 0.55))
    bx.pick:SetWidth(pickW)
    bx.title = BT.Show(label)
    bx.tip = (hint and hint ~= "") and BT.Show(hint) or nil
    W.FitText(bx.label, bx.title, w - pickW - 6)
    bx.opts = opts
    local cur
    for _, o in ipairs(opts) do
        if o.selected then
            cur = o
        end
    end
    local text = shown or (cur and BT.Show(cur.label)) or L.style_noneOpt
    W.SetPickText(bx.pick, text)
    bx:Show()
    return ROW_H
end

-- Options of a radio group: "None" first when the group may be empty, then the members.
local function GroupOpts(g)
    local opts = {}
    local anyOn = false
    for _, t in ipairs(g.members) do
        if t.on then
            anyOn = true
        end
    end
    if g.none then
        opts[#opts + 1] = { label = L.style_noneOpt, tip = L.style_noneTip, selected = not anyOn, key = "",
            fn = function() St.GroupNone(g.id) end }
    end
    for _, t in ipairs(g.members) do
        local key = t.key
        opts[#opts + 1] = {
            label = t.label, tip = (t.hint ~= "") and BT.Show(t.hint) or nil, selected = t.on, key = key,
            fn = function() St.Toggle(key, true) end,
        }
    end
    return opts
end

local function GroupHint(g)
    local hint = g.hint or ""
    if g.cls and g.list == "nc" then
        hint = L.style_ncTag .. hint
    end
    return hint
end

-- Pet options (hunter and warlock): stances (the last one sent is checked), orders, rename / abandon.
local function PetOpts(low, class)
    local sel = petStance[low]
    local function Stance(id)
        return function() St.PetOrder("pet " .. id, id) end
    end
    local opts = {
        { label = L.style_petAggressive, selected = sel == "aggressive", fn = Stance("aggressive") },
        { label = L.style_petDefensive, selected = sel == "defensive", fn = Stance("defensive") },
        { label = L.style_petPassive, selected = sel == "passive", fn = Stance("passive") },
        { label = L.style_petAttack, plain = true, tip = L.style_petAttackTip, fn = function() St.PetOrder("pet attack") end },
        { label = L.style_petFollow, plain = true, fn = function() St.PetOrder("pet follow") end },
        { label = L.style_petStay, plain = true, fn = function() St.PetOrder("pet stay") end },
    }
    if class == HUNTER then
        opts[#opts + 1] = { label = L.style_petRename, plain = true, fn = function() St.PetRename() end }
        opts[#opts + 1] = { label = L.style_petAbandon, plain = true, fn = function() St.PetAbandon() end }
    end
    return opts
end

-- ---------------------------------------------------------------- render

-- Lays the cells of one card out in `cols` columns from y0 (switch rows first, then group rows).
-- cells = { {kind = "switch", t = toggle} | {kind = "group", label, hint, opts, id, shown} }.
-- Returns the y under the last row.
local function RenderGrid(list, card, cells, y0, inner, cols)
    local colGap = 16
    local cw = math.floor((inner - (cols - 1) * colGap) / cols)
    local nRows, nBoxes = 0, 0
    for i, c in ipairs(cells) do
        local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
        local x, y = 10 + col * (cw + colGap), y0 + row * ROW_H
        local f
        if c.kind == "switch" then
            nRows = nRows + 1
            f = ToggleRow(list, nRows)
            local t = c.t
            f.key = t.key
            f:SetWidth(cw)
            f.title = BT.Show(t.label)
            f.tip = BT.Show(((c.nc and L.style_ncTag) or "") .. (t.hint or ""))
            W.FitText(f.label, f.title, cw - 40)
            K.SetSwitch(f.switch, t.on)
            f:Show()
        else
            nBoxes = nBoxes + 1
            f = GroupBox(list, nBoxes)
            FillBox(f, cw, c.label, c.hint, c.opts, c.shown)
            f.groupId = c.id
        end
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", card, "TOPLEFT", x, -y)
    end
    for k = nRows + 1, #ui.rows[list] do
        ui.rows[list][k]:Hide()
    end
    for k = nBoxes + 1, #ui.boxes[list] do
        ui.boxes[list][k]:Hide()
        ui.boxes[list][k].groupId = nil
    end
    return y0 + math.ceil(#cells / cols) * ROW_H
end

-- One list card (co / nc): general switches and general groups of that list, in toggle order.
local function RenderListCard(st, list, x, y, cardW, cols)
    local card = ui.cards[list]
    local cells, done = {}, {}
    for _, t in ipairs(st.toggles) do
        if not t.cls and t.list == list and not t.group and not HIDDEN[t.key] then
            cells[#cells + 1] = { kind = "switch", t = t }
        end
    end
    -- general groups whose section is this list (members may live in either list)
    for _, g in ipairs(st.groups) do
        if not g.cls and g.list == list and not done[g.id] and #g.members > 0 then
            done[g.id] = true
            cells[#cells + 1] = { kind = "group", label = g.label, hint = g.hint, opts = GroupOpts(g), id = g.id }
        end
    end
    local bottom = RenderGrid(list, card, cells, 26, cardW - 20, cols)
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", body, "TOPLEFT", x, -y)
    card:SetWidth(cardW)
    local empty = #cells == 0
    local height = empty and 50 or (bottom + 8)
    card:SetHeight(height)
    if not card.none then
        card.none = W.Text(card, "GameFontDisableSmall", W.FAINT)
        card.none:SetPoint("TOPLEFT", 10, -28)
        card.none:SetText(L.style_none)
    end
    W.Show(card.none, empty)
    return height
end

-- Class card at y (full width): class switches, class groups and the pet row in CLASS_COLS columns.
-- Returns its height (0 when hidden).
local function RenderClassCard(st, low, top, w)
    local card = ui.cards.cls
    local b = K.Bot(low)
    local class = b and tonumber(b.class)
    local hasPet = class and PET_CLASSES[class]
    local cells = {}
    for _, t in ipairs(st.toggles) do
        if t.cls and not t.group and not HIDDEN[t.key] then
            cells[#cells + 1] = { kind = "switch", t = t, nc = t.list == "nc" }
        end
    end
    for _, g in ipairs(st.groups) do
        if g.cls and #g.members > 0 then
            cells[#cells + 1] = { kind = "group", label = g.label, hint = GroupHint(g), opts = GroupOpts(g), id = g.id }
        end
    end
    if hasPet then
        local sel = petStance[low]
        local shown = L.style_petOrders
        if sel then
            for _, o in ipairs(PetOpts(low, class)) do
                if o.selected then
                    shown = BT.Show(o.label)
                end
            end
        end
        cells[#cells + 1] = { kind = "group", label = L.style_pet, hint = L.style_petHint, opts = PetOpts(low, class),
            id = "pet", shown = shown }
    end
    if #cells == 0 then
        card:Hide()
        for _, r in ipairs(ui.rows.cls) do r:Hide() end
        for _, bx in ipairs(ui.boxes.cls) do
            bx:Hide()
            bx.groupId = nil
        end
        return 0
    end
    local caption = L.style_class
    if class then
        caption = caption .. L.dot .. BT.ClassName(class)
    end
    card.caption:SetText(caption)
    local bottom = RenderGrid("cls", card, cells, 26, w - 20, CLASS_COLS)
    local height = bottom + 8
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -top)
    card:SetWidth(w)
    card:SetHeight(height)
    card:Show()
    return height
end

function St.Render()
    local w, h = K.PaneSize(pane)
    local leftW = math.floor((w - CARD_GAP) / 3)
    local rightW = w - leftW - CARD_GAP
    local low = K.Current()
    local st = low and styles[low]
    ui.loading:SetText(low and L.style_loading or "")
    W.Show(ui.loading, not st)
    for _, key in ipairs({ "role", "co", "nc" }) do
        W.Show(ui.cards[key], st ~= nil)
    end
    W.Show(ui.cards.ai, st ~= nil and st.ai ~= nil)
    ui.note:Hide()
    if not st then
        ui.cards.cls:Hide()
        ui.more:Hide()
        return
    end
    body:SetWidth(w)

    -- role card (with the AI block under the role buttons)
    local rc = ui.cards.role
    rc:ClearAllPoints()
    rc:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    rc:SetWidth(leftW)
    local x = 10
    local nRoles = math.max(1, #st.roles)
    for i, b in ipairs(ui.roles) do
        local role = st.roles[i]
        if role then
            b.role = role.id
            W.FitTab(b, BT.Show(role.label), 50, math.floor((leftW - 20 - (nRoles - 1) * 2) / nRoles))
            b.tip = L.style_roleNote
            W.SetTabSelected(b, role.id == st.role)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", x, -26)
            x = x + b:GetWidth() + 2
            b:Show()
        else
            b:Hide()
        end
    end
    local roleH = 26 + 22 + 10
    roleH = St.RenderManual(leftW, roleH)
    if st.ai then
        roleH = St.RenderAi(leftW, roleH)
    end
    rc:SetHeight(roleH)
    -- manual mode: the class AI cards and the AI slider have no effect (dimmed, a note in their tooltips)
    local alpha = St.ManualOn(low) and 0.45 or 1
    for _, key in ipairs({ "ai", "co", "nc", "cls" }) do
        ui.cards[key]:SetAlpha(alpha)
    end

    -- out of combat under it, in combat on the right (two columns)
    local hNc = RenderListCard(st, "nc", 0, roleH + CARD_GAP, leftW, 1)
    local hCo = RenderListCard(st, "co", leftW + CARD_GAP, 0, rightW, 2)
    local top = math.max(roleH + CARD_GAP + hNc, hCo) + CARD_GAP
    local hCls = RenderClassCard(st, low, top, w)
    local bottom = top + ((hCls > 0) and (hCls + CARD_GAP) or 0)

    ui.note:ClearAllPoints()
    ui.note:SetPoint("TOPLEFT", body, "TOPLEFT", 2, -bottom)
    ui.note:SetWidth(w - 4)
    ui.note:SetText((hCls > 0) and L.style_noteClass or L.style_note)
    ui.note:Show()

    local total = bottom + 24
    body:SetHeight(total)
    ui.maxOffset = math.max(0, total - h)
    if low ~= ui.lastLow then
        ui.lastLow = low
        ui.offset = 0             -- another bot starts at the top
    end
    St.Scroll(0)
end

-- "AI: 8 actions, silent 84%" (the per-intent counts are the tooltip, St.AistatText)
function St.AistatShort(low)
    local s = aistats[low]
    if not s then
        return ""
    end
    if s.ai == 0 then
        return L.style_aiOff
    end
    local n = 0
    for _, e in ipairs(s.fires) do
        n = n + (e.n or 0)
    end
    return string.format(L.style_aiStatShort, n, s.silent)
end

-- Manual mode block of the role card from y (hidden when the server sends no STYLE field 9). Returns y below it.
function St.RenderManual(cardW, y)
    local low = K.Current()
    local st = low and styles[low]
    local m = st and st.manual
    local block = ui.manual
    if not m then
        block:Hide()
        return y
    end
    local inner = cardW - 20
    block:ClearAllPoints()
    block:SetPoint("TOPLEFT", ui.cards.role, "TOPLEFT", 10, -y)
    block:SetWidth(inner)
    local n = m.on and 2 or 1
    for i, r in ipairs(ui.manualRows) do
        if i <= n then
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", block, "TOPLEFT", 0, -16 - (i - 1) * ROW_H)
            r:SetWidth(inner)
            r.title = (i == 1) and L.style_manualOn or L.style_manualStrict
            r.tip = (i == 1) and L.style_manualTip or L.style_manualStrictTip
            W.FitText(r.label, r.title, inner - 40)
            K.SetSwitch(r.switch, (i == 1) and m.on or m.strict)
            r:Show()
        else
            r:Hide()
        end
    end
    local h = 16 + n * ROW_H
    block:SetHeight(h)
    block:Show()
    return y + h + 8
end

-- AI block of the role card from y: caption, the four positions in 2 x 2, the AISTAT line.
-- Returns the card height.
function St.RenderAi(cardW, y)
    local low = K.Current()
    local st = low and styles[low]
    local ai = st and st.ai
    if not ai then
        return y
    end
    local block = ui.cards.ai
    local inner = cardW - 20
    block:ClearAllPoints()
    block:SetPoint("TOPLEFT", ui.cards.role, "TOPLEFT", 10, -y)
    block:SetWidth(inner)
    local perRow = 2
    local bw = math.floor((inner - (perRow - 1) * 2) / perRow)
    for i, b in ipairs(ui.ai) do
        local idx = b.idx
        local name = ai.names[idx]
        local locked = idx > ai.max
        b.locked = locked
        b:SetWidth(bw)
        W.SetTabText(b, BT.Show(name and name.label ~= "" and name.label or tostring(idx)))
        local col, row = (i - 1) % perRow, math.floor((i - 1) / perRow)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", block, "TOPLEFT", col * (bw + 2), -16 - row * 24)
        W.SetTabSelected(b, idx == ai.value)
        if locked then
            b:SetAlpha(0.45)
            b.tip = string.format(L.style_aiLocked, (idx >= 3) and ai.lvl3 or ai.lvl2)
        else
            b:SetAlpha(1)
            b.tip = name and name.hint ~= "" and BT.Show(name.hint) or nil
        end
        if St.ManualOn(low) then
            b.tip = L.style_manualAiDim
        end
        b:Show()
    end
    ui.aiStatLine:ClearAllPoints()
    ui.aiStatLine:SetPoint("TOPLEFT", block, "TOPLEFT", 0, -16 - 2 * 24 - 2)
    ui.aiStatLine:SetWidth(inner)
    W.FitText(ui.aiStat, BT.Show(St.AistatShort(low)), inner)
    local blockH = 16 + 2 * 24 + 2 + 14
    block:SetHeight(blockH)
    return y + blockH + 10
end

-- ---------------------------------------------------------------- actions

function St.SetAi(idx)
    local low = K.Current()
    local st = low and styles[low]
    local ai = st and st.ai
    if not ai or not idx or idx > ai.max or idx == ai.value then
        return
    end
    ai.value = idx
    K.Send("SETSTYLE", low, "ai", tostring(idx))
    St.Render()
end

-- SETSTYLE <bot> manual <1|0> [strict] (abilities-mirroring-spec 3.1); optimistic, STYLE follows.
function St.SetManual(on, strict)
    local low = K.Current()
    local st = low and styles[low]
    local m = st and st.manual
    if not m then
        return
    end
    strict = on and strict or false
    if m.on == on and m.strict == strict then
        return
    end
    m.on, m.strict = on, strict
    if on and strict then
        K.Send("SETSTYLE", low, "manual", "1", "strict")
    else
        K.Send("SETSTYLE", low, "manual", on and "1" or "0")
    end
    St.Render()
    if BT.Editor and BT.Editor.Refresh then
        BT.Editor.Refresh()
    end
end

function St.SetRole(role)
    local low = K.Current()
    local st = low and styles[low]
    if not st or not role or st.role == role then
        return
    end
    st.role = role
    K.Send("SETSTYLE", low, "role", role)
    St.Render()
end

-- Switch or radio member on/off (SETSTYLE <bot> <key> 1|0). A member turned on turns its group's other
-- members off (the server does the same, P3). A member already shown on is sent again: STYLE reports only
-- the first active member of a group, so a second one switched on from chat (e.g. "co +mm" on a bm hunter,
-- the rotation group has no playerbots siblings) is dropped by the server's explicit "-others" this way.
function St.Toggle(key, on)
    local low = K.Current()
    local st = low and styles[low]
    if not st or not key then
        return
    end
    local entry
    for _, t in ipairs(st.toggles) do
        if t.key == key then
            entry = t
        end
    end
    if not entry then
        return
    end
    local g = entry.group and st.groupById[entry.group]
    if g then
        if not on and not g.none then
            return
        end
        if on then
            for _, t in ipairs(g.members) do
                t.on = false
            end
        end
    end
    entry.on = on
    K.Send("SETSTYLE", low, key, on and "1" or "0")
    St.Render()
end

-- "None" of a group: switch its active member off.
function St.GroupNone(id)
    local low = K.Current()
    local st = low and styles[low]
    local g = st and st.groupById[id]
    if not g or not g.none then
        return
    end
    for _, t in ipairs(g.members) do
        if t.on then
            St.Toggle(t.key, false)
            return
        end
    end
end

function St.PetOrder(cmd, stance)
    local low = K.Current()
    if not low then
        return
    end
    if stance then
        petStance[low] = stance
    end
    BT.Protocol.Cmd(low, cmd)
    St.Render()
end

function St.PetRename()
    local low = K.Current()
    if not low then
        return
    end
    K.Prompt("petname", L.style_petRenamePrompt, "", function(text)
        local name = BT.Trim(text or "")
        if string.match(name, "^%a+$") and #name <= 12 then
            BT.Protocol.Cmd(low, "tame rename " .. name)
        else
            K.Status(low, L.style_petBadName, "err")
        end
    end)
end

function St.PetAbandon()
    local low = K.Current()
    local b = K.Bot(low)
    if not b then
        return
    end
    K.Confirm("petabandon", string.format(L.style_petAbandonConfirm, BT.Show(b.name)), function()
        BT.Protocol.Cmd(low, "tame abandon")
    end)
end

-- ---------------------------------------------------------------- messages

K.Hook("STYLE", function(f)
    local before = St.ManualOn(tonumber(f[2]))
    local low = ParseStyle(f)
    -- the tactics tab's "class AI" row follows the manual mode
    if low and St.ManualOn(low) ~= before and BT.Editor and BT.Editor.ui and BT.Editor.ui.bot == low
        and BT.Editor.Refresh then
        BT.Editor.Refresh()
    end
    if low and BT.Party.SyncPassive then
        BT.Party.SyncPassive(low)
    end
    if pane:IsVisible() and low and low == K.Current() then
        St.Render()
    end
end)

K.Hook("AISTAT", function(f)
    local low = ParseAistat(f)
    if pane:IsVisible() and low and low == K.Current() then
        St.Render()
    end
end)

K.Hook("ACK", function(f)
    local low, op, ok, _, text = K.Ack(f)
    if low and op == "SETSTYLE" and not ok then
        if not K.sharedAck then
            K.Status(low, text, "err")
        end
        K.Send("STYLE", low)     -- undo the optimistic change
    end
end)
