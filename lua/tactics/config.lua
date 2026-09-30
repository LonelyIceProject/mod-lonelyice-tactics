-- Bot tactics: tunable constants (progression, protocol, rate limits).
-- Everything here is policy: change it, then run ".tactics reload" in the worldserver console.

local config = {}

-- Protocol ----------------------------------------------------------------------------------------
config.PROTO = "1"                -- HELLO\t<proto> the addon must send
config.CAT_VERSION = "1"          -- first field of the CAT message

-- Rule slots (spec 4.4): no level gates, every slot and the second condition are always available ---
config.SLOT_MAX = 11              -- rule slots per list
config.COND2_LEVEL = 0            -- level of the second condition per rule (still sent in PARTY)
config.MAX_PRESETS = 5            -- named rule sets per bot (store keys p1..pN)
config.PRESET_NAME_MAX = 24       -- UTF-8 characters

-- Interpreter -------------------------------------------------------------------------------------
config.MAX_CANDIDATES = 3         -- decisions returned per tick (C++ reads at most Tactics.MaxCandidates)
config.NEAR_RADIUS = 8            -- yards, "enemies nearby" condition
config.BEHIND_DIST = 3.5          -- yards behind the tank
config.BEHIND_TOLERANCE = 2       -- skip "behind" when already this close to the spot
config.FOLLOW_SKIP_DIST = 5       -- skip "follow" when already this close to the leader

-- Fired-rule notifications (spec 5.4) -------------------------------------------------------------
config.FIRED_SAME_SLOT_MS = 1500  -- per bot: repeat of the same (list, slot) at most this often
config.FIRED_OWNER_WINDOW_MS = 1000
config.FIRED_OWNER_MAX = 4        -- per owner: at most N FIRED messages per window

-- Party window (party-window-spec 5.1) --------------------------------------------------------
config.ORDER_SLOT = 99            -- decision slot of a one-shot order (never a rule number)
config.ORDER_TTL_MS = 12000       -- an order not executed within this time expires
config.VETO_MAX = 40              -- per-spell rules per bot
config.VETO_REFRESH_MS = 10000    -- re-push the veto set to C++ at least this often (runtime is not persistent)
config.OUTFITS_MAX = 8            -- saved outfits per bot (idx 1..N)
config.OUTFIT_NAME_MAX = 24       -- UTF-8 characters
config.BOTS_CACHE_MS = 3000       -- BOTS: account query at most once per N ms per player
config.TRACE_MAX = 24             -- TRACE entries sent
config.CMD_MAX = 200              -- bytes of one bot chat command
config.LOOT_LIST_MAX = 60         -- always-loot entries per bot
config.BAGS_MAX_BYTES = 30000     -- BAGS payload cap (truncated at whole rows, flag "T")

-- Party window extras (party-extras-spec 5.1) ----------------------------------------------------
config.LIST_MAX_BYTES = 30000     -- cap of REPS / SKILLS / GLYPHS / VENDOR / BUYBACK payloads (whole rows, flag "T")
config.QDONE_PAGE = 50            -- completed quests per QDONE page
config.BUY_MAX_COUNT = 20         -- stacks per BUY
config.PREMADE_MAX_ENTRIES = 512  -- entries of one premade spec merged by talents.premadeBuild

-- AI layer on top of the rules (ai-layer-spec 12) ----------------------------------------------
config.AI_SLOT = 98               -- decision slot of the free layer (never a rule number; 99 = order)
config.AI_DEFAULT = 2             -- slider when the store has no "ai" key
config.AI_LVL_PARTNER = 0         -- slider 2 available from this level (no gate)
config.AI_LVL_OWN = 0             -- slider 3 (no gate)
config.AI_THRESHOLD = { [1] = 0.60, [2] = 0.40, [3] = 0.25 }
config.AI_DELAY_MS = { [1] = 600, [2] = 400, [3] = 200 }
config.AI_HYST = 15               -- hysteresis points above the engage threshold
config.AI_ARMED_URGENCY = 0.45    -- urgency of an hp intent inside the hysteresis band (above watch, still armed)
config.AI_COMMIT_MS = 3000        -- commitment window (x1.25)
config.AI_FAIL_BACKOFF_MS = 8000  -- a spell / item whose AI execution failed is not picked again for this long
config.AI_COMMIT_BONUS = 1.25
config.AI_RULE_SHADOW_MS = 4000   -- no AI action of a category this soon after a rule of that category
config.AI_FOCUS_MIN_MS = 6000     -- focus_target switches at most this often
config.AI_POSITION_MIN_MS = 3000
config.AI_RESERVE_TRASH = 35      -- mana reserve %
config.AI_RESERVE_BOSS = 15
config.AI_TREND_MS = 500          -- trend sample period
config.AI_TREND_DROP = 15         -- avg group hp drop over 3 s = "fight goes badly"
config.AI_TREND_SPAN_MS = 2500    -- minimum time between the oldest and newest trend sample
config.AI_TREND_SAMPLES = 6
config.AI_AOE_AUTO_MS = 10000     -- slider 3 auto aoe toggle period
config.AI_TRACE_MAX = 12          -- Lua AI trace ring entries
config.AI_KIT_TTL_MS = 10000
config.AI_SCAN_RANGE = 40         -- yards: dispel / heal_priority consider group members this close only
config.AI_DISPEL_SCAN_MAX = 10    -- dispel reads auras() of at most this many members per tick (raids)
config.AI_PROFILE_STYLE_MS = 5000
-- Level gates of the AI layer: all 0 (every intent and feature at every level)
config.AI_INTENT_LEVEL = { preserve_self = 0, interrupt = 0, dispel = 0, focus_target = 0, heal_priority = 0,
                           position = 0, cooldown_burst = 0, mana_economy = 0 }
config.AI_TREND_LEVEL = 0         -- group hp trend and ai-3 foresight
config.AI_AOE_LEVEL = 0           -- slider 3 auto aoe
config.AI_WATCH = { tank = 60, ally = 45, self = 35 }   -- default observation thresholds (profile 3.2)
config.AI_WATCH_FORESIGHT = 15    -- ai 3, level >= AI_TREND_LEVEL: watch thresholds this much higher (cap 85)
config.AI_WATCH_CAP = 85

-- Mana economy intent (tactics-round2-spec 1.5); mana percentages of the bot
config.AI_MANA_POT_PCT = 25       -- mana potion / mana gem below this
config.AI_MANA_CD_PCT = 50        -- own mana cooldown (Shadowfiend, Divine Plea, Mana Tide...) below this
config.AI_MANA_OOM_PCT = 15       -- "out of mana" callout (once per fight)
config.AI_RANKDOWN_PCT = 60       -- healers cast lower heal ranks on safe targets below this
config.AI_DRINK_PCT = 55          -- drink between pulls below this
config.AI_DRINK_MIN_MS = 25000    -- at most one drink command per this long

-- Party coordination: human-like callouts and claims (tactics-round2-spec 2.6). Index = effective slider.
config.AI_COORD_HEAR_MS = { [2] = 1200, [3] = 700 }    -- a spoken claim is heard this late
config.AI_COORD_MISS_PCT = { [2] = 25, [3] = 10 }      -- ... and missed this often (unspoken: double)
config.AI_COORD_SAY_PCT = { [2] = 50, [3] = 70 }       -- claims said aloud (the rest is only "seen")
config.AI_COORD_DEFER = { [2] = 0.35, [3] = 0.25 }     -- urgency factor of a job someone else took
config.AI_COORD_SEE_RANGE = 20    -- yards: an unspoken claim is seen by bots this close to the claimer
config.AI_COORD_SEE_MS = 900
config.AI_COORD_YOUNG_MS = 0      -- extra latency below level 40 (off: every level is equal)
config.AI_COORD_CLAIM_MS = 2500
config.AI_COORD_FLAG_MS = 8000
config.AI_SAY_MIN_MS = 8000       -- per bot: gap between two callouts
config.AI_SAY_FIGHT_MAX = 0       -- per bot and fight; 0 = no limit
config.AI_SAY_REPEAT_MS = 15000   -- the same callout id
config.AI_SAY_PARTY_MAX = 3       -- per party and 10 s window
config.AI_SAY_MAX_BYTES = 120

-- Debug: 1 = wow.log every evaluate result (very noisy)
config.DEBUG = false

-- Slots available at a level (every level has all of them).
function config.slots(level)
    return config.SLOT_MAX
end

-- Level at which slot k (1-based) unlocks.
function config.slotUnlock(k)
    return 0
end

-- "0:0:0:10:20:..." for the PARTY message.
function config.unlockList()
    local t = {}
    for k = 1, config.SLOT_MAX do t[k] = tostring(config.slotUnlock(k)) end
    return table.concat(t, ":")
end

return config
