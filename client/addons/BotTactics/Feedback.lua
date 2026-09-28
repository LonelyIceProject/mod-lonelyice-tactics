-- Fired-rule feedback (spec 5.4 FIRED): highlight the rule row in the editor and float a short
-- label (the rule's action name) over the bot's party frame, fading in ~1.5 s.

local BT = BotTactics
local W, P = BT.W, BT.Protocol

local F = {}
BT.Feedback = F

local FLOAT_TIME = 1.6
local RISE = 16
local labels = {}          -- anchor frame -> label
local pool = {}
local autoGet = {}         -- bot -> time of the last GET asked for a label

local ticker = CreateFrame("Frame")
ticker:Hide()

local function Acquire()
    local f = table.remove(pool)
    if not f then
        f = CreateFrame("Frame", nil, UIParent)
        f:SetFrameStrata("DIALOG")
        f:SetWidth(200)
        f:SetHeight(16)
        f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.text:SetPoint("BOTTOMLEFT")
        f.text:SetJustifyH("LEFT")
        f.text:SetShadowOffset(1, -1)
    end
    return f
end

local function Release(anchor, f)
    labels[anchor] = nil
    f:Hide()
    f:ClearAllPoints()
    pool[#pool + 1] = f
end

ticker:SetScript("OnUpdate", function(self)
    local now = GetTime()
    local any = false
    local done
    for anchor, f in pairs(labels) do
        local t = (now - f.start) / FLOAT_TIME
        if t >= 1 or not anchor:IsVisible() then
            done = done or {}
            done[#done + 1] = anchor
        else
            any = true
            local alpha
            if t < 0.15 then
                alpha = t / 0.15
            elseif t > 0.7 then
                alpha = (1 - t) / 0.3
            else
                alpha = 1
            end
            f:SetAlpha(alpha)
            f:ClearAllPoints()
            f:SetPoint("BOTTOMLEFT", anchor, f.relPoint, f.dx, f.dy + RISE * t)
        end
    end
    if done then
        for _, anchor in ipairs(done) do
            Release(anchor, labels[anchor])
        end
    end
    if not any then
        self:Hide()
    end
end)

local function Float(anchor, text, relPoint, dx, dy, color)
    if not anchor or not anchor:IsVisible() then
        return
    end
    local f = labels[anchor] or Acquire()
    labels[anchor] = f
    f.start = GetTime()
    f.relPoint, f.dx, f.dy = relPoint, dx, dy
    f.text:SetText(text)
    local c = color or W.FIRED
    f.text:SetTextColor(c[1], c[2], c[3])
    f:SetAlpha(0)
    f:ClearAllPoints()
    f:SetPoint("BOTTOMLEFT", anchor, relPoint, dx, dy)
    f:Show()
    ticker:Show()
end

-- PartyMemberFrameN whose unit is the bot.
local function PartyFrame(bot)
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) and BT.UnitLow(unit) == bot then
            local f = _G["PartyMemberFrame" .. i]
            if f and f:IsVisible() then
                return f
            end
        end
    end
    return nil
end

-- Short label for the fired rule: its action name, or "#slot" while the rules are unknown.
local function Label(bot, list, slot)
    local p = BT.ActivePreset(bot)
    local rules = p and p[list]
    local r = rules and rules[slot]
    if r then
        local name = BT.ActionInfo(bot, r)
        if name then
            return name
        end
    end
    if not p then
        local last = autoGet[bot]
        if not last or GetTime() - last > 30 then
            autoGet[bot] = GetTime()
            P.Get(bot)
        end
    end
    return "#" .. slot
end

-- Decision slot of the server's AI layer (ai-layer-spec 8): FIRED carries the intent id, there is no row.
local AI_SLOT = 98

function F.OnFired(bot, list, slot, intent)
    local text, color
    if slot == AI_SLOT then
        text = BT.L.traceAi .. BT.Show(BT.IntentLabel(BT.Unesc(intent or "")))
        color = W.AI
    else
        BT.Editor.FlashRule(bot, list, slot)
        text = Label(bot, list, slot)
    end
    local pf = PartyFrame(bot)
    if pf then
        Float(pf, text, "TOPLEFT", 48, -6, color)
    end
    local btn = BT.Party.RosterButton(bot)
    if btn then
        Float(btn, text, "BOTTOMLEFT", 42, 2, color)
    end
end
