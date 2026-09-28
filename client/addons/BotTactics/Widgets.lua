-- Small widget factories shared by the editor and the picker (3.3.5 API only).

local BT = BotTactics
local W = {}
BT.W = W

W.GOLD = { 0.85, 0.71, 0.40 }
W.GOLD_DIM = { 0.54, 0.44, 0.26 }
W.TEXT = { 0.93, 0.87, 0.77 }
W.MUTED = { 0.65, 0.59, 0.47 }
W.FAINT = { 0.43, 0.38, 0.31 }
W.FIRED = { 0.42, 0.72, 1.00 }
W.AI = { 0.55, 0.75, 1.00 }       -- decisions of the AI layer (trace lines, floating labels)
W.WARN = { 0.91, 0.64, 0.24 }
W.RED = { 1.00, 0.35, 0.30 }
W.OWN = { 0.56, 0.89, 0.60 }
W.FOE = { 0.95, 0.60, 0.55 }
W.LINE = { 0.29, 0.23, 0.14 }

local BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

function W.Panel(frame, bg, border)
    frame:SetBackdrop(BACKDROP)
    frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 0.95)
    frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
end

function W.Color(fs, c)
    fs:SetTextColor(c[1], c[2], c[3])
end

function W.Text(parent, font, c, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    if c then
        W.Color(fs, c)
    end
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

W.BG_FIELD = { 0.07, 0.055, 0.04, 0.95 }
W.BORDER_FIELD = { 0.30, 0.24, 0.15 }

-- ---------------------------------------------------------------- one-line text + full-text tooltip
-- Everywhere a label may not fit its place: W.FitText(fs, text, width, owner) keeps it on one line
-- (BT.OneLine: cut with "...") and remembers the full string in fs.fullText while it is cut. Hovering
-- `owner` (the mouse-enabled frame the label belongs to) then shows the full string: under the owner's
-- own tooltip when it has one, else as a tooltip of its own. Returns true when the text was cut.

local function TooltipHas(text)
    local n = GameTooltip.NumLines and GameTooltip:NumLines() or 0
    for i = 1, n do
        local fs = _G["GameTooltipTextLeft" .. i]
        if fs and fs:GetText() == text then
            return true
        end
    end
    return false
end

-- Full strings of the cut labels of `owner` that are shown now.
function W.CutLines(owner)
    local out = {}
    for _, fs in ipairs(owner.cutFs or {}) do
        if fs.fullText and fs:IsShown() then
            out[#out + 1] = fs.fullText
        end
    end
    return out
end

local function CutEnter(self)
    local lines = W.CutLines(self)
    if #lines == 0 then
        return
    end
    if GameTooltip:IsShown() and GameTooltip:GetOwner() == self then
        -- the owner already shows a tooltip (a hint): add what it does not say yet
        local added = false
        for _, t in ipairs(lines) do
            if not TooltipHas(t) then
                GameTooltip:AddLine(t, 1, 1, 1, 1)
                added = true
            end
        end
        if added then
            GameTooltip:Show()
        end
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(lines[1], 1, 1, 1, 1, 1)
    for i = 2, #lines do
        GameTooltip:AddLine(lines[i], 1, 1, 1, 1)
    end
    GameTooltip:Show()
end

local function CutLeave(self)
    if GameTooltip:GetOwner() == self then
        GameTooltip:Hide()
    end
end

-- Registers label `fs` on `owner`: its OnEnter / OnLeave get the full-text tooltip (hooked after the
-- owner's own scripts, once per owner).
function W.CutTip(owner, fs)
    owner.cutFs = owner.cutFs or {}
    for _, f in ipairs(owner.cutFs) do
        if f == fs then
            return
        end
    end
    owner.cutFs[#owner.cutFs + 1] = fs
    if owner.cutHooked then
        return
    end
    owner.cutHooked = true
    if owner.EnableMouse and not owner.noMouseForTip then
        owner:EnableMouse(true)
    end
    if owner:GetScript("OnEnter") then
        owner:HookScript("OnEnter", CutEnter)
    else
        owner:SetScript("OnEnter", CutEnter)
    end
    if owner:GetScript("OnLeave") then
        owner:HookScript("OnLeave", CutLeave)
    else
        owner:SetScript("OnLeave", CutLeave)
    end
end

-- Mouse zone over a free-standing label (child of `parent`, covering the label) to own its tooltip.
function W.TextZone(parent, fs)
    local z = CreateFrame("Frame", nil, parent)
    z:SetAllPoints(fs)
    z:EnableMouse(true)
    return z
end

function W.FitText(fs, text, width, owner)
    text = text or ""
    local cut = BT.OneLine(fs, text, width)
    fs.fullText = cut and text or nil
    if owner then
        W.CutTip(owner, fs)
    end
    return cut
end

local function PickEnter(self)
    if self:IsEnabled() == 1 or self:IsEnabled() == true then
        self:SetBackdropBorderColor(W.GOLD[1], W.GOLD[2], W.GOLD[3])
    end
    if self.onEnter then
        self.onEnter(self)
        if GameTooltip:IsShown() and GameTooltip:GetOwner() == self then
            if self.text and self.text.fullText and not TooltipHas(self.text.fullText) then
                GameTooltip:AddLine(self.text.fullText, 1, 1, 1, 1)
                GameTooltip:Show()
            end
        elseif self.text and self.text.fullText then
            -- the handler showed nothing (e.g. a parameter field without a spell): the cut label
            -- still gets its full-text tooltip
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(self.text.fullText, 1, 1, 1, 1, 1)
            GameTooltip:Show()
        end
    elseif self.text and self.text.fullText then
        -- the field shows one line of it: the whole text as a tooltip (party-ui-audit T1 / W1)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(self.text.fullText, 1, 1, 1, 1, 1)
        GameTooltip:Show()
    elseif self.text and self.text:GetStringWidth() > self:GetWidth() - 20 then
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(self.text:GetText() or "", 1, 1, 1, 1, 1)
        GameTooltip:Show()
    end
end

local function PickLeave(self)
    local c = self.borderColor or W.BORDER_FIELD
    self:SetBackdropBorderColor(c[1], c[2], c[3])
    if self.onLeave then
        self.onLeave(self)
    else
        GameTooltip:Hide()
    end
end

-- Flat "field" button: optional icon, a text, optional caret; text truncates.
function W.Pick(parent, width, height, withIcon, withCaret)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(width)
    b:SetHeight(height or 22)
    W.Panel(b, W.BG_FIELD, W.BORDER_FIELD)
    local left = 6
    if withIcon then
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetWidth((height or 22) - 6)
        b.icon:SetHeight((height or 22) - 6)
        b.icon:SetPoint("LEFT", 3, 0)
        b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        left = (height or 22)
    end
    b.text = W.Text(b, "GameFontHighlightSmall", W.TEXT)
    b.text:SetPoint("LEFT", left, 0)
    b.text:SetPoint("RIGHT", withCaret and -14 or -4, 0)
    b.text:SetHeight(12)
    b.textPad = left + (withCaret and 14 or 4)
    if withCaret then
        b.caret = b:CreateTexture(nil, "OVERLAY")
        b.caret:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
        b.caret:SetWidth(14)
        b.caret:SetHeight(14)
        b.caret:SetPoint("RIGHT", -1, 0)
        b.caret:SetAlpha(0.6)
    end
    b:SetScript("OnEnter", PickEnter)
    b:SetScript("OnLeave", PickLeave)
    -- Clicking a field finishes number typing first (so the new value is kept, no Enter needed)
    b:SetScript("OnMouseDown", W.ReleaseNumber)
    return b
end

-- Text of a field, cut to its width (pad = the room taken by the icon / caret / other labels); the
-- full text is the field's tooltip when it was cut.
function W.SetPickText(b, text, pad)
    return W.FitText(b.text, text, b:GetWidth() - (pad or b.textPad or 10))
end

function W.SetPickBorder(b, c)
    b.borderColor = c
    local cc = c or W.BORDER_FIELD
    b:SetBackdropBorderColor(cc[1], cc[2], cc[3])
end

-- Small texture button (up/down/delete).
function W.IconButton(parent, size, up, down, highlight, tip)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(size)
    b:SetHeight(size)
    b:SetNormalTexture(up)
    if down then
        b:SetPushedTexture(down)
    end
    b:SetHighlightTexture(highlight or "Interface\\Buttons\\ButtonHilight-Square", "ADD")
    if tip then
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(tip, 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return b
end

function W.UpButton(parent, tip)
    return W.IconButton(parent, 18, "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up",
        "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Down", "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Highlight", tip)
end

function W.DownButton(parent, tip)
    return W.IconButton(parent, 18, "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up",
        "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Down", "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Highlight", tip)
end

function W.CloseSmall(parent, tip, size)
    return W.IconButton(parent, size or 16, "Interface\\Buttons\\UI-GroupLoot-Pass-Up",
        "Interface\\Buttons\\UI-GroupLoot-Pass-Down", "Interface\\Buttons\\UI-GroupLoot-Pass-Highlight", tip)
end

-- Text button in the "tab" style (flat, gold when selected).
function W.Tab(parent, height)
    local b = CreateFrame("Button", nil, parent)
    b.flat = true
    b:SetHeight(height or 22)
    W.Panel(b, { 0.13, 0.10, 0.07, 0.95 }, W.LINE)
    b.text = W.Text(b, "GameFontNormalSmall", W.MUTED, "CENTER")
    b.text:SetPoint("LEFT", 6, 0)
    b.text:SetPoint("RIGHT", -6, 0)
    b.text:SetHeight(12)
    b:SetScript("OnEnter", function(self)
        if not self.selected then
            self:SetBackdropBorderColor(W.GOLD_DIM[1], W.GOLD_DIM[2], W.GOLD_DIM[3])
        end
        -- a cut label shows its full text as the title, the hint (tip) under it
        local full = self.text.fullText
        if full or self.tip then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            if full then
                GameTooltip:SetText(full, 1, 0.82, 0, 1, 1)
                if self.tip and self.tip ~= full then
                    GameTooltip:AddLine(self.tip, 1, 1, 1, 1)
                end
            else
                GameTooltip:SetText(self.tip, 1, 1, 1, 1, 1)
            end
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(self)
        W.SetTabSelected(self, self.selected)
        GameTooltip:Hide()
    end)
    return b
end

function W.SetTabSelected(b, sel)
    b.selected = sel
    if sel then
        b:SetBackdropColor(0.23, 0.18, 0.11, 0.95)
        b:SetBackdropBorderColor(W.GOLD_DIM[1], W.GOLD_DIM[2], W.GOLD_DIM[3])
        W.Color(b.text, W.GOLD)
    else
        b:SetBackdropColor(0.13, 0.10, 0.07, 0.95)
        b:SetBackdropBorderColor(W.LINE[1], W.LINE[2], W.LINE[3])
        W.Color(b.text, W.MUTED)
    end
end

-- Width of a tab that fits its text.
-- A text wider than `max` is cut with "..."; hovering shows the full text (W.Tab's OnEnter, above
-- the tab's own tip) (party-ui-audit W2: the button was clipped, the text stuck out of it).
function W.FitTab(b, text, min, max)
    text = text or ""
    b.text.fullText = nil
    b.text:SetText(text)
    local w = b.text:GetStringWidth() + 16
    if min and w < min then
        w = min
    end
    if max and w > max then
        w = max
        W.FitText(b.text, text, max - 12)
    end
    b:SetWidth(w)
end

-- Label of a tab of a fixed width (cut with a full-text tooltip when it does not fit).
function W.SetTabText(b, text)
    W.FitText(b.text, text, b:GetWidth() - 12)
end

-- Round button (minimap button recipe): round icon made with SetPortraitToTexture.
function W.Round(parent, name)
    local b = CreateFrame("Button", name, parent)
    b:SetWidth(31)
    b:SetHeight(31)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    b.bg:SetWidth(20)
    b.bg:SetHeight(20)
    b.bg:SetPoint("TOPLEFT", 7, -5)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetWidth(20)
    b.icon:SetHeight(20)
    b.icon:SetPoint("TOPLEFT", 7, -5)
    b.border = b:CreateTexture(nil, "OVERLAY")
    b.border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    b.border:SetWidth(53)
    b.border:SetHeight(53)
    b.border:SetPoint("TOPLEFT")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")
    return b
end

function W.SetRoundIcon(b, path)
    if b.iconPath ~= path then
        b.iconPath = path
        SetPortraitToTexture(b.icon, path or BT.ICON_UNKNOWN)
    end
end

-- The number box that has the keyboard, so a click on any field can release it (WoW keeps the focus
-- in an edit box when you click other widgets).
W.focusedNumber = nil

function W.ReleaseNumber()
    if W.focusedNumber then
        W.focusedNumber:ClearFocus()
    end
end

-- Numeric field: styled like the other fields, spin arrows on the right, mouse wheel steps the value.
-- e.min / e.max / e.step (set by the owner) bound the arrows and the wheel; e.spin is the arrow column
-- (anchor things after the widget to it). Width includes the arrows.
local function Step(e, dir)
    local v = tonumber(e:GetText()) or e.min or 0
    local step = e.step or 1
    -- snap to the step grid first, then move
    if dir > 0 then
        v = math.floor(v / step) * step + step
    else
        v = math.ceil(v / step) * step - step
    end
    if e.min and v < e.min then v = e.min end
    if e.max and v > e.max then v = e.max end
    e:SetText(tostring(v))
    if e.onChange then e.onChange(e) end
    if e.onCommit and not e.focused then e.onCommit(e, false) end
end

function W.Number(parent, width)
    width = width or 46
    local e = CreateFrame("EditBox", nil, parent)
    e:SetWidth(width - 13)
    e:SetHeight(22)
    W.Panel(e, W.BG_FIELD, W.BORDER_FIELD)
    e:SetTextInsets(4, 5, 0, 0)
    e:SetAutoFocus(false)
    e:SetNumeric(true)
    e:SetMaxLetters(3)
    e:SetJustifyH("RIGHT")
    e:SetFontObject(GameFontHighlightSmall)
    e:SetTextColor(W.GOLD[1], W.GOLD[2], W.GOLD[3])
    e:EnableMouseWheel(true)
    e:SetScript("OnMouseWheel", function(self, delta)
        Step(self, delta)
    end)
    e:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(W.GOLD[1], W.GOLD[2], W.GOLD[3])
    end)
    e:SetScript("OnLeave", function(self)
        if not self.focused then
            self:SetBackdropBorderColor(W.BORDER_FIELD[1], W.BORDER_FIELD[2], W.BORDER_FIELD[3])
        end
    end)

    local spin = CreateFrame("Frame", nil, e)
    spin:SetWidth(12)
    spin:SetHeight(22)
    spin:SetPoint("LEFT", e, "RIGHT", 1, 0)
    e.spin = spin
    local up = W.IconButton(spin, 12, "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up",
        "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Down", "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Highlight")
    up:SetPoint("TOP", 0, 0)
    up:SetHeight(11)
    up:SetScript("OnClick", function() Step(e, 1) end)
    local down = W.IconButton(spin, 12, "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up",
        "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Down", "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Highlight")
    down:SetPoint("BOTTOM", 0, 0)
    down:SetHeight(11)
    down:SetScript("OnClick", function() Step(e, -1) end)

    e:SetScript("OnEditFocusGained", function(self)
        self.focused = true
        W.focusedNumber = self
        self:SetBackdropBorderColor(W.GOLD[1], W.GOLD[2], W.GOLD[3])
        self:HighlightText()
    end)
    e:SetScript("OnTabPressed", function(self)
        self:ClearFocus()
    end)
    e:SetScript("OnEscapePressed", function(self)
        self.cancel = true
        self:ClearFocus()
    end)
    e:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    -- Clicking another widget does not take the focus away in WoW, so values apply while typing
    e:SetScript("OnTextChanged", function(self)
        if self.focused and self.onChange then
            self.onChange(self)
        end
    end)
    e:SetScript("OnEditFocusLost", function(self)
        self.focused = false
        if W.focusedNumber == self then
            W.focusedNumber = nil
        end
        self:SetBackdropBorderColor(W.BORDER_FIELD[1], W.BORDER_FIELD[2], W.BORDER_FIELD[3])
        self:HighlightText(0, 0)
        local cancel = self.cancel
        self.cancel = nil
        if self.onCommit then
            self.onCommit(self, cancel)
        end
    end)
    return e
end

-- ---------------------------------------------------------------- spell id field (tactics-round2-spec 3)

-- Spell id from typed digits ("12345", "#12345") or a spell link ("|Hspell:12345|h[...]|h", also with the
-- doubled "||" a pasted link may carry). nil when there is none.
function W.SpellIdOf(text)
    if type(text) ~= "string" then
        return nil
    end
    local id = string.match(text, "Hspell:(%d+)") or string.match(text, "^%s*#?(%d+)%s*$")
    id = tonumber(id)
    if id and id > 0 and id < 10000000 then
        return id
    end
    return nil
end

-- Shift-click on a spell (spellbook, chat, combat log) while a spell id box has the keyboard: the link
-- goes into that box. Hooked once, after the original (which does nothing without an open chat box).
local spellLinkHooked
local function HookSpellLinks()
    if spellLinkHooked or type(hooksecurefunc) ~= "function" or type(ChatEdit_InsertLink) ~= "function" then
        return
    end
    spellLinkHooked = true
    hooksecurefunc("ChatEdit_InsertLink", function(link)
        local e = W.focusedNumber
        if e and e.focused and e.spellBox then
            local id = W.SpellIdOf(link)
            if id then
                e:SetText(tostring(id))
            end
        end
    end)
end

-- Text field for a spell id (condition param "spellid"): accepts digits and pasted / shift-clicked spell
-- links. e.onChange(e) while typing (focused), e.onCommit(e, cancel) when it loses the focus, e.onEnter(e)
-- on hover. Shares W.focusedNumber with the number boxes (a click on any field releases it).
function W.SpellIdBox(parent, width)
    HookSpellLinks()
    local e = CreateFrame("EditBox", nil, parent)
    e.spellBox = true
    e:SetWidth(width or 46)
    e:SetHeight(22)
    W.Panel(e, W.BG_FIELD, W.BORDER_FIELD)
    e:SetTextInsets(4, 4, 0, 0)
    e:SetAutoFocus(false)
    e:SetMaxLetters(255)
    e:SetJustifyH("RIGHT")
    e:SetFontObject(GameFontHighlightSmall)
    e:SetTextColor(W.GOLD[1], W.GOLD[2], W.GOLD[3])
    e:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(W.GOLD[1], W.GOLD[2], W.GOLD[3])
        if self.onEnter then
            self.onEnter(self)
        end
    end)
    e:SetScript("OnLeave", function(self)
        if not self.focused then
            self:SetBackdropBorderColor(W.BORDER_FIELD[1], W.BORDER_FIELD[2], W.BORDER_FIELD[3])
        end
        GameTooltip:Hide()
    end)
    e:SetScript("OnEditFocusGained", function(self)
        self.focused = true
        W.focusedNumber = self
        self:SetBackdropBorderColor(W.GOLD[1], W.GOLD[2], W.GOLD[3])
        self:HighlightText()
    end)
    e:SetScript("OnTabPressed", function(self)
        self:ClearFocus()
    end)
    e:SetScript("OnEscapePressed", function(self)
        self.cancel = true
        self:ClearFocus()
    end)
    e:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    e:SetScript("OnTextChanged", function(self)
        if self.focused and self.onChange then
            self.onChange(self)
        end
    end)
    e:SetScript("OnEditFocusLost", function(self)
        self.focused = false
        if W.focusedNumber == self then
            W.focusedNumber = nil
        end
        self:SetBackdropBorderColor(W.BORDER_FIELD[1], W.BORDER_FIELD[2], W.BORDER_FIELD[3])
        self:HighlightText(0, 0)
        local cancel = self.cancel
        self.cancel = nil
        if self.onCommit then
            self.onCommit(self, cancel)
        end
    end)
    return e
end

-- ---------------------------------------------------------------- party window helpers (6.2)

-- Inline caret for menu buttons (the mock's triangle glyph is not in the 3.3.5 fonts).
W.CARET = " |TInterface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up:14:14:0:-1|t"

-- Shared dropdown menu (EasyMenu); a second click on the same anchor closes it.
local menuFrame
local menuAnchor

function W.ShowMenu(anchor, items)
    if not menuFrame then
        menuFrame = CreateFrame("Frame", "BotTacticsMenu", UIParent, "UIDropDownMenuTemplate")
    end
    if DropDownList1 and DropDownList1:IsShown() and menuAnchor == anchor then
        CloseDropDownMenus()
        menuAnchor = nil
        return
    end
    CloseDropDownMenus()
    menuAnchor = anchor
    EasyMenu(items, menuFrame, anchor, 0, 0, "MENU")
end

-- Action button: a flat tab-styled button (the red UIPanelButtonTemplate was too heavy for the party
-- window, findings.md); width fits the text (at least minW, at most maxW, then cut with a tooltip).
function W.Button(parent, text, minW, height, maxW)
    local b = W.Tab(parent, height or 22)
    b.maxW = maxW or 220
    W.SetButtonText(b, text, minW)
    W.SetTabSelected(b, false)
    return b
end

function W.SetButtonText(b, text, minW)
    W.FitTab(b, text, minW or 40, b.maxW or 220)
end

-- On/off switch 34x18 (two textures: track and knob), as the mock's "sw".
function W.Switch(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(34)
    b:SetHeight(18)
    W.Panel(b, { 0.16, 0.14, 0.11, 1 }, W.LINE)
    b.knob = b:CreateTexture(nil, "OVERLAY")
    b.knob:SetWidth(12)
    b.knob:SetHeight(12)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    W.SetSwitch(b, false)
    return b
end

function W.SetSwitch(b, on)
    b.on = on and true or false
    b.knob:ClearAllPoints()
    if b.on then
        b:SetBackdropColor(0.12, 0.23, 0.13, 1)
        b:SetBackdropBorderColor(0.25, 0.48, 0.27, 1)
        b.knob:SetTexture(0.38, 0.82, 0.43, 1)
        b.knob:SetPoint("RIGHT", -3, 0)
    else
        b:SetBackdropColor(0.16, 0.14, 0.11, 1)
        b:SetBackdropBorderColor(W.LINE[1], W.LINE[2], W.LINE[3], 1)
        b.knob:SetTexture(0.42, 0.37, 0.31, 1)
        b.knob:SetPoint("LEFT", 3, 0)
    end
end

-- Titled card ("statbox" of the mock).
function W.Card(parent, title, width, height)
    local c = CreateFrame("Frame", nil, parent)
    c:SetWidth(width)
    c:SetHeight(height)
    W.Panel(c, { 0.07, 0.055, 0.04, 0.95 }, W.LINE)
    c.title = W.Text(c, "GameFontNormalSmall", W.GOLD_DIM)
    c.title:SetPoint("TOPLEFT", 10, -8)
    c.title:SetText(title or "")
    return c
end

function W.Enable(b, on)
    if on then
        b:Enable()
    else
        b:Disable()
    end
    if b.flat then
        -- a flat button has no disabled texture: dim it
        b:SetAlpha(on and 1 or 0.45)
    end
end

function W.Show(f, on)
    if on then
        f:Show()
    else
        f:Hide()
    end
end
