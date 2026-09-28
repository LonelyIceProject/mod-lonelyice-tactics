-- Bot tactics: small helpers shared by all modules (no game logic here).

local util = {}

-- Bit operations: LuaJIT "bit" (opened by the host), with bit32 / pure-Lua fallbacks.
local bitlib = rawget(_G, "bit") or rawget(_G, "bit32")
if bitlib then
    util.band = bitlib.band
else
    util.band = function(a, b)
        local r, p = 0, 1
        a = a % 4294967296
        b = b % 4294967296
        while a > 0 and b > 0 do
            local ra, rb = a % 2, b % 2
            if ra == 1 and rb == 1 then r = r + p end
            a = (a - ra) / 2
            b = (b - rb) / 2
            p = p * 2
        end
        return r
    end
end

-- true when bit n (0-based) is set in mask
function util.hasBit(mask, n)
    return util.band(mask or 0, 2 ^ n) ~= 0
end

-- Payload text escaping (spec 5.2): % TAB LF CR ; , = : | -> %XX
local ESC_PATTERN = "[%%\t\n\r;,=:|]"
local function escByte(c) return string.format("%%%02X", c:byte()) end

function util.esc(s)
    if s == nil then return "" end
    return (tostring(s):gsub(ESC_PATTERN, escByte))
end

function util.unesc(s)
    if s == nil then return "" end
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- Split keeping empty fields: split("a\t\tb", "\t") -> {"a", "", "b"}. sep is plain text.
function util.split(s, sep)
    local out = {}
    if s == nil then return out end
    local pos = 1
    while true do
        local a, b = string.find(s, sep, pos, true)
        if not a then
            out[#out + 1] = string.sub(s, pos)
            break
        end
        out[#out + 1] = string.sub(s, pos, a - 1)
        pos = b + 1
    end
    return out
end

-- Number of UTF-8 characters (counts non-continuation bytes).
function util.utf8len(s)
    local n = 0
    for i = 1, #s do
        local c = s:byte(i)
        if c < 0x80 or c >= 0xC0 then n = n + 1 end
    end
    return n
end

-- Strict decimal integer parse ("-" allowed), nil otherwise.
function util.toint(s)
    if type(s) == "number" then
        if s == math.floor(s) then return s end
        return nil
    end
    if type(s) ~= "string" or not s:match("^%-?%d+$") or #s > 12 then return nil end
    return tonumber(s)
end

-- Unsigned id (> 0) parse, nil otherwise.
function util.toid(s)
    local n = util.toint(s)
    if n and n > 0 then return n end
    return nil
end

-- "ru" for ruRU, else "en".
function util.lang(locale)
    if locale == "ruRU" then return "ru" end
    return "en"
end

-- Pick a localized string from {en=..., ru=...}.
function util.L(t, lang)
    if type(t) ~= "table" then return t or "" end
    return t[lang] or t.en or ""
end

-- Handles are compared by GUID text (works across Unit / Bot handle types).
function util.same(a, b)
    if a == nil or b == nil then return false end
    return a:guid() == b:guid()
end

function util.copy(list)
    local t = {}
    for i = 1, #list do t[i] = list[i] end
    return t
end

function util.set(list)
    local t = {}
    for i = 1, #list do t[list[i]] = true end
    return t
end

-- Filter an array by predicate.
function util.filter(list, pred)
    local t = {}
    for i = 1, #list do
        if pred(list[i]) then t[#t + 1] = list[i] end
    end
    return t
end

-- Stable sort by numeric key (lower first); nil keys sort last. table.sort is not stable.
function util.sortBy(list, keyFn)
    local keyed = {}
    for i = 1, #list do
        local k = keyFn(list[i])
        keyed[i] = { v = list[i], k = k or math.huge, i = i }
    end
    table.sort(keyed, function(a, b)
        if a.k ~= b.k then return a.k < b.k end
        return a.i < b.i
    end)
    for i = 1, #keyed do list[i] = keyed[i].v end
    return list
end

return util
