-- Addon transport (spec 5.1). Frame = <flag><id><data>; flag F whole, B first, C middle, E last;
-- id = 2 chars [0-9A-Za-z]; data <= 240 bytes cut on UTF-8 boundaries. Client pacing: <= 10 frames/s.

local BT = BotTactics
local T = {}
BT.Transport = T

local MAX_DATA = 240
local FRAME_INTERVAL = 0.1        -- 10 frames per second
local BUFFER_TTL = 30             -- seconds
local BUFFER_MAX = 32768          -- bytes, server -> client
local ID_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

local nextId = 0
local queue, qHead, qTail = {}, 1, 0
local lastSend = 0
local buffers = {}                -- id -> { parts, size, at }

T.OnPayload = nil                 -- set by Protocol: function(payload)

local function NewId()
    local n = nextId
    nextId = (nextId + 1) % (62 * 62)
    local a = math.floor(n / 62) + 1
    local b = (n % 62) + 1
    return string.sub(ID_CHARS, a, a) .. string.sub(ID_CHARS, b, b)
end

-- Last byte index of a slice starting at pos with at most limit bytes that does not split a
-- UTF-8 character.
local function CutEnd(s, pos, limit)
    local last = pos + limit - 1
    local len = #s
    if last >= len then
        return len
    end
    while last > pos do
        local b = string.byte(s, last + 1)
        if b < 128 or b >= 192 then
            break
        end
        last = last - 1
    end
    return last
end
T.CutEnd = CutEnd

local pump = CreateFrame("Frame")
pump:Hide()
pump:SetScript("OnUpdate", function(self)
    if qHead > qTail then
        self:Hide()
        return
    end
    local now = GetTime()
    if now - lastSend < FRAME_INTERVAL then
        return
    end
    local frame = queue[qHead]
    queue[qHead] = nil
    qHead = qHead + 1
    lastSend = now
    if BT.debug then
        BT.Print(">> " .. string.sub(frame, 1, 120))
    end
    SendAddonMessage(BT.PREFIX, frame, "WHISPER", UnitName("player"))
end)

local function Enqueue(frame)
    qTail = qTail + 1
    queue[qTail] = frame
    pump:Show()
end

-- Splits a payload into frames and queues them. Returns false for bytes the protocol forbids.
function T.Send(payload)
    if string.find(payload, "[%z\n\r|]") then
        return false
    end
    local id = NewId()
    local len = #payload
    if len <= MAX_DATA then
        Enqueue("F" .. id .. payload)
        return true
    end
    local pos, first = 1, true
    while pos <= len do
        local e = CutEnd(payload, pos, MAX_DATA)
        local flag
        if first then
            flag = "B"
        elseif e >= len then
            flag = "E"
        else
            flag = "C"
        end
        Enqueue(flag .. id .. string.sub(payload, pos, e))
        first = false
        pos = e + 1
    end
    return true
end

function T.Pending()
    return qTail - qHead + 1
end

local function Deliver(payload)
    if T.OnPayload then
        T.OnPayload(payload)
    end
end

-- One received frame (CHAT_MSG_ADDON text without the prefix).
function T.OnFrame(msg)
    if BT.debug then
        BT.Print("<< " .. string.sub(msg, 1, 120))
    end
    local flag, id, data = string.sub(msg, 1, 1), string.sub(msg, 2, 3), string.sub(msg, 4)
    if #id ~= 2 then
        return
    end
    local now = GetTime()
    for k, b in pairs(buffers) do
        if now - b.at > BUFFER_TTL then
            buffers[k] = nil
        end
    end

    if flag == "F" then
        Deliver(data)
    elseif flag == "B" then
        buffers[id] = { parts = { data }, size = #data, at = now }
    elseif flag == "C" or flag == "E" then
        local b = buffers[id]
        if not b then
            return
        end
        b.size = b.size + #data
        if b.size > BUFFER_MAX then
            buffers[id] = nil
            return
        end
        b.parts[#b.parts + 1] = data
        if flag == "E" then
            buffers[id] = nil
            Deliver(table.concat(b.parts))
        end
    end
end
