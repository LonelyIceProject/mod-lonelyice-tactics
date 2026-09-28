-- Events, slash commands, key binding and the screen launcher button.

local BT = BotTactics
local L, W, P, T = BT.L, BT.W, BT.Protocol, BT.Transport

local DEFAULTS = { showFired = true, hideButton = false, lastTab = "tactics", bagMode = "use" }
-- Table defaults (party-window-spec 6.1), created per character on first load.
local TABLE_DEFAULTS = { "favorites", "talentTabs", "statSections" }

-- ---------------------------------------------------------------- launcher button (no minimap)

local launcher = W.Round(UIParent, "BotTacticsLauncher")
launcher:SetFrameStrata("MEDIUM")
launcher:SetMovable(true)
launcher:SetClampedToScreen(true)
launcher:RegisterForDrag("LeftButton")
launcher:RegisterForClicks("LeftButtonUp")
W.SetRoundIcon(launcher, BT.ICON_LAUNCHER)
launcher:Hide()

launcher:SetScript("OnClick", function()
    BT.Party.Toggle()
end)
launcher:SetScript("OnDragStart", function(self)
    self:StartMoving()
end)
launcher:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint(1)
    BotTacticsDB.button = { point, relPoint, x, y }
end)
launcher:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L.title, W.GOLD[1], W.GOLD[2], W.GOLD[3])
    GameTooltip:AddLine(L.launcherTip, 1, 1, 1, 1)
    GameTooltip:AddLine("/party  /tactics  /bt", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)
launcher:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

local function PlaceLauncher()
    launcher:ClearAllPoints()
    local p = BotTacticsDB.button
    if p then
        launcher:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    else
        launcher:SetPoint("TOPLEFT", PlayerFrame, "BOTTOMLEFT", 20, 8)
    end
    W.Show(launcher, not BotTacticsDB.hideButton)
end

-- ---------------------------------------------------------------- slash + binding

function BotTactics_Toggle()
    BT.Party.Toggle()
end

SLASH_BOTTACTICS1 = "/tactics"
SLASH_BOTTACTICS2 = "/bt"
-- party-window-spec 6.1. Note: the default UI treats "/party" as the party chat command before it
-- looks at addon slash commands, so this alias may never be reached (see open issues).
SLASH_BOTTACTICS3 = "/party"
SlashCmdList.BOTTACTICS = function(msg)
    msg = BT.Trim(string.lower(msg or ""))
    if msg == "button" then
        BotTacticsDB.hideButton = not BotTacticsDB.hideButton
        PlaceLauncher()
    elseif msg == "reset" then
        BotTacticsDB.pos = nil
        BotTacticsDB.button = nil
        BT.Party.RestorePosition()
        PlaceLauncher()
    elseif msg == "debug" then
        -- Prints every addon frame both ways; also re-sends HELLO so a fresh exchange shows up
        BT.debug = not BT.debug
        BT.Print("debug " .. (BT.debug and "on" or "off"))
        if BT.debug then
            P.Hello()
        end
    elseif msg == "help" or msg == "?" then
        BT.Print(L.slashHelp)
    else
        BT.Party.Toggle()
    end
end

-- ---------------------------------------------------------------- events

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PARTY_MEMBERS_CHANGED")
events:RegisterEvent("CHAT_MSG_ADDON")

events:SetScript("OnEvent", function(_, event, arg1, arg2, _, arg4)
    if event == "CHAT_MSG_ADDON" then
        if arg1 == BT.PREFIX and arg4 == UnitName("player") then
            T.OnFrame(arg2)
        end
    elseif event == "ADDON_LOADED" then
        if arg1 == "BotTactics" then
            BotTacticsDB = BotTacticsDB or {}
            for k, v in pairs(DEFAULTS) do
                if BotTacticsDB[k] == nil then
                    BotTacticsDB[k] = v
                end
            end
            for _, k in ipairs(TABLE_DEFAULTS) do
                if type(BotTacticsDB[k]) ~= "table" then
                    BotTacticsDB[k] = {}
                end
            end
            BT.Party.RestorePosition()
            PlaceLauncher()
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- The server may not accept addon traffic the instant the world loads
        BT.After("hello", 2, P.Hello)
    elseif event == "PARTY_MEMBERS_CHANGED" then
        BT.After("hello", 1, P.Hello)
    end
end)
