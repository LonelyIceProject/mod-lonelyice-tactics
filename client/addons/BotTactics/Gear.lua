-- Tab "Gear" (party-window spec 6.4): paperdoll with the bot's equipment, slot flyout (equip from
-- bags / unequip), 3D model, character-sheet stats, outfits and autogear.

local BT = BotTactics
local L, W, K = BT.L, BT.W, BT.TabKit
local S = BT.S

L.gear_tab = S("Gear", "Снаряжение")
L.gear_levelLine = S("Level %d %s", "%d-й уровень, %s")
L.gear_far = S("The bot is too far away", "Бот далеко")
L.gear_rotLeft = S("Rotate left", "Повернуть влево")
L.gear_rotRight = S("Rotate right", "Повернуть вправо")
L.gear_current = S("equipped", "надето")
L.gear_noFit = S("Nothing in the bags fits this slot", "В сумках нет подходящих вещей")
L.gear_unequip = S("Put into the bags", "Снять в сумку")
L.gear_empty = S("empty", "пусто")
L.gear_outfit = S("Outfit", "Комплект")
L.gear_outfitWear = S("Wear", "Надеть")
L.gear_outfitSaveHere = S("Save equipped here", "Сохранить надетое сюда")
L.gear_outfitRename = S("Rename", "Переименовать")
L.gear_outfitDelete = S("Delete", "Удалить")
L.gear_outfitNew = S("+ Save equipped...", "+ Сохранить надетое...")
L.gear_outfitNone = S("No outfits yet", "Комплектов пока нет")
L.gear_outfitName = S("Outfit name:", "Название комплекта:")
L.gear_outfitFull = S("All outfit slots are used", "Все места для комплектов заняты")
L.gear_outfitDelConfirm = S("Delete outfit \"%s\"?", "Удалить комплект «%s»?")
L.gear_autogear = S("Autogear", "Автоподбор")
L.gear_autogearTip = S("The bot picks the best gear it has or can get (playerbots autogear).",
    "Бот сам подбирает лучшее снаряжение (команда playerbots autogear).")
L.gear_autogearConfirm = S("Let the bot re-equip itself automatically?", "Бот сам переоденется в лучшее снаряжение. Продолжить?")
L.gear_brokenTip = S("Durability %d / %d", "Прочность %d / %d")
L.gear_noBot = S("Select a bot on the left.", "Выберите бота слева.")

-- stat sections
L.gear_secIlvl = S("Item level", "Уровень предмета")
L.gear_secBase = S("Base stats", "Основные")
L.gear_secSpell = S("Spell", "Магия")
L.gear_secMelee = S("Melee", "Ближний бой")
L.gear_secRanged = S("Ranged", "Дальний бой")
L.gear_secDefense = S("Defense", "Защита")
L.gear_secResist = S("Resistance", "Сопротивления")
L.gear_str = S("Strength", "Сила")
L.gear_agi = S("Agility", "Ловкость")
L.gear_sta = S("Stamina", "Выносливость")
L.gear_int = S("Intellect", "Интеллект")
L.gear_spi = S("Spirit", "Дух")
L.gear_armor = S("Armor", "Броня")
L.gear_spellDmg = S("Bonus damage", "Доп. урон")
L.gear_spellHeal = S("Bonus healing", "Доп. лечение")
L.gear_hit = S("Hit rating", "Меткость")
L.gear_crit = S("Crit chance", "Крит. удар")
L.gear_haste = S("Haste rating", "Скорость")
L.gear_mp5 = S("Mana regen", "Восполнение маны")
L.gear_damage = S("Damage", "Урон")
L.gear_speed = S("Speed", "Скорость")
L.gear_ap = S("Power", "Сила атаки")
L.gear_expertise = S("Expertise", "Мастерство")
L.gear_arpen = S("Armor penetration", "Пробивание брони")
L.gear_defense = S("Defense", "Защита")
L.gear_dodge = S("Dodge", "Уклонение")
L.gear_parry = S("Parry", "Парирование")
L.gear_block = S("Block", "Блок")
L.gear_resilience = S("Resilience", "Устойчивость")
L.gear_resArcane = S("Arcane", "Тайная магия")
L.gear_resFire = S("Fire", "Огонь")
L.gear_resNature = S("Nature", "Природа")
L.gear_resFrost = S("Frost", "Лёд")
L.gear_resShadow = S("Shadow", "Тьма")
-- dynamic sections (party-extras-spec 6.2)
L.gear_secReps = S("Reputation", "Репутация")
L.gear_secSkills = S("Skills", "Навыки")
L.gear_atWar = S("at war", "война")
L.gear_inactive = S("inactive", "неактивна")
L.gear_noData = S("no data", "нет данных")

local G = {}
BT.Gear = G

-- Client-side data from the server messages (other tabs may read it).
BT.gearState = BT.gearState or { bags = {}, stats = {}, outfits = {} }
local state = BT.gearState
state.reps = state.reps or {}       -- low -> { trunc, rows = { {id, name, parent, rank, bar, max, flags}, ... } }
state.skills = state.skills or {}   -- low -> { {id, cat, value, max, pureMax, name}, ... }

local FRAME_W, FRAME_H = 384, 440
local SIDEBAR_W = 290
local QUALITY_BORDER = "Interface\\Buttons\\UI-ActionButton-Border"
local ZOOM_MIN, ZOOM_MAX = -0.5, 1.2

-- equipment slot (0..18) -> x, y in CharacterFrame coordinates (party.html SLOTS)
local SLOT_POS = {
    [0] = { 21, 74 }, [1] = { 21, 115 }, [2] = { 21, 156 }, [14] = { 21, 197 }, [4] = { 21, 238 },
    [3] = { 21, 279 }, [18] = { 21, 320 }, [8] = { 21, 361 },
    [9] = { 305, 74 }, [5] = { 305, 115 }, [6] = { 305, 156 }, [7] = { 305, 197 }, [10] = { 305, 238 },
    [11] = { 305, 279 }, [12] = { 305, 320 }, [13] = { 305, 361 },
    [15] = { 122, 361 }, [16] = { 163, 361 }, [17] = { 204, 361 },
}

-- equipment slot -> inventory slot name (GetInventorySlotInfo) and the FrameXML global with its label
local SLOT_INFO = {
    [0] = { "HeadSlot", "HEADSLOT", "Head" }, [1] = { "NeckSlot", "NECKSLOT", "Neck" },
    [2] = { "ShoulderSlot", "SHOULDERSLOT", "Shoulder" }, [3] = { "ShirtSlot", "SHIRTSLOT", "Shirt" },
    [4] = { "ChestSlot", "CHESTSLOT", "Chest" }, [5] = { "WaistSlot", "WAISTSLOT", "Waist" },
    [6] = { "LegsSlot", "LEGSSLOT", "Legs" }, [7] = { "FeetSlot", "FEETSLOT", "Feet" },
    [8] = { "WristSlot", "WRISTSLOT", "Wrist" }, [9] = { "HandsSlot", "HANDSSLOT", "Hands" },
    [10] = { "Finger0Slot", "FINGER0SLOT", "Finger" }, [11] = { "Finger1Slot", "FINGER1SLOT", "Finger" },
    [12] = { "Trinket0Slot", "TRINKET0SLOT", "Trinket" }, [13] = { "Trinket1Slot", "TRINKET1SLOT", "Trinket" },
    [14] = { "BackSlot", "BACKSLOT", "Back" }, [15] = { "MainHandSlot", "MAINHANDSLOT", "Main Hand" },
    [16] = { "SecondaryHandSlot", "SECONDARYHANDSLOT", "Off Hand" }, [17] = { "RangedSlot", "RANGEDSLOT", "Ranged" },
    [18] = { "TabardSlot", "TABARDSLOT", "Tabard" },
}

local function SlotLabel(slot)
    local info = SLOT_INFO[slot]
    return info and (_G[info[2]] or info[3]) or "?"
end

-- ---------------------------------------------------------------- data

-- 3.3.5 item link of a BAGS row (spec 6.4): enchant, gems, (socket 4 = 0), suffix id, unique id = suffix
-- factor, level.
local function ItemLink(row, level)
    return "item:" .. row.entry .. ":" .. row.ench .. ":" .. row.gem1 .. ":" .. row.gem2 .. ":" .. row.gem3 ..
        ":0:" .. row.rprop .. ":" .. row.suffix .. ":" .. (level or 80)
end
G.ItemLink = ItemLink

local function BotLevel(low)
    local b = K.Bot(low)
    return b and b.level or 80
end

-- name, quality, ilvl of a row (nil fields until the client has the item cached)
local function ItemData(row, low)
    local name, _, quality, ilvl = GetItemInfo(ItemLink(row, BotLevel(low)))
    return name, quality, ilvl
end

local function Num(v)
    return tonumber(v) or 0
end

-- Equipment and bag rows only (bank rows are not equippable from where the bot stands).
local function IsBagPos(row)
    if row.bag == 255 then
        return row.slot >= 23 and row.slot < 39
    end
    return row.bag >= 19 and row.bag <= 22
end

local function ParseBags(f)
    local low = tonumber(f[2])
    if not low then
        return
    end
    local d = { money = Num(f[3]), flags = f[4] or "", equip = {}, items = {}, at = GetTime() }
    for _, e in ipairs(BT.List(f[6])) do
        local s = BT.Split(e, ",")
        local row = {
            bag = Num(s[1]), slot = Num(s[2]), guid = s[3] or "0", entry = Num(s[4]), count = Num(s[5]),
            ench = Num(s[6]), gem1 = Num(s[7]), gem2 = Num(s[8]), gem3 = Num(s[9]), rprop = Num(s[10]),
            suffix = Num(s[11]), dur = Num(s[12]), maxdur = Num(s[13]), flags = s[14] or "", fits = {},
        }
        for _, v in ipairs(BT.List(s[15], ":")) do
            local n = tonumber(v)
            if n then
                row.fits[n] = true
            end
        end
        if row.entry > 0 then
            if row.bag == 255 and row.slot < 19 then
                d.equip[row.slot] = row
            elseif IsBagPos(row) then
                d.items[#d.items + 1] = row
            end
        end
    end
    state.bags[low] = d
    return low
end

local function ParseStats(f)
    local low = tonumber(f[2])
    if not low then
        return
    end
    local st = {}
    for _, kv in ipairs(BT.List(f[3])) do
        local k, v = string.match(kv, "^([^=]+)=(.*)$")
        if k then
            st[k] = tonumber(v) or 0
        end
    end
    state.stats[low] = st
    return low
end

local function ParseOutfits(f)
    local low = tonumber(f[2])
    if not low then
        return
    end
    local list = {}
    for _, e in ipairs(BT.List(f[3])) do
        local s = BT.Split(e, ",")
        local idx = tonumber(s[1])
        if idx then
            local items = {}
            for _, it in ipairs(BT.List(s[3], ":")) do
                local p = BT.Split(it, ".")
                items[#items + 1] = { slot = tonumber(p[1]), entry = tonumber(p[2]), guid = p[3] }
            end
            list[#list + 1] = { idx = idx, name = BT.Unesc(s[2]), items = items }
        end
    end
    table.sort(list, function(a, b) return a.idx < b.idx end)
    state.outfits[low] = list
    return low
end

-- REPS <bot> <flags> <rows>: id,nameEsc,parent,rank,bar,max,flags (party-extras-spec 4.2)
local function ParseReps(f)
    local low = tonumber(f[2])
    if not low then
        return
    end
    local rows = {}
    for _, e in ipairs(BT.List(f[4])) do
        local s = BT.Split(e, ",")
        local id = tonumber(s[1])
        if id then
            rows[#rows + 1] = {
                id = id, name = BT.Unesc(s[2]), parent = Num(s[3]), rank = Num(s[4]), bar = Num(s[5]),
                max = Num(s[6]), flags = s[7] or "",
            }
        end
    end
    state.reps[low] = { trunc = f[3] == "T", rows = rows }
    return low
end

-- SKILLS <bot> <rows>: id,cat,value,max,pureMax,nameEsc
local function ParseSkills(f)
    local low = tonumber(f[2])
    if not low then
        return
    end
    local rows = {}
    for _, e in ipairs(BT.List(f[3])) do
        local s = BT.Split(e, ",")
        local id = tonumber(s[1])
        if id then
            rows[#rows + 1] = {
                id = id, cat = Num(s[2]), value = Num(s[3]), max = Num(s[4]), pureMax = Num(s[5]), name = BT.Unesc(s[6]),
            }
        end
    end
    state.skills[low] = rows
    return low
end

-- ---------------------------------------------------------------- pane

local pane
local ui = { slots = {}, facing = 0, zoom = 0, sections = {}, pending = {} }
G.ui = ui

local function Render() G.Render() end

local function Request(low)
    K.Send("INV", low)
    K.Send("STATS", low)
    K.Send("OUTFITS", low)
    G.RequestDynamic(low)
    K.Inspect(low)
end

pane = K.Tab("gear", L.gear_tab, Request, Render, function()
    if ui.flyout then
        ui.flyout:Hide()
    end
end)
G.pane = pane

-- character frame (scaled down when the pane is shorter than 440)
local doll = CreateFrame("Frame", nil, pane)
doll:SetWidth(FRAME_W)
doll:SetHeight(FRAME_H)
doll:SetPoint("TOPLEFT", 0, 0)
ui.doll = doll

do
    local base = "Interface\\PaperDollInfoFrame\\UI-Character-General-"
    local crop = (FRAME_H - 256) / 256
    local parts = {
        { "TopLeft", 256, 256, 0, 0, 1 }, { "TopRight", 128, 256, 256, 0, 1 },
        { "BottomLeft", 256, FRAME_H - 256, 0, -256, crop }, { "BottomRight", 128, FRAME_H - 256, 256, -256, crop },
    }
    for _, p in ipairs(parts) do
        local t = doll:CreateTexture(nil, "BACKGROUND")
        t:SetTexture(base .. p[1])
        t:SetWidth(p[2])
        t:SetHeight(p[3])
        t:SetPoint("TOPLEFT", p[4], p[5])
        t:SetTexCoord(0, 1, 0, p[6])
    end
end

ui.name = doll:CreateFontString(nil, "OVERLAY", "GameFontNormal")
ui.name:SetPoint("TOPLEFT", 74, -16)
ui.name:SetWidth(250)
ui.name:SetJustifyH("CENTER")
ui.level = doll:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ui.level:SetPoint("TOPLEFT", 74, -36)
ui.level:SetWidth(250)
ui.level:SetJustifyH("CENTER")

-- model
local model = CreateFrame("PlayerModel", "BotTacticsGearModel", doll)
model:SetWidth(231)
model:SetHeight(250)
model:SetPoint("TOPLEFT", 66, -76)
model:EnableMouseWheel(true)
model:SetScript("OnMouseWheel", function(self, delta)
    ui.zoom = math.max(ZOOM_MIN, math.min(ZOOM_MAX, ui.zoom + delta * 0.15))
    self:SetPosition(ui.zoom, 0, 0)
end)
ui.model = model

ui.far = W.Text(doll, "GameFontDisableSmall", W.MUTED, "CENTER")
ui.far:SetPoint("CENTER", doll, "TOPLEFT", 66 + 115, -76 - 125)
ui.far:SetText(L.gear_far)

local function Rotate(dir)
    ui.facing = ui.facing + dir * 0.35
    model:SetFacing(ui.facing)
end

local rotL = W.IconButton(doll, 26, "Interface\\Buttons\\UI-RotationLeft-Button-Up",
    "Interface\\Buttons\\UI-RotationLeft-Button-Down", "Interface\\Buttons\\ButtonHilight-Round", L.gear_rotLeft)
rotL:SetPoint("TOPLEFT", 76, -80)
rotL:SetFrameLevel(model:GetFrameLevel() + 2)
rotL:SetScript("OnClick", function() Rotate(-1) end)
local rotR = W.IconButton(doll, 26, "Interface\\Buttons\\UI-RotationRight-Button-Up",
    "Interface\\Buttons\\UI-RotationRight-Button-Down", "Interface\\Buttons\\ButtonHilight-Round", L.gear_rotRight)
rotR:SetPoint("TOPLEFT", 262, -80)
rotR:SetFrameLevel(model:GetFrameLevel() + 2)
rotR:SetScript("OnClick", function() Rotate(1) end)

function G.RefreshModel()
    local low = K.Current()
    local unit = K.Unit(low)
    if unit and UnitIsVisible(unit) then
        model:Show()
        model:SetUnit(unit)
        model:SetFacing(ui.facing)
        model:SetPosition(ui.zoom, 0, 0)
        ui.far:Hide()
        ui.modelUnit = unit
    else
        model:Hide()
        ui.far:Show()
        ui.modelUnit = nil
    end
end

-- ---------------------------------------------------------------- slot buttons

local function SlotTooltip(self)
    local low = K.Current()
    local d = low and state.bags[low]
    local row = d and d.equip[self.slot]
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if row then
        GameTooltip:SetHyperlink(ItemLink(row, BotLevel(low)))
        if row.maxdur > 0 and row.dur < row.maxdur * 0.2 then
            GameTooltip:AddLine(string.format(L.gear_brokenTip, row.dur, row.maxdur), 1, 0.3, 0.3)
            GameTooltip:Show()
        end
    else
        GameTooltip:SetText(SlotLabel(self.slot), 1, 1, 1)
        GameTooltip:AddLine(L.gear_empty, 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end
end

local function CreateSlot(slot)
    local name = "BotTacticsGearSlot" .. slot
    local b = CreateFrame("Button", name, doll, "ItemButtonTemplate")
    b.slot = slot
    b:SetPoint("TOPLEFT", SLOT_POS[slot][1], -SLOT_POS[slot][2])
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.icon = _G[name .. "IconTexture"] or b:CreateTexture(nil, "BORDER")
    b.icon:SetAllPoints(b)
    local _, empty = GetInventorySlotInfo(SLOT_INFO[slot][1])
    b.emptyTex = empty
    b.border = b:CreateTexture(nil, "OVERLAY")
    b.border:SetTexture(QUALITY_BORDER)
    b.border:SetBlendMode("ADD")
    b.border:SetWidth(67)
    b.border:SetHeight(67)
    b.border:SetPoint("CENTER", b, "CENTER", 0, 1)
    b.border:Hide()
    b.ilvl = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    b.ilvl:SetPoint("BOTTOMLEFT", 2, 2)
    b:SetScript("OnEnter", SlotTooltip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self)
        local low = K.Current()
        local d = low and state.bags[low]
        local row = d and d.equip[self.slot]
        if row and IsModifiedClick and IsModifiedClick("CHATLINK") then
            local _, link = GetItemInfo(ItemLink(row, BotLevel(low)))
            if link and ChatEdit_InsertLink then
                ChatEdit_InsertLink(link)
            end
            return
        end
        G.ToggleFlyout(self)
    end)
    ui.slots[slot] = b
    return b
end

for slot = 0, 18 do
    CreateSlot(slot)
end

local function RenderSlots(low)
    local d = low and state.bags[low]
    local st = low and state.stats[low]
    local avg = st and st.ilvl or 0
    for slot, b in pairs(ui.slots) do
        local row = d and d.equip[slot]
        if row then
            local _, quality, ilvl = ItemData(row, low)
            b.icon:SetTexture(GetItemIcon(row.entry) or BT.ICON_UNKNOWN)
            if row.maxdur > 0 and row.dur < row.maxdur * 0.2 then
                b.icon:SetVertexColor(1, 0.3, 0.3)
            else
                b.icon:SetVertexColor(1, 1, 1)
            end
            if quality and quality >= 2 then
                local r, g, bl = GetItemQualityColor(quality)
                b.border:SetVertexColor(r, g, bl)
                b.border:Show()
            else
                b.border:Hide()
            end
            if ilvl and ilvl > 0 then
                b.ilvl:SetText(ilvl)
                if avg > 0 and ilvl >= avg + 10 then
                    b.ilvl:SetTextColor(0.12, 1, 0)
                elseif avg > 0 and ilvl <= avg - 10 then
                    b.ilvl:SetTextColor(0.62, 0.62, 0.62)
                else
                    b.ilvl:SetTextColor(1, 1, 1)
                end
            else
                b.ilvl:SetText("")
            end
        else
            b.icon:SetTexture(b.emptyTex)
            b.icon:SetVertexColor(1, 1, 1)
            b.border:Hide()
            b.ilvl:SetText("")
        end
    end
end

-- ---------------------------------------------------------------- flyout

local FLY_W, FLY_ROW = 280, 30
local FLY_MAX = 10

local fly = CreateFrame("Frame", "BotTacticsGearFlyout", pane)
fly:SetWidth(FLY_W)
fly:SetFrameStrata("DIALOG")
fly:EnableMouse(true)
W.Panel(fly, { 0.055, 0.043, 0.03, 0.98 }, W.GOLD_DIM)
fly:Hide()
ui.flyout = fly
-- Escape closes menus (UIMenus) before windows, so the main window stays open
if UIMenus then
    tinsert(UIMenus, "BotTacticsGearFlyout")
end

fly.head = W.Text(fly, "GameFontNormalSmall", W.GOLD_DIM)
fly.head:SetPoint("TOPLEFT", 10, -8)

local function FlyRow(parent, clickable)
    local r = CreateFrame("Button", nil, parent)
    r:SetWidth(FLY_W - 10)
    r:SetHeight(FLY_ROW)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetWidth(24)
    r.icon:SetHeight(24)
    r.icon:SetPoint("LEFT", 4, 0)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    r.text = W.Text(r, "GameFontHighlightSmall", W.TEXT)
    r.text:SetPoint("LEFT", 34, 0)
    r.text:SetPoint("RIGHT", -40, 0)
    r.text:SetHeight(12)
    r.right = W.Text(r, "GameFontDisableSmall", W.FAINT, "RIGHT")
    r.right:SetPoint("RIGHT", -6, 0)
    if clickable then
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    end
    r:SetScript("OnEnter", function(self)
        if self.link then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.link)
        end
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return r
end

fly.cur = FlyRow(fly, false)
fly.rows = {}
for i = 1, FLY_MAX do
    local r = FlyRow(fly, true)
    r:SetScript("OnClick", function(self)
        G.Equip(self.row)
    end)
    fly.rows[i] = r
end
fly.none = W.Text(fly, "GameFontDisableSmall", W.FAINT)
fly.unequip = CreateFrame("Button", nil, fly)
fly.unequip:SetWidth(FLY_W - 10)
fly.unequip:SetHeight(22)
fly.unequip:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
fly.unequip.text = W.Text(fly.unequip, "GameFontNormalSmall", W.GOLD)
fly.unequip.text:SetPoint("LEFT", 8, 0)
fly.unequip.text:SetText(L.gear_unequip)
fly.unequip:SetScript("OnClick", function()
    G.Unequip(fly.slot)
end)

-- click outside closes the flyout
fly:SetScript("OnUpdate", function(self)
    if not IsMouseButtonDown then
        return
    end
    local down = IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")
    if down and not MouseIsOver(self) and not (self.owner and MouseIsOver(self.owner)) then
        self:Hide()
    end
end)

local function FillRow(r, row, low, rightText)
    local name, quality, ilvl = ItemData(row, low)
    r.row = row
    r.link = ItemLink(row, BotLevel(low))
    r.icon:SetTexture(GetItemIcon(row.entry) or BT.ICON_UNKNOWN)
    BT.OneLine(r.text, name or ("item " .. row.entry), FLY_W - 10 - 34 - 40)
    if quality then
        local cr, cg, cb = GetItemQualityColor(quality)
        r.text:SetTextColor(cr, cg, cb)
    else
        W.Color(r.text, W.TEXT)
    end
    r.right:SetText(rightText or (ilvl and tostring(ilvl)) or "")
end

function G.OpenFlyout(button)
    local low = K.Current()
    local d = low and state.bags[low]
    if not d then
        return
    end
    local slot = button.slot
    fly.slot, fly.owner = slot, button
    fly.head:SetText(SlotLabel(slot))
    local y = -26
    local cur = d.equip[slot]
    if cur then
        FillRow(fly.cur, cur, low, L.gear_current)
        fly.cur:SetPoint("TOPLEFT", 5, y)
        fly.cur:Show()
        y = y - FLY_ROW
    else
        fly.cur:Hide()
    end
    local cands = {}
    for _, row in ipairs(d.items) do
        if row.fits[slot] then
            local _, _, ilvl = ItemData(row, low)
            cands[#cands + 1] = { row = row, ilvl = ilvl or 0 }
        end
    end
    table.sort(cands, function(a, b) return a.ilvl > b.ilvl end)
    for i, r in ipairs(fly.rows) do
        local c = cands[i]
        if c then
            FillRow(r, c.row, low)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 5, y)
            r:Show()
            y = y - FLY_ROW
        else
            r:Hide()
        end
    end
    if #cands == 0 then
        fly.none:ClearAllPoints()
        fly.none:SetPoint("TOPLEFT", 10, y - 4)
        fly.none:SetText(L.gear_noFit)
        fly.none:Show()
        y = y - 20
    else
        fly.none:Hide()
    end
    if cur then
        fly.unequip:ClearAllPoints()
        fly.unequip:SetPoint("TOPLEFT", 5, y - 2)
        fly.unequip:Show()
        y = y - 24
    else
        fly.unequip:Hide()
    end
    fly:SetHeight(-y + 8)
    fly:ClearAllPoints()
    if slot >= 15 and slot <= 17 then
        fly:SetPoint("BOTTOMLEFT", button, "TOPLEFT", 0, 4)
    elseif SLOT_POS[slot][1] > 200 then
        fly:SetPoint("TOPRIGHT", button, "TOPLEFT", -4, 0)
    else
        fly:SetPoint("TOPLEFT", button, "TOPRIGHT", 4, 0)
    end
    fly:Show()
end

function G.ToggleFlyout(button)
    if fly:IsShown() and fly.owner == button then
        fly:Hide()
    else
        G.OpenFlyout(button)
    end
end

-- ---------------------------------------------------------------- item actions

local function SendItem(low, op, row, a, b)
    ui.pending[low] = { at = GetTime(), op = op }
    K.Send("ITEM", low, op, row.bag, row.slot, row.guid, a or 0, b or 0)
end

function G.Equip(row)
    local low = K.Current()
    if low and row then
        SendItem(low, "equip", row)
    end
    fly:Hide()
end

function G.Unequip(slot)
    local low = K.Current()
    local d = low and state.bags[low]
    local row = d and d.equip[slot]
    if row then
        SendItem(low, "unequip", row)
    end
    fly:Hide()
end

-- ---------------------------------------------------------------- stats sidebar

local function F2(v) return string.format("%.2f", v or 0) end
local function D(v) return string.format("%d", math.floor((v or 0) + 0.5)) end
local function Pct(v) return string.format("%.2f%%", v or 0) end
local function Rating(st, key)
    return string.format("%d (%.2f%%)", math.floor((st["cr_" .. key] or 0) + 0.5), st["crb_" .. key] or 0)
end
local function Range(a, b) return string.format("%d - %d", math.floor((a or 0) + 0.5), math.floor((b or 0) + 0.5)) end

-- primary stat: value, colour (green = positive mods, red = negative mods, as PaperDollFrame)
local function Primary(key)
    return function(st)
        local neg, pos = st[key .. "_neg"] or 0, st[key .. "_pos"] or 0
        local c
        if math.abs(neg) > 0.001 then
            c = { 1, 0.13, 0.13 }
        elseif pos > 0.001 then
            c = { 0.12, 1, 0 }
        end
        return D(st[key]), c
    end
end

-- Dynamic sections (party-extras-spec 6.2): build(low) -> { {label, value, color, indent, labelColor}, ... }
local REP_LABELS = {
    S("Hated", "Ненависть"), S("Hostile", "Враждебность"), S("Unfriendly", "Неприязнь"), S("Neutral", "Равнодушие"),
    S("Friendly", "Дружелюбие"), S("Honored", "Уважение"), S("Revered", "Почтение"), S("Exalted", "Превознесение"),
}
local REP_COLORS = {
    { 0.8, 0.3, 0.22 }, { 0.8, 0.3, 0.22 }, { 0.75, 0.27, 0 }, { 0.9, 0.7, 0 },
    { 0, 0.6, 0.1 }, { 0, 0.6, 0.1 }, { 0, 0.6, 0.1 }, { 0, 0.6, 0.1 },
}
local LABEL_C = { 1, 0.82, 0 }
local MUTED_C = { 0.5, 0.5, 0.5 }

local function RepLine(r, indent)
    local i = math.max(1, math.min(8, r.rank + 1))
    local label = (_G and _G["FACTION_STANDING_LABEL" .. i]) or REP_LABELS[i]
    local value = r.max > 0 and (label .. " " .. r.bar .. "/" .. r.max) or label
    local bc = FACTION_BAR_COLORS and FACTION_BAR_COLORS[i]
    local color = bc and { bc.r or bc[1] or 1, bc.g or bc[2] or 1, bc.b or bc[3] or 1 } or REP_COLORS[i]
    local name, lc = BT.Show(r.name), LABEL_C
    if string.find(r.flags, "i", 1, true) then
        lc = MUTED_C
        name = name .. " (" .. L.gear_inactive .. ")"
    end
    if string.find(r.flags, "w", 1, true) then
        name = name .. " |cffff4040(" .. L.gear_atWar .. ")|r"
    end
    return { name, value, color, indent, lc }
end

local function BuildReps(low)
    local d = low and state.reps[low]
    if not d then
        return nil
    end
    local byId, children, top = {}, {}, {}
    for _, r in ipairs(d.rows) do
        byId[r.id] = r
    end
    for _, r in ipairs(d.rows) do
        if r.parent ~= 0 and byId[r.parent] and r.parent ~= r.id then
            local c = children[r.parent] or {}
            children[r.parent] = c
            c[#c + 1] = r
        else
            top[#top + 1] = r
        end
    end
    local out, done = {}, {}
    local function Emit(r, depth)
        if done[r.id] then
            return
        end
        done[r.id] = true
        out[#out + 1] = RepLine(r, depth * 12)
        for _, c in ipairs(children[r.id] or {}) do
            Emit(c, math.min(depth + 1, 3))
        end
    end
    for _, r in ipairs(top) do
        Emit(r, 0)
    end
    -- a parent cycle leaves rows unreached: list them at the top level
    for _, r in ipairs(d.rows) do
        Emit(r, 0)
    end
    return out
end

local function BuildSkills(low)
    local rows = low and state.skills[low]
    if not rows then
        return nil
    end
    local out = {}
    for _, r in ipairs(rows) do
        local c = r.max > r.pureMax and { 0.12, 1, 0 } or { 1, 1, 1 }
        out[#out + 1] = { BT.Show(r.name), r.value .. " / " .. r.max, c, 0, LABEL_C }
    end
    return out
end
G.BuildReps, G.BuildSkills = BuildReps, BuildSkills

local SECTIONS = {
    { id = "ilvl", title = L.gear_secIlvl, big = function(st) return D(st.ilvl) end },
    { id = "base", title = L.gear_secBase, rows = {
        { L.gear_str, Primary("str") }, { L.gear_agi, Primary("agi") }, { L.gear_sta, Primary("sta") },
        { L.gear_int, Primary("int") }, { L.gear_spi, Primary("spi") }, { L.gear_armor, function(st) return D(st.armor) end },
    } },
    { id = "spell", title = L.gear_secSpell, rows = {
        { L.gear_spellDmg, function(st) return D(st.sp) end },
        { L.gear_spellHeal, function(st) return D(st.heal) end },
        { L.gear_hit, function(st) return Rating(st, "hit_spell") end },
        { L.gear_crit, function(st) return Pct(st.s_crit) end },
        { L.gear_haste, function(st) return Rating(st, "haste_spell") end },
        { L.gear_mp5, function(st) return string.format("%d / %d", math.floor((st.mp5 or 0) + 0.5), math.floor((st.mp5_cast or 0) + 0.5)) end },
    } },
    { id = "melee", title = L.gear_secMelee, rows = {
        { L.gear_damage, function(st) return Range(st.dmg_min, st.dmg_max) end },
        { L.gear_speed, function(st)
            if (st.oh_speed or 0) > 0 then
                return F2(st.speed) .. " / " .. F2(st.oh_speed)
            end
            return F2(st.speed)
        end },
        { L.gear_ap, function(st) return D(st.ap) end },
        { L.gear_hit, function(st) return Rating(st, "hit_melee") end },
        { L.gear_crit, function(st) return Pct(st.crit) end },
        { L.gear_haste, function(st) return Rating(st, "haste_melee") end },
        { L.gear_expertise, function(st) return D(st.expertise) end },
        { L.gear_arpen, function(st) return Rating(st, "arpen") end },
    } },
    { id = "ranged", title = L.gear_secRanged, rows = {
        { L.gear_damage, function(st) return Range(st.r_min, st.r_max) end },
        { L.gear_speed, function(st) return F2(st.r_speed) end },
        { L.gear_ap, function(st) return D(st.rap) end },
        { L.gear_hit, function(st) return Rating(st, "hit_ranged") end },
        { L.gear_crit, function(st) return Pct(st.r_crit) end },
        { L.gear_haste, function(st) return Rating(st, "haste_ranged") end },
    } },
    { id = "defense", title = L.gear_secDefense, rows = {
        { L.gear_armor, function(st) return D(st.armor) end },
        { L.gear_defense, function(st) return D(st.defense) end },
        { L.gear_dodge, function(st) return Pct(st.dodge) end },
        { L.gear_parry, function(st) return Pct(st.parry) end },
        { L.gear_block, function(st) return Pct(st.block) end },
        { L.gear_resilience, function(st) return Rating(st, "resilience") end },
    } },
    { id = "resist", title = L.gear_secResist, rows = {
        { L.gear_resArcane, function(st) return D(st.res6) end },
        { L.gear_resFire, function(st) return D(st.res2) end },
        { L.gear_resNature, function(st) return D(st.res3) end },
        { L.gear_resFrost, function(st) return D(st.res4) end },
        { L.gear_resShadow, function(st) return D(st.res5) end },
    } },
    { id = "reps", title = L.gear_secReps, dynamic = true, build = BuildReps, request = "REPS" },
    { id = "skills", title = L.gear_secSkills, dynamic = true, build = BuildSkills, request = "SKILLS" },
}

-- default open sections by class / role (spec 6.4)
local CASTERS = { [5] = true, [8] = true, [9] = true }
local MELEE = { [1] = true, [4] = true, [6] = true }
local function DefaultOpen(id, low)
    if id == "ilvl" or id == "base" then
        return true
    elseif id == "reps" or id == "skills" then
        return false
    end
    local b = K.Bot(low)
    local cls = b and tonumber(b.class)
    local role = b and b.role
    if role == "tank" then
        return id == "defense"
    elseif role == "heal" then
        return id == "spell"
    end
    if cls == 3 then
        return id == "ranged"
    elseif CASTERS[cls] then
        return id == "spell"
    elseif MELEE[cls] then
        return id == "melee"
    end
    return id == "melee" or id == "spell"
end

local function IsOpen(id, low)
    local db = BotTacticsDB and BotTacticsDB.statSections
    if db and db[id] ~= nil then
        return db[id]
    end
    return DefaultOpen(id, low)
end

local statScroll, statChild = K.Scroll(pane, "BotTacticsGearStatsScroll", SIDEBAR_W - 26)
ui.statScroll = statScroll

-- One stat line (label left, value right); static sections make theirs once, dynamic ones on demand.
local function MakeLine(i)
    local line = CreateFrame("Frame", nil, statChild)
    line:SetWidth(SIDEBAR_W - 26)
    line:SetHeight(16)
    if i % 2 == 0 then
        local bg = line:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(line)
        bg:SetTexture(1, 1, 1, 0.035)
    end
    line.value = W.Text(line, "GameFontHighlightSmall", { 1, 1, 1 }, "RIGHT")
    line.value:SetPoint("RIGHT", -8, 0)
    line.label = W.Text(line, "GameFontNormalSmall", { 1, 0.82, 0 })
    line.label:SetPoint("LEFT", 8, 0)
    line.label:SetHeight(14)
    return line
end

for _, sec in ipairs(SECTIONS) do
    local h = CreateFrame("Button", nil, statChild)
    h:SetWidth(SIDEBAR_W - 26)
    h:SetHeight(22)
    W.Panel(h, { 0.20, 0.155, 0.10, 0.95 }, { 0.35, 0.29, 0.18 })
    h.sign = h:CreateTexture(nil, "ARTWORK")
    h.sign:SetWidth(14)
    h.sign:SetHeight(14)
    h.sign:SetPoint("LEFT", 6, 0)
    h.text = W.Text(h, "GameFontNormal", W.TEXT, "CENTER")
    h.text:SetPoint("LEFT", 22, 0)
    h.text:SetPoint("RIGHT", -22, 0)
    h.text:SetText(sec.title)
    h:SetScript("OnClick", function()
        BotTacticsDB = BotTacticsDB or {}
        BotTacticsDB.statSections = BotTacticsDB.statSections or {}
        local low = K.Current()
        local open = not IsOpen(sec.id, low)
        BotTacticsDB.statSections[sec.id] = open
        -- a dynamic section loads its data when it is opened
        if open and sec.dynamic and low then
            K.Send(sec.request, low)
        end
        G.RenderStats()
    end)
    sec.header = h
    sec.lines = {}
    if sec.big then
        local fs = W.Text(statChild, "GameFontHighlightLarge", nil, "CENTER")
        fs:SetWidth(SIDEBAR_W - 26)
        sec.bigText = fs
    elseif not sec.dynamic then
        for i, def in ipairs(sec.rows) do
            local line = MakeLine(i)
            line.label:SetText(def[1])
            sec.lines[i] = line
        end
    end
end

-- Requests of the open dynamic sections (Request() of the tab).
function G.RequestDynamic(low)
    for _, sec in ipairs(SECTIONS) do
        if sec.dynamic and IsOpen(sec.id, low) then
            K.Send(sec.request, low)
        end
    end
end

function G.RenderStats()
    local low = K.Current()
    local st = (low and state.stats[low]) or {}
    local y = 0
    for _, sec in ipairs(SECTIONS) do
        local open = IsOpen(sec.id, low)
        sec.header:ClearAllPoints()
        sec.header:SetPoint("TOPLEFT", 0, -y)
        sec.header.sign:SetTexture(open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
        y = y + 24
        if sec.bigText then
            W.Show(sec.bigText, open)
            if open then
                sec.bigText:ClearAllPoints()
                sec.bigText:SetPoint("TOPLEFT", 0, -y - 4)
                sec.bigText:SetText(state.stats[low] and D(st.ilvl) or "-")
                y = y + 30
            end
        elseif sec.dynamic then
            local list = {}
            if open then
                list = sec.build(low) or {}
                if #list == 0 then
                    list = { { L.gear_noData, "", nil, 0, MUTED_C } }
                end
            end
            for i, def in ipairs(list) do
                local line = sec.lines[i]
                if not line then
                    line = MakeLine(i)
                    sec.lines[i] = line
                end
                line:ClearAllPoints()
                line:SetPoint("TOPLEFT", 0, -y)
                line.label:ClearAllPoints()
                line.label:SetPoint("LEFT", 8 + (def[4] or 0), 0)
                line.label:SetPoint("RIGHT", line.value, "LEFT", -6, 0)
                line.value:SetText(def[2] or "")
                -- one line: a long faction / skill name is cut, never wrapped over the next row (audit G1)
                W.FitText(line.label, def[1], SIDEBAR_W - 26 - 8 - (def[4] or 0) - line.value:GetStringWidth() - 6 - 8, line)
                local lc = def[5] or LABEL_C
                line.label:SetTextColor(lc[1], lc[2], lc[3])
                local c = def[3] or { 1, 1, 1 }
                line.value:SetTextColor(c[1], c[2], c[3])
                line:Show()
                y = y + 16
            end
            for i = #list + 1, #sec.lines do
                sec.lines[i]:Hide()
            end
            if open then
                y = y + 4
            end
        else
            for i, line in ipairs(sec.lines) do
                W.Show(line, open)
                if open then
                    line:ClearAllPoints()
                    line:SetPoint("TOPLEFT", 0, -y)
                    local text, c = sec.rows[i][2](st)
                    line.value:SetText(state.stats[low] and text or "-")
                    c = c or { 1, 1, 1 }
                    line.value:SetTextColor(c[1], c[2], c[3])
                    y = y + 16
                end
            end
            if open then
                y = y + 4
            end
        end
    end
    statChild:SetHeight(math.max(10, y))
end

-- ---------------------------------------------------------------- bottom strip: outfits, autogear

local outfitButton = W.Pick(pane, 150, 22, false, true)
outfitButton.text:SetText(L.gear_outfit)
ui.outfitButton = outfitButton

local autoButton = W.Tab(pane, 22)
W.FitTab(autoButton, L.gear_autogear, 100)
W.SetTabSelected(autoButton, false)
autoButton.tip = L.gear_autogearTip
autoButton:SetScript("OnClick", function()
    local low = K.Current()
    if low then
        K.Confirm("autogear", L.gear_autogearConfirm, function()
            K.Send("CMD", low, BT.Esc("autogear"))
            ui.pending[low] = { at = GetTime(), op = "autogear" }
        end)
    end
end)
ui.autoButton = autoButton

-- data = { low, op ("save" | "rename"), idx }
function G.OutfitNamed(data, name)
    name = BT.Trim(name or "")
    if not data or name == "" then
        return
    end
    K.Send("OUTFIT", data.low, data.op, data.idx, BT.Esc(name))
end

local function AskName(low, op, idx, name)
    local data = { low = low, op = op, idx = idx }
    return K.Prompt("outfit", L.gear_outfitName, name or "", function(text)
        G.OutfitNamed(data, text)
    end)
end
G.AskName = AskName

function G.OutfitMenu(anchor)
    local low = K.Current()
    if not low then
        return
    end
    local list = state.outfits[low] or {}
    local items = { { text = L.gear_outfit, isTitle = true, notCheckable = true } }
    local used = {}
    for _, o in ipairs(list) do
        used[o.idx] = true
        local idx, name = o.idx, o.name
        items[#items + 1] = {
            text = BT.Show(name), notCheckable = true, hasArrow = true,
            func = function()
                K.Send("OUTFIT", low, "wear", idx, BT.Esc(name))
                CloseDropDownMenus()
            end,
            menuList = {
                { text = L.gear_outfitWear, notCheckable = true, func = function()
                    K.Send("OUTFIT", low, "wear", idx, BT.Esc(name))
                    CloseDropDownMenus()
                end },
                { text = L.gear_outfitSaveHere, notCheckable = true, func = function()
                    K.Send("OUTFIT", low, "save", idx, BT.Esc(name))
                    CloseDropDownMenus()
                end },
                { text = L.gear_outfitRename, notCheckable = true, func = function()
                    CloseDropDownMenus()
                    AskName(low, "rename", idx, name)
                end },
                { text = L.gear_outfitDelete, notCheckable = true, func = function()
                    CloseDropDownMenus()
                    K.Confirm("outfitdel", string.format(L.gear_outfitDelConfirm, BT.Show(name)), function()
                        K.Send("OUTFIT", low, "del", idx, "")
                    end)
                end },
            },
        }
    end
    if #list == 0 then
        items[#items + 1] = { text = L.gear_outfitNone, notCheckable = true, disabled = true }
    end
    local free
    for i = 1, 8 do
        if not used[i] then
            free = i
            break
        end
    end
    items[#items + 1] = {
        text = free and L.gear_outfitNew or L.gear_outfitFull, notCheckable = true, disabled = not free,
        func = function()
            CloseDropDownMenus()
            AskName(low, "save", free, "")
        end,
    }
    K.Menu(anchor, items)
end

outfitButton:SetScript("OnClick", function(self)
    G.OutfitMenu(self)
end)

-- ---------------------------------------------------------------- layout + render

function G.Layout()
    local w, h = K.PaneSize(pane)
    local scale = math.min(1, h / FRAME_H)
    doll:SetScale(scale)
    local x = FRAME_W * scale + 12
    local sideW = math.min(SIDEBAR_W, w - x)
    statScroll:ClearAllPoints()
    statScroll:SetPoint("TOPLEFT", pane, "TOPLEFT", x, 0)
    statScroll:SetWidth(sideW - 22)
    statScroll:SetHeight(h - 32)
    outfitButton:ClearAllPoints()
    outfitButton:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", x, 2)
    autoButton:ClearAllPoints()
    autoButton:SetPoint("LEFT", outfitButton, "RIGHT", 8, 0)
end

function G.Render()
    G.Layout()
    local low = K.Current()
    local b = K.Bot(low)
    if not b then
        ui.name:SetText(L.gear_noBot)
        ui.level:SetText("")
    else
        local r, g, bl = BT.ClassColor(b.class)
        ui.name:SetText(BT.Show(b.name))
        ui.name:SetTextColor(r, g, bl)
        ui.level:SetText(string.format(L.gear_levelLine, b.level or 0, BT.ClassName(b.class)))
    end
    RenderSlots(low)
    G.RenderStats()
    if ui.modelUnit ~= K.Unit(low) or not model:IsShown() then
        G.RefreshModel()
    end
    local list = low and state.outfits[low]
    outfitButton.text:SetText(L.gear_outfit .. (list and #list > 0 and (" (" .. #list .. ")") or ""))
    if fly:IsShown() and fly.owner then
        if low and state.bags[low] then
            G.OpenFlyout(fly.owner)
        else
            fly:Hide()
        end
    end
end

-- ---------------------------------------------------------------- messages

local function Visible(low)
    return pane:IsVisible() and low and low == K.Current()
end

K.Hook("BAGS", function(f)
    local low = ParseBags(f)
    if Visible(low) then
        G.Render()
    end
end)

K.Hook("STATS", function(f)
    local low = ParseStats(f)
    if Visible(low) then
        G.Render()
    end
end)

K.Hook("OUTFITS", function(f)
    local low = ParseOutfits(f)
    if Visible(low) then
        G.Render()
    end
end)

K.Hook("REPS", function(f)
    local low = ParseReps(f)
    if Visible(low) then
        G.RenderStats()
    end
end)

K.Hook("SKILLS", function(f)
    local low = ParseSkills(f)
    if Visible(low) then
        G.RenderStats()
    end
end)

-- Widgets for the mock tests (scratchpad bt_test).
function G.ForTest()
    local out = {}
    for _, sec in ipairs(SECTIONS) do
        if sec.id == "reps" then
            out.repsSection, out.repsLines = sec.header, sec.lines
        elseif sec.id == "skills" then
            out.skillsSection, out.skillsLines = sec.header, sec.lines
        end
    end
    return out
end

-- Follow-ups of actions started here: fresh stats after an equip change; stale bags -> reload.
K.Hook("ACK", function(f)
    local low, op, ok, code = K.Ack(f)
    local pend = low and ui.pending[low]
    if not pend or GetTime() - pend.at > 10 then
        if op == "OUTFIT" and ok and low then
            K.Send("STATS", low)
        end
        return
    end
    if op == "ITEM" or (op == "CMD" and pend.op == "autogear") then
        ui.pending[low] = nil
        if ok then
            K.Send("STATS", low)
            if pend.op == "autogear" then
                BT.After("gearAuto" .. low, 3, function()
                    K.Send("INV", low)
                    K.Send("STATS", low)
                end)
            end
        elseif code == "stale" and not K.sharedAck then
            K.Send("INV", low)
        end
    elseif op == "OUTFIT" and ok then
        K.Send("STATS", low)
    end
end)

-- model refresh on the bot's appearance changes
local events = CreateFrame("Frame")
events:RegisterEvent("UNIT_MODEL_CHANGED")
events:RegisterEvent("UNIT_INVENTORY_CHANGED")
events:SetScript("OnEvent", function(_, _, unit)
    if pane:IsVisible() and unit and unit == ui.modelUnit then
        G.RefreshModel()
    end
end)
