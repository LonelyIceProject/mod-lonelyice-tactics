-- AI intent position (ai-layer-spec 6): (a) a ranged bot / healer steps away from a hostile next to it that
-- is not attacking it, (b) a healer follows its tank when the tank leaves heal range, (c) a melee bot with
-- the "behind" toggle moves behind its target when the target is tanked by someone else and faces it.
-- At most one executed move per AI_POSITION_MIN_MS (state key pm). C++ checks every move against the
-- mechanics guard like any other move.

local config = wow.include("config.lua")
local profile = wow.include("profile.lua")

local I = { id = "position", level = config.AI_INTENT_LEVEL.position, category = "move" }

local CLOSE = 5          -- yards: a hostile this close to a ranged bot
local STEP = 10          -- yards away from that hostile
local CENTROID_PULL = 0.3
local DEFAULT_RANGE = 40

local function healRange(env)
    local e = env.kit.healDirect[1]
    local r = e and e.range or 0
    if r <= 0 then r = DEFAULT_RANGE end
    return r
end

function I.urgency(env, st)
    env._posMode = nil
    if st.pm then
        local dt = env.now - st.pm
        if dt >= 0 and dt < profile.cfg(env.profile, "POSITION_MIN_MS") then return 0 end
    end
    local p, bot = env.profile, env.bot
    if p.role == "tank" then return 0 end
    -- no step while casting: playerbots' MoveTo refuses then (the move would only fail and cost the slot)
    if (bot:casting() or 0) ~= 0 then return 0 end
    -- (b) healer too far from its tank
    if p.healer then
        local tank = env:tank()
        if tank and tank:guid() ~= env.guid then
            local d = bot:distance(tank)
            if d and d > healRange(env) - 5 then
                env._posMode, env._posUnit = "b", tank
                return 0.6
            end
        end
    end
    -- (a) ranged / healer with a hostile next to it that attacks someone else
    if p.healer or bot:isRanged() then
        local att = env:attackers()
        for i = 1, #att do
            local u = att[i]
            if u:isAlive() then
                local d = bot:distance(u)
                if d and d <= CLOSE then
                    local v = u:victim()
                    if not v or v:guid() ~= env.guid then
                        env._posMode, env._posUnit = "a", u
                        return 0.5
                    end
                end
            end
        end
    end
    -- (c) melee with "behind": in front of a target tanked by someone else
    if p.style.behind and bot:isMelee() then
        local t = bot:currentTarget()
        local v = t and t:victim()
        if v and v:guid() ~= env.guid then
            local tx, ty, _, o = t:position()
            local bx, by = bot:position()
            if tx and bx and o and (math.cos(o) * (bx - tx) + math.sin(o) * (by - ty)) > 0 then
                env._posMode, env._posUnit = "c", t
                return 0.4
            end
        end
    end
    return 0
end

local function centroid(env)
    local group = env:group()
    local sx, sy, n = 0, 0, 0
    for i = 1, #group do
        local m = group[i]
        if m:isAlive() and m:guid() ~= env.guid then
            local x, y = m:position()
            if x then sx, sy, n = sx + x, sy + y, n + 1 end
        end
    end
    if n == 0 then return nil end
    return sx / n, sy / n
end

function I.build(env, st)
    local bot, mode, u = env.bot, env._posMode, env._posUnit
    if not mode or not u or bot:isDead() or not u:valid() then return nil end
    if mode == "b" then
        return { verb = "follow", target = u:guid(), dist = math.max(5, healRange(env) - 8) }
    end
    local bx, by, bz = bot:position()
    local hx, hy = u:position()
    if not bx or not hx then return nil end
    if mode == "a" then
        local dx, dy = bx - hx, by - hy
        local len = math.sqrt(dx * dx + dy * dy)
        if len < 0.1 then return nil end
        local px, py = hx + dx / len * STEP, hy + dy / len * STEP
        local cx, cy = centroid(env)
        if cx then px, py = px + (cx - px) * CENTROID_PULL, py + (cy - py) * CENTROID_PULL end
        return { verb = "move", x = px, y = py, z = bz }
    end
    -- (c) behind the target, on the line from its victim through the target
    local v = u:victim()
    if not v then return nil end
    local vx, vy = v:position()
    if not vx then return nil end
    local dx, dy = hx - vx, hy - vy
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.1 then return nil end
    local px, py = hx + dx / len * config.BEHIND_DIST, hy + dy / len * config.BEHIND_DIST
    local ddx, ddy = bx - px, by - py
    if math.sqrt(ddx * ddx + ddy * ddy) <= config.BEHIND_TOLERANCE then return nil end
    return { verb = "move", x = px, y = py, z = bz }
end

return I
