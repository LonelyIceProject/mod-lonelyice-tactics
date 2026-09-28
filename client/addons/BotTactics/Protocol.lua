-- Protocol messages (spec 5.3 / 5.4) and the client-side data model.

local BT = BotTactics
local L = BT.L
local P = {}
BT.Protocol = P

-- ---------------------------------------------------------------- data model
BT.party = {}      -- ordered array of bot entries (PARTY)
BT.bots = {}       -- low -> bot entry
BT.presets = {}    -- low -> { items = { [idx] = preset }, active, count, max, loaded, getPending, seen }
BT.books = {}      -- low -> { cats, spells, items, itemByEntry, at }
BT.status = {}     -- low -> { text, kind ("ok" | "busy" | "err") }
BT.gotParty = false
-- party window data (party-window-spec 4.2)
BT.acct = {}       -- BOTS entries in server order: { id (raw guid field), low, name, class, level, state }
BT.acctByLow = {}
BT.gotBots = false
BT.groupSet = { formation = "", rti = "" }   -- GROUPSET
BT.bags = {}       -- low -> BAGS snapshot (see H.BAGS)
BT.outfits = {}    -- low -> { { idx, name, items = { {slot, entry, guid}, ... } }, ... }

-- preset = { name, co = rules, nc = rules, dirty, seq, sentSeq, rejected, localNew, acceptNext }

local inflight = {}    -- low -> { op, idx, seq }
local pendingDel = {}  -- low -> idx
local lastWatch

-- Every data change goes through the editor callback, which forwards to BT.Party.OnData (6.2).
-- Extra arguments (ACK: op, ok, code, text) are passed on to the tab callbacks.
local function Changed(what, bot, ...)
    if BT.Editor and BT.Editor.OnData then
        BT.Editor.OnData(what, bot, ...)
    end
end
P.Changed = Changed

local function PartyStatus(bot, text, kind)
    if BT.Party and BT.Party.SetStatus and not BT.Party.stub then
        BT.Party.SetStatus(bot, text, kind)
    end
end

-- Rule-saving state of a bot (the Tactics tab's revert button reads it); shown in the window's one
-- status line like every other message (party-ui-audit 4.2).
local function SetStatus(bot, text, kind)
    BT.status[bot] = { text = text, kind = kind }
    PartyStatus(bot, text, kind)
    Changed("status", bot)
end
P.SetStatus = SetStatus

function BT.PresetsOf(bot)
    local pr = BT.presets[bot]
    if not pr then
        pr = { items = {}, max = 5 }
        BT.presets[bot] = pr
    end
    return pr
end

-- Active preset (falls back to the lowest index present) and its index.
function BT.ActivePreset(bot)
    local pr = BT.presets[bot]
    if not pr then
        return nil
    end
    local idx = pr.active
    if not idx or not pr.items[idx] then
        idx = nil
        for i = 1, 16 do
            if pr.items[i] then
                idx = i
                break
            end
        end
    end
    if not idx then
        return nil
    end
    return pr.items[idx], idx
end

-- Id of the bot's known rank of the spell chain that `id` belongs to (by name), or nil.
function BT.KnownRank(bot, id)
    local book = bot and BT.books[bot]
    local name = id and GetSpellInfo(id)
    return book and name and book.knownByName[name]
end

-- ---------------------------------------------------------------- sending

local function RawSend(payload)
    if not BT.Transport.Send(payload) then
        BT.Print("bad payload")
    end
end

-- One ITEM in flight per bot (party-window-spec 8): the others wait in a queue; no ACK within
-- ITEM_TIMEOUT drops it with "no answer"; "moving" is retried once after a second.
local ITEM_TIMEOUT = 5
local ITEM_QUEUE_MAX = 20
local itemQ = {}          -- bot -> { cur = job, list = { job, ... }, hold }
local lastOutfitOp = {}   -- bot -> op of the last OUTFIT sent (only "wear" shows its ACK text)

local ItemNext

local function ItemSend(bot, job)
    local q = itemQ[bot]
    q.cur = job
    RawSend(job.payload)
    BT.After("itemto" .. bot, ITEM_TIMEOUT, function()
        if q.cur == job then
            q.cur = nil
            PartyStatus(bot, L.noAnswer, "err")
            ItemNext(bot)
        end
    end)
end

ItemNext = function(bot)
    local q = itemQ[bot]
    if not q or q.cur or q.hold then
        return
    end
    local job = table.remove(q.list, 1)
    if job then
        ItemSend(bot, job)
    end
end

local function QueueItem(bot, payload)
    local q = itemQ[bot]
    if not q then
        q = { list = {} }
        itemQ[bot] = q
    end
    if #q.list >= ITEM_QUEUE_MAX then
        return
    end
    q.list[#q.list + 1] = { payload = payload }
    ItemNext(bot)
end

-- ACK of an ITEM: frees the slot, does the automatic follow-ups (stale -> INV, moving -> retry).
local function ItemAck(bot, ok, code)
    local q = itemQ[bot]
    local job = q and q.cur
    if q then
        q.cur = nil
        BT.Cancel("itemto" .. bot)
    end
    if not ok and code == "stale" then
        RawSend("INV\t" .. bot)
    elseif not ok and code == "moving" and job and not job.retried and q then
        job.retried = true
        table.insert(q.list, 1, job)
        q.hold = true
        BT.After("itemretry" .. bot, 1, function()
            q.hold = nil
            ItemNext(bot)
        end)
        return
    end
    ItemNext(bot)
end

local function Send(...)
    local payload = table.concat({ ... }, "\t")
    local kind, bot, op = ...
    if kind == "ITEM" and tonumber(bot) then
        QueueItem(tonumber(bot), payload)
        return
    elseif kind == "OUTFIT" and tonumber(bot) then
        lastOutfitOp[tonumber(bot)] = op
    end
    RawSend(payload)
end
-- Tab files send their messages with it (party-window-spec 1, P4): P.Send("INV", bot).
P.Send = Send

function P.RequestBots()
    Send("BOTS")
end

-- Command for one bot / every owned bot in the group (whitelisted by the server, 5.2).
function P.Cmd(bot, text)
    Send("CMD", bot, BT.Esc(text))
end

function P.CmdAll(text)
    Send("CMDALL", BT.Esc(text))
end

-- Command for the owned bots of one role scope (multibot-gap P4): all | tank | heal | dps | melee | ranged.
function P.CmdRole(scope, text)
    Send("CMDROLE", scope or "all", BT.Esc(text))
end

-- Pull card (multibot-gap P5): PULL <scope> wait <n> | PULL <scope> preset <id>; PULLSET = current settings.
function P.Pull(scope, mode, value)
    Send("PULL", scope or "all", mode, tostring(value))
end

function P.RequestPullSet()
    Send("PULLSET")
end

function P.Hello()
    Send("HELLO", BT.PROTO)
    lastWatch = nil
    P.UpdateWatch()
    BT.helloAt = GetTime()
end

function P.RequestParty()
    Send("PARTY")
end

function P.Get(bot)
    local pr = BT.PresetsOf(bot)
    pr.getPending = true
    pr.seen = {}
    Send("GET", bot)
end

function P.Book(bot)
    Send("BOOK", bot)
end

function P.Act(bot, idx)
    local pr = BT.PresetsOf(bot)
    pr.active = idx
    Send("ACT", bot, idx)
    Changed("presets", bot)
end

function P.Del(bot, idx)
    pendingDel[bot] = idx
    Send("DEL", bot, idx)
end

function P.Enable(bot, on)
    local b = BT.bots[bot]
    if b then
        b.enabled = on
    end
    Send("ENABLE", bot, on and "1" or "0")
end

-- WATCH 1 while the window is open or the "show fired rules" option is on.
function P.UpdateWatch(force)
    local want = (BotTacticsDB and BotTacticsDB.showFired) or (BotTacticsFrame and BotTacticsFrame:IsShown())
    want = want and true or false
    if force or want ~= lastWatch then
        lastWatch = want
        Send("WATCH", want and "1" or "0")
    end
end

-- Problem text of a rule list (nil when every rule is complete).
local function Incomplete(p)
    for _, list in ipairs({ p.co, p.nc }) do
        for i, r in ipairs(list) do
            if not r.a then
                return string.format(L.incompleteAction, i)
            end
            for _, c in ipairs(r.c) do
                local def = BT.cat.condById[c.id]
                if def and def.param == "spell" and not tonumber(c.v) then
                    return string.format(L.incompleteAura, i)
                end
                if def and def.param == "spellid" and not tonumber(c.v) then
                    return string.format(L.incompleteSpell or L.incompleteAura, i)
                end
            end
        end
    end
    return nil
end

-- Sends one PUT for the first dirty preset of the bot (one PUT in flight per bot).
function P.Save(bot)
    if inflight[bot] then
        return
    end
    local pr = BT.presets[bot]
    if not pr then
        return
    end
    for idx = 1, 16 do
        local p = pr.items[idx]
        if p and p.dirty and p.rejected ~= p.seq then
            local problem = Incomplete(p)
            if problem then
                SetStatus(bot, problem, "err")
            else
                inflight[bot] = { op = "PUT", idx = idx, seq = p.seq }
                p.sentSeq = p.seq
                Send("PUT", bot, idx, BT.Esc(p.name), BT.SerializeRules(p.co), BT.SerializeRules(p.nc))
                SetStatus(bot, L.saving, "busy")
                return
            end
        end
    end
end

-- Marks a preset changed and saves it after a short pause.
function P.Touch(bot, idx, now)
    local pr = BT.PresetsOf(bot)
    local p = pr.items[idx]
    if not p then
        return
    end
    p.dirty = true
    p.seq = (p.seq or 0) + 1
    BT.After("save" .. bot, now and 0 or 1.0, function() P.Save(bot) end)
    Changed("rules", bot)
end

function P.AnyDirty(bot)
    local pr = BT.presets[bot]
    if not pr then
        return false
    end
    for _, p in pairs(pr.items) do
        if p.dirty then
            return true
        end
    end
    return false
end

-- Drops local edits and reloads from the server.
function P.Revert(bot)
    local pr = BT.PresetsOf(bot)
    BT.Cancel("save" .. bot)
    inflight[bot] = nil
    pr.items = {}
    pr.loaded = false
    BT.status[bot] = nil
    P.Get(bot)
    Changed("presets", bot)
end

-- ---------------------------------------------------------------- receiving

local H = {}

-- Handler table for the tab files: BT.Protocol.Handlers.X = fn(fields). Assigning a type that already
-- has a handler chains the new one after the old one, so two files can listen to the same message
-- (for example BAGS in Bags.lua and Gear.lua) without replacing each other.
P.Handlers = setmetatable({}, {
    __index = H,
    __newindex = function(_, k, fn)
        local old = rawget(H, k)
        if old and fn and old ~= fn then
            rawset(H, k, function(f)
                old(f)
                fn(f)
            end)
        else
            rawset(H, k, fn)
        end
    end,
})

local function Fields(e)
    return BT.Split(e, ",")
end

local function FlagSet(s)
    local set = {}
    for c in string.gmatch(s or "", ".") do
        set[c] = true
    end
    return set
end
BT.FlagSet = FlagSet

H.CAT = function(f)
    local cat = { targets = {}, conds = {}, specials = {}, itemcats = {}, dispels = {} }
    for _, e in ipairs(BT.List(f[3])) do
        local s = Fields(e)
        cat.targets[#cat.targets + 1] = { id = s[1], side = s[2], lvl = tonumber(s[3]) or 0, label = BT.Unesc(s[4]) }
    end
    for _, e in ipairs(BT.List(f[4])) do
        local s = Fields(e)
        cat.conds[#cat.conds + 1] = {
            id = s[1], param = (s[2] ~= "" and s[2]) or "none", lvl = tonumber(s[3]) or 0,
            label = BT.Unesc(s[4]), prefix = BT.Unesc(s[5]), unit = BT.Unesc(s[6]),
            default = (s[7] ~= nil and s[7] ~= "") and s[7] or nil,
            min = tonumber(s[8]), max = tonumber(s[9]),
            enum = (s[10] ~= nil and s[10] ~= "") and s[10] or nil,
        }
    end
    -- Option lists of "enum" conditions: "list,id,label" entries
    cat.enums = {}
    for _, e in ipairs(BT.List(f[8])) do
        local s = Fields(e)
        if s[1] and s[2] then
            local opts = cat.enums[s[1]] or {}
            cat.enums[s[1]] = opts
            opts[#opts + 1] = { id = s[2], label = BT.Unesc(s[3]) }
        end
    end
    for _, e in ipairs(BT.List(f[5])) do
        local s = Fields(e)
        cat.specials[#cat.specials + 1] = { id = s[1], side = s[2], label = BT.Unesc(s[3]), desc = BT.Unesc(s[4]) }
    end
    for _, e in ipairs(BT.List(f[6])) do
        local s = Fields(e)
        cat.itemcats[#cat.itemcats + 1] = { id = s[1], label = BT.Unesc(s[2]) }
    end
    for _, e in ipairs(BT.List(f[7])) do
        local s = Fields(e)
        cat.dispels[#cat.dispels + 1] = { id = s[1], label = BT.Unesc(s[2]) }
    end
    if #cat.targets == 0 or #cat.conds == 0 then
        return
    end
    BT.SetCatalog(cat, true)
    Changed("catalog")
end

H.PARTY = function(f)
    local party, bots = {}, {}
    for _, e in ipairs(BT.List(f[2])) do
        local s = Fields(e)
        local low = tonumber(s[1])
        if low then
            local unlock = {}
            for i, v in ipairs(BT.Split(s[9] or "", ":")) do
                unlock[i] = tonumber(v) or 0
            end
            -- role, hp, alive: party-window-spec 4.2 (absent from an older server: defaults)
            local b = {
                low = low, name = BT.Unesc(s[2]), level = tonumber(s[3]) or 1, class = s[4],
                enabled = s[5] ~= "0", active = tonumber(s[6]) or 1, slots = tonumber(s[7]) or 3,
                cond2lvl = tonumber(s[8]) or 60, unlock = unlock,
                role = s[10] or "", hp = tonumber(s[11]), alive = s[12] ~= "0",
            }
            party[#party + 1] = b
            bots[low] = b
            local pr = BT.PresetsOf(low)
            if not pr.active then
                pr.active = b.active
            end
        end
    end
    BT.party, BT.bots = party, bots
    BT.gotParty = true
    Changed("party")
end

H.PRESET = function(f)
    local bot, idx = tonumber(f[2]), tonumber(f[3])
    if not bot or not idx then
        return
    end
    local pr = BT.PresetsOf(bot)
    if pr.seen then
        pr.seen[idx] = true
    end
    local p = pr.items[idx]
    if p and p.dirty and not p.acceptNext then
        return          -- newer local edits win; they are saved next
    end
    local np = { name = BT.Unesc(f[4]), co = BT.ParseRules(f[5]), nc = BT.ParseRules(f[6]), seq = p and p.seq or 0 }
    pr.items[idx] = np
    Changed("rules", bot)
end

H.PRESETS = function(f)
    local bot = tonumber(f[2])
    if not bot then
        return
    end
    local pr = BT.PresetsOf(bot)
    pr.active = tonumber(f[3]) or pr.active
    pr.count = tonumber(f[4])
    pr.max = tonumber(f[5]) or pr.max or 5
    if pr.getPending then
        for idx, p in pairs(pr.items) do
            if not pr.seen[idx] and not (p.dirty and p.localNew) then
                pr.items[idx] = nil
            end
        end
        pr.getPending = nil
        pr.seen = nil
    end
    pr.loaded = true
    local b = BT.bots[bot]
    if b and pr.active then
        b.active = pr.active
    end
    Changed("presets", bot)
end

H.BOOK = function(f)
    local bot = tonumber(f[2])
    if not bot then
        return
    end
    local book = { cats = {}, spells = {}, items = {}, itemByEntry = {}, at = GetTime() }
    for _, e in ipairs(BT.List(f[3])) do
        local s = Fields(e)
        local id = tonumber(s[1])
        if id then
            book.cats[#book.cats + 1] = { id = id, label = BT.Unesc(s[2]) }
        end
    end
    for _, e in ipairs(BT.List(f[4])) do
        local s = Fields(e)
        local id = tonumber(s[1])
        if id then
            local flags = s[4] or ""
            book.spells[#book.spells + 1] = {
                id = id, skill = tonumber(s[2]) or 0, level = tonumber(s[3]) or 0,
                known = string.find(flags, "k", 1, true) ~= nil,
                talent = string.find(flags, "t", 1, true) ~= nil,
            }
        end
    end
    for _, e in ipairs(BT.List(f[5])) do
        local s = Fields(e)
        local entry = tonumber(s[1])
        if entry then
            local it = { entry = entry, count = tonumber(s[2]) or 0, cat = s[3], name = BT.Unesc(s[4]) }
            book.items[#book.items + 1] = it
            book.itemByEntry[entry] = it
        end
    end
    book.knownByName = {}
    for _, s in ipairs(book.spells) do
        if s.known then
            local name = GetSpellInfo(s.id)
            if name then
                book.knownByName[name] = s.id
            end
        end
    end
    BT.books[bot] = book
    Changed("book", bot)
end

-- Ops of the tactics editor (TS 5.4); every other op is a party window op (party-window-spec 8).
local EDITOR_OPS = { PUT = true, DEL = true, GET = true, ACT = true, ENABLE = true, BOOK = true, PARTY = true, HELLO = true, WATCH = true }
-- Ops whose ACK ok text is worth showing.
local OK_TEXT_OPS = { SELLGREY = true, TRAIN = true, CMDALL = true, CMDROLE = true, PULL = true }

local function PartyAck(bot, op, ok, code, text)
    if op == "ITEM" then
        ItemAck(bot, ok, code)
    end
    if not ok then
        PartyStatus(bot, text, "err")
    elseif OK_TEXT_OPS[op] or (op == "OUTFIT" and lastOutfitOp[bot] == "wear") then
        PartyStatus(bot, text, "ok")
    elseif code == "pending" then
        PartyStatus(bot, text, "busy")
    end
    if (op == "LOGIN" or op == "LOGOUT") and ok then
        -- login is asynchronous: poll the list twice
        BT.After("botspoll2", 2, P.RequestBots)
        BT.After("botspoll6", 6, P.RequestBots)
    end
end

H.ACK = function(f)
    local bot, op, res, code, text = BT.ParseLow(f[2]), f[3], f[4], f[5], BT.Unesc(f[6])
    if not bot then
        return
    end
    local ok = res == "ok"
    if text == "" then
        text = code or ""
    end
    if not EDITOR_OPS[op] then
        PartyAck(bot, op, ok, code, text)
        Changed("ack", bot, op, ok, code, text)
        return
    end
    local pr = BT.PresetsOf(bot)

    if op == "GET" and not ok then
        -- a rejected GET must not leave the prune-on-PRESETS state armed
        pr.getPending = nil
        pr.seen = nil
    end

    if op == "PUT" then
        local inf = inflight[bot]
        inflight[bot] = nil
        local p = inf and pr.items[inf.idx]
        if p then
            if ok then
                p.rejected = nil
                if p.seq == inf.seq then
                    p.dirty = false
                    p.acceptNext = true     -- the normalized PRESET that follows replaces it
                end
                if p.localNew then
                    p.localNew = nil
                    if pr.active == inf.idx then
                        Send("ACT", bot, inf.idx)
                    end
                end
            else
                p.rejected = inf.seq
            end
        end
        if ok then
            SetStatus(bot, L.saved, "ok")
        else
            SetStatus(bot, string.format(L.notSaved, text), "err")
        end
        P.Save(bot)
    elseif op == "DEL" then
        local idx = pendingDel[bot]
        pendingDel[bot] = nil
        if ok and idx then
            pr.items[idx] = nil
            SetStatus(bot, L.saved, "ok")
        elseif not ok then
            SetStatus(bot, string.format(L.error, text), "err")
        end
    elseif not ok then
        SetStatus(bot, string.format(L.error, text), "err")
    end
    Changed("ack", bot, op, ok, code, text)
end

-- ---------------------------------------------------------------- party window messages (4.2)

-- BOTS <entries>: guid,nameEsc,class,level,state (0 offline, 1 online mine, 2 in use, 3 in my group)
H.BOTS = function(f)
    local list, byLow = {}, {}
    for _, e in ipairs(BT.List(f[2])) do
        local s = Fields(e)
        local low = BT.ParseLow(s[1])
        if low and not byLow[low] then
            local b = {
                id = s[1], low = low, name = BT.Unesc(s[2]), class = s[3],
                level = tonumber(s[4]) or 1, state = tonumber(s[5]) or 0,
            }
            list[#list + 1] = b
            byLow[low] = b
        end
    end
    BT.acct, BT.acctByLow = list, byLow
    BT.gotBots = true
    Changed("bots")
end

H.GROUPSET = function(f)
    BT.groupSet = { formation = f[2] or "", rti = f[3] or "" }
    Changed("groupset")
end

-- PULLSET <scope> <preset> <wait> <presets> <scopes> (multibot-gap P5): the stored pull settings (empty =
-- never set), presets = id,labelEsc,hintEsc,wait; scopes = id,labelEsc (labels of the "To whom" dropdown).
H.PULLSET = function(f)
    local ps = {
        scope = f[2] or "", preset = f[3] or "", wait = tonumber(f[4]),
        presets = {}, scopes = {}, scopeLabel = {},
    }
    for _, e in ipairs(BT.List(f[5])) do
        local s = Fields(e)
        if s[1] and s[1] ~= "" then
            ps.presets[#ps.presets + 1] = { id = s[1], label = BT.Unesc(s[2]), hint = BT.Unesc(s[3]), wait = tonumber(s[4]) }
        end
    end
    for _, e in ipairs(BT.List(f[6])) do
        local s = Fields(e)
        if s[1] and s[1] ~= "" then
            ps.scopes[#ps.scopes + 1] = { id = s[1], label = BT.Unesc(s[2]) }
            ps.scopeLabel[s[1]] = BT.Unesc(s[2])
        end
    end
    BT.pullSet = ps
    Changed("pullset")
end

-- BAGS <bot> <money> <flags> <containers> <items> (party-window-spec 4.2). Positions: bag 255 for
-- equipment/backpack/keyring/bank main slots, the bag slot (19..22, 67..73) for bag contents.
-- The item guid field is kept as sent and echoed back verbatim in ITEM.
H.BAGS = function(f)
    local bot = tonumber(f[2])
    if not bot then
        return
    end
    local b = BT.bots[bot]
    local level = b and b.level or nil
    local bags = {
        money = tonumber(f[3]) or 0, flags = f[4] or "", containers = {}, items = {}, byPos = {}, at = GetTime(),
    }
    bags.flag = FlagSet(bags.flags)
    for _, e in ipairs(BT.List(f[5])) do
        local s = Fields(e)
        bags.containers[#bags.containers + 1] = {
            kind = s[1] or "", bag = tonumber(s[2]) or 0, start = tonumber(s[3]) or 0,
            size = tonumber(s[4]) or 0, entry = tonumber(s[5]) or 0,
        }
    end
    for _, e in ipairs(BT.List(f[6])) do
        local s = Fields(e)
        local entry = tonumber(s[4])
        if entry then
            local row = {
                bag = tonumber(s[1]) or 0, slot = tonumber(s[2]) or 0, guid = s[3] or "", entry = entry,
                count = tonumber(s[5]) or 1, ench = tonumber(s[6]) or 0,
                gem1 = tonumber(s[7]) or 0, gem2 = tonumber(s[8]) or 0, gem3 = tonumber(s[9]) or 0,
                rprop = tonumber(s[10]) or 0, suffix = tonumber(s[11]) or 0,
                dur = tonumber(s[12]) or 0, maxdur = tonumber(s[13]) or 0,
                flags = s[14] or "", fits = {}, level = level,
            }
            row.flag = FlagSet(row.flags)
            for _, v in ipairs(BT.List(s[15], ":")) do
                local n = tonumber(v)
                if n then
                    row.fits[#row.fits + 1] = n
                end
            end
            bags.items[#bags.items + 1] = row
            bags.byPos[row.bag .. ":" .. row.slot] = row
        end
    end
    BT.bags[bot] = bags
    Changed("bags", bot)
end

-- OUTFITS <bot> <entries>: idx,nameEsc,items (items = slot.entry.guid joined by ":")
H.OUTFITS = function(f)
    local bot = tonumber(f[2])
    if not bot then
        return
    end
    local list = {}
    for _, e in ipairs(BT.List(f[3])) do
        local s = Fields(e)
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
    BT.outfits[bot] = list
    Changed("outfits", bot)
end

H.FIRED = function(f)
    local bot, list, slot = tonumber(f[2]), f[3], tonumber(f[4])
    if bot and slot and BT.Feedback then
        BT.Feedback.OnFired(bot, list, slot, f[5])
    end
end

H.ERR = function(f)
    local text = BT.Unesc(f[2])
    BT.Print(text)
    BT.lastError = text
    Changed("error")
end

-- The normalized PRESET of a PUT comes before PRESETS; after that the flag must not stay on.
local function ClearAccept(bot)
    local pr = bot and BT.presets[bot]
    if pr then
        for _, p in pairs(pr.items) do
            p.acceptNext = nil
        end
    end
end

function P.OnPayload(payload)
    local f = BT.Split(payload, "\t")
    local h = H[f[1]]
    if h then
        h(f)
        if f[1] == "PRESETS" then
            ClearAccept(tonumber(f[2]))
        end
    end
end

BT.Transport.OnPayload = P.OnPayload
