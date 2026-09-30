# Bot tactics - Lua scripts

These scripts define all the behaviour of the party-bot gambits: the interpreter, targets, conditions,
actions, level progression, rule validation, the addon protocol and the spell list for the action picker.
C++ only runs them, gives them game facts through the `wow` API and carries out the primitive commands
(`cast`, `use`, `attack`, `move`, `follow`, `stop`, `wait`). The binding spec is
bot-tactics-spec, and the `wow` / `Unit` / `Bot` API is listed in its section 3.4.

## Files

| file | what it does |
|---|---|
| `init.lua` | Entry point. Sets `tactics.evaluate`, `tactics.on_message` and `tactics.on_event`. |
| `config.lua` | Constants: rule slots (no level gates: all slots and the second condition at every level), preset limits, FIRED rate limits, `DEBUG`. |
| `catalog.lua` | Ids, level gates and ru/en labels for targets, conditions, special actions, item categories, dispel types and server messages. The addon gets all of it in `CAT`. |
| `targets.lua` | Target selectors: `function(env) -> {units in preference order}`. |
| `conditions.lua` | Conditions: `check(env, unit, value)`, plus optional `sort` and `allowDead`. |
| `actions.lua` | Actions: `function(env, unit, rule) -> decision or nil`. |
| `interpreter.lua` | `evaluate`: runs the active preset top-down and returns decisions. |
| `rules.lua` | Rule text format, presets in the DB store, validation for `PUT`. |
| `protocol.lua` | Addon messages (`handlers.<TYPE>`), `CAT` / `PARTY` / `BOOK` replies, the FIRED policy. |
| `spellbook.lua` | Non-tactical spell filter and the `BOOK` export (spells by skill line tab, bag consumables). |
| `util.lua` | Escaping, splitting, sorting and bit helpers. |
| `store.lua` | Store keys per (bot, leader): `store.get/set/erase/view`, `store.leaderOf`, the lazy legacy migration (`store.migrate`). |

Party window ("Отряд", party-window-spec). Each module adds its own
`protocol.handlers.<TYPE>`; `init.lua` loads them after `protocol.lua`:

| file | messages / what it does |
|---|---|
| `inventory.lua` | `INV` -> `BAGS`, `ITEM`, `SELLGREY`, `STATS`, `TRAIN` -> `TRAINER`. Validates fields, maps C++ reasons to ACK codes. |
| `bots.lua` | `BOTS` (account bots, cached 3 s per player), `LOGIN`, `LOGOUT`, `CMD`, `CMDALL`, `GROUP` (formation / raid icon); adds `BOTS` + `GROUPSET` to the `HELLO` reply. |
| `talents.lua` | `TTREE`, `TALENTS`, `TAPPLY` (row gating, prerequisites, point budget checked here), `TSPEC`; premade builds `PRESPECS`, `PRESPEC` (playerbots config specs from `wow.premadeSpecs`, merged and trimmed to the bot's points by `talents.premadeBuild`, then the `TAPPLY` validation); glyphs `GLYPHS`, `GLYPH` (apply / remove). |
| `style.lua` | `STYLE`, `SETSTYLE`: role (tank/heal/dps) and behaviour switches as playerbots `co`/`nc` commands; the AI slider (`SETSTYLE <bot> ai <0..3>`, `STYLE` fields 6-7) and the wake sync of owned bots on `HELLO` / `PARTY`. |
| `orders.lua` | `ORDER`: one-shot "cast now"; the interpreter returns it as the first decision (slot 99) for up to 12 s. |
| `veto.lua` | `VETO`, `VETOS`: per-spell rules for the class AI ("never" / "only on <target>"). |
| `outfits.lua` | `OUTFITS`, `OUTFIT` (save / wear / del / rename). |
| `loot.lua` | `LOOT`, `SETLOOT`; re-applies the stored loot rules once after each login. |
| `quests.lua` | `QUESTS`, `QUEST` (drop / accept all), `QDONE` (completed quests, pages of `config.QDONE_PAGE`). |
| `character.lua` | `REPS` (reputations grouped by parent faction), `SKILLS` (weapon / secondary / profession skills, names from `wow.skillLine`). Exports `character.capJoin` (the `config.LIST_MAX_BYTES` list cap). |
| `vendor.lua` | `VENDOR`, `BUY`, `BUYBACK`, `BUYBACKBUY`: buy from the vendor next to the bot and buy back sold items (party-extras-spec 5.4). |
| `trace.lua` | `TRACE`: the last actions the class AI executed, merged with the Lua AI trace (rule fires and AI-layer decisions; entry fields 6 `kind` and 7 `score100`). |
| `aistat.lua` | `AISTAT`: slider, role, threshold, mana reserve, fires per intent, last decision, fight stats. Also the lazy access to `profile.lua` / `ai/trace.lua` for the protocol modules (stand-ins when those files are missing). |

AI layer (ai-layer-spec): `profile.lua`, `ai\*.lua`. Protocol additions (spec 8):

| message | fields |
|---|---|
| `SETSTYLE <bot> ai <0..3>` | ACK `ok`, `bad_value`, `locked_ai` ("Available from level N."), `store_failed`; then `STYLE` |
| `STYLE` field 6 / 7 | `<ai>,<aiStored>,<aiMax>,<lvl2>,<lvl3>` / `0:labelEsc:hintEsc;1:...;2:...;3:...` (`catalog.aiPositions`) |
| `AISTAT <bot>` | -> `AISTAT <bot> <ai> <role> <threshold100> <reserve> <intentId:n;...> <intentId,score100,agoMs> <fights,switches,silentPct>` |
| `TRACE` entry | `agoMs,nameEsc,ok,target,relevance,kind,score100`; kind `""` class AI, `rule` (name `co#3`), `ai` (name = intent id) |
| `FIRED <bot> <list> 98 <intent>` | an AI-layer decision executed (slot `config.AI_SLOT`) |

`SETSTYLE <bot> aoe <v>` also sets the var `style_touched_aoe` (slider 3 then stops switching `aoe` itself).
Intent labels: `catalog.intents`; slider labels: `catalog.aiPositions`.

Store keys (table `character_tactics`, per guid; all Lua-owned). Since tactics-round2-spec 4 everything a player
configures on a bot is stored per (bot, leader) under `l<leaderGuid>_<key>` (`store.lua`): the same player
re-inviting the bot gets the setup back, another leader gets their own. Leader = `bot:ownerLow()`, else the
per-bot `last_leader`. Always go through `store.get/set/erase(low, key, leader)` for these keys.

| guid | key | scope | data |
|---|---|---|---|
| bot | `l<L>_enabled`, `l<L>_active`, `l<L>_p1`..`l<L>_p5` | bot + leader | rule sets (see `rules.lua`) |
| bot | `l<L>_veto` | bot + leader | `spellFirstRank,mode,target;...` (mode `never` / `only`) |
| bot | `l<L>_ai` | bot + leader | AI slider `0`..`3` (missing = 2); `N!` (sim only) ignores the level gate |
| bot | `l<L>_style` | bot + leader | `role=<tank\|heal\|dps>;<styleKey>=<1\|0>;...` - what the player set with `SETSTYLE` |
| bot | `l<L>_pull` | bot + leader | `wait=<n>;focus=<1\|0>;assist=<strategy\|->` - the last `PULL` that reached this bot |
| bot | `l<L>_aicfg` | bot + leader | AI config overrides `KEY=number;...` (written by the sim sweep only) |
| bot | `last_leader` | bot | leader guid of the last namespaced write (reads of a bot outside a party) |
| bot | `outfits` | bot | `idx<TAB>nameEsc<TAB>slot.entry.guid:...;...` |
| bot | `loot` | bot | `mode<TAB>on<TAB>entry,entry,...` |
| player | `formation`, `rti` | player | group settings (formation name, raid icon id 0..8) |
| player | `pull` | player | pull card display `scope,preset,wait` |

Old rows (`enabled`, `active`, `p1`..`p5`, `veto`, `ai` without a prefix) move to the first leader that has
the bot in the party (`store.migrate`, from `interpreter.evaluate`, `protocol.ownedBot` and `PARTY` / `HELLO`);
until then a leader without keys of its own reads them. `data\sql\custom\tactics_migrate_leader.sql` moves
them for the whole server at once (optional, run by hand).

`style.ensure` (from `evaluate`) re-applies the leader's `style` and `pull` once per var
`style_applied_<L>`: after a relog (vars are cleared), after `TAPPLY` / `TSPEC` / `PRESPEC` and a party-window `reset botAI` (the talent
change resets the playerbots strategies) and when another leader takes the bot.

Vars (`wow.getVar`, not persistent): `order_*`, `veto_rev`, `veto_at`, `loot_applied`, `bots_at`,
`bots_cache_n`, `bots_cache_1..8`, `mig_<L>`, `style_applied_<L>`, `style_due_<L>` (re-apply not before, after a party-window `reset botAI`), plus `watch` / `fired_*` from the rules.

Modules load each other with `wow.include("file.lua")`, which loads a file once per Lua state. There is one
Lua state per server thread, so keep any memory a bot needs between ticks in `wow.getVar` / `wow.setVar`,
not in module-level tables. Module-level tables are fine for static caches such as spell data.

## Зеркалирование / mirroring ("Как в RPG", abilities-mirroring-spec 5)

`mirror.lua` (loaded by `init.lua`, sets `tactics.on_mirror`). C++ (`TacticsMirror.cpp`) watches the real
group leader and calls `tactics.on_mirror(event, player, payload)` on the world thread (same context as
`on_message`); the payload is `k=v;...`. What the owned bots of that leader do:

| event | bots | option |
|---|---|---|
| `quest_accept quest=;giver=` | every bot: `bot:questAccept` (playerbots may have done it: `already` counts as done) | `quest` |
| `quest_reward quest=;giver=;choice=` | only bots that have the quest; incomplete: `bot:questComplete(q)` when `turnin_force`; then `bot:questReward(q, giver, mirror.reward(...))` (the bot gives the required items it has, missing ones do not block) | `turnin`, `turnin_force`, `reward` |
| `quest_abandon quest=` | `bot:dropQuest` | `abandon` |
| `taxi_start` | nothing (playerbots flies the near bots); one feed entry + one chat line | `taxi` |
| `taxi_done`, `teleport_done` | bots farther than `Tactics.Mirror.Radius` (or on another map): `bot:summonToOwner()` | `taxi`, `hearth` |
| `vendor`, `repair` | bots within the radius: `sellGrey` + `repair` (once per 10 s) | `vendor` |
| `trainer` | bots within the radius: `trainerLearnAll` | `train` |
| `gossip` | bots within the radius: `talk` | `talk` (default off) |

Reward (`mirror.reward`): `reward=same` = the player's index when valid; else the best choice by
`bot:itemUsage` (equip / replace > use > bad_equip > rest), `bot:itemFits`, item level, sell price.
Playerbots switches: `quest=0` -> `nc -quest` (back to `+quest` only when `mirror.lua` removed it, or on an
explicit `SETMIRROR`); `taxi` -> `bot:setTaxiMirror(on)` (not persistent: re-applied on `SETMIRROR`, `HELLO`,
`PARTY` and every mirror event). Chat lines (`bot:sayParty`, option `chat`): one bot speaks the good news of an
event, every bot its own problem (bags / quest log full).

| message | fields |
|---|---|
| `MIRROR` | -> `MIRRORSET <k=v;... every key> <bot,k=0,...;... opt-outs> <enable=0\|1,radius=N>` (also after `HELLO`) |
| `SETMIRROR 0 <key> <0\|1\|best\|same>` | player switch; ACK `ok` / `bad_op` / `bad_value` / `store_failed`, then `MIRRORSET` |
| `SETMIRROR <bot> <key> <0\|1>` | per-bot opt-out (bool keys only; `reward` -> `bad_op`), ACK, `MIRRORSET` |
| `MIRRORLOG [<n>]` | -> `MIRRORLOG <age_s,bot,event,0\|1,textEsc;...>` (last n <= 20, oldest first) |
| `MIRRORED <bot\|0> <event> <0\|1> <textEsc>` | pushed per bot action (bot 0 = the party) |

Store: player key `mirror` on the leader guid (only values that differ from the defaults `quest=1;turnin=1;
turnin_force=1;abandon=1;taxi=1;taxi_learn=1;hearth=1;vendor=1;train=1;talk=0;chat=1;reward=best`);
per (bot, leader) `l<L>_mirror` = the bot's opt-outs `k=0;...` (written with `store.key`, not `store.set`: the key is
not in `store.LEADER_KEYS`). Vars: `mirror_log_1..20`, `mirror_log_head`, `mirror_log_n` (leader), `mq_<quest>`,
`mirror_repair_at`, `mirror_qcmd`, `mirror_qcmd_at`, `mirror_qoff_<L>` (bot). Self-test: `sim\selftest_mirror.lua`
(groups `mirror_*`); mock tests: scratchpad `tactics\lua_test_mirror.lua`, `bt_test\bt_test_mirror.lua`.

## Adding a condition (example: "target is moving")

1. In `catalog.lua`, add an entry to `catalog.conditions`. Its position in the list is its position in the
   editor dropdown.
   ```lua
   { id = "moving", param = "none", lvl = 10,
     label = { en = "moving", ru = "движется" }, prefix = { en = "moving", ru = "движется" } },
   ```
   `param` is `"none"`, `"num"` (also set `default`, `min`, `max` and optionally `unit`), `"spell"` (a spell
   from the bot's book, aura picker), `"spellid"` (any spell id, e.g. an enemy cast: typed or pasted as a
   link in the editor), `"dispel"` or `"enum"`. `lvl` is the bot level needed to use the condition (currently 0 for every entry).
2. In `conditions.lua`, add its logic:
   ```lua
   conditions.moving = {
       check = function(env, u, v) return u:isMoving() end,
   }
   ```
   `env.bot` is the bot, `env.ctx` is the tick context (`state`, `now`, `combatMs`), and `env:group()` /
   `env:attackers()` / `env:tank()` are cached for the current call. `v` is the rule value, already parsed for the
   condition's `param`. The candidate must be alive unless you set `allowDead = true`.
3. Reload (see below). The editor picks up the new condition from the `CAT` message the next time the
   window opens or `/reload` runs, with no addon change.

New targets work the same way (`catalog.targets` plus `targets.<id>`), and so do special actions
(`catalog.specials` plus `actions.<id>`). An action returns a decision table using the C++ verbs, for
example `{ verb = "cast", spell = id, target = unit:guid() }`. If a catalogue id has no implementation,
it is hidden from the editor and a warning is logged when the scripts load.

A new addon message is a new function `handlers.MYMSG = function(req, fields) ... end` in `protocol.lua`
(or `protocol.handlers.MYMSG` in a module loaded by `init.lua`), plus matching code in the addon. Use the
shared helpers: `protocol.ownedBot(req, field)` (re-check ownership before every change),
`protocol.ack` / `protocol.ackReason` (C++ reason -> ACK code), `protocol.send`, `protocol.runCommand`.

## Adding a style switch

Add an entry to `catalog.style` in `catalog.lua`:
```lua
{ key = "pull", list = "co", strategy = "pull",
  label = { en = "Pull", ru = "Подтягивать врагов" },
  hint = { en = "The tank pulls the next group.", ru = "Танк сам подводит следующую группу." } },
```
The Style tab shows it after the next `STYLE` reply (labels come from the server), and
`co +pull` / `co -pull` become allowed chat commands. Role strategies per class are in
`catalog.roleStrategies` (copied from `AiFactory::AddDefaultCombatStrategies`).

Class-only switches get `class = { ids }`. Mutually exclusive choices (auras, totems, curses, ...) are radio
groups: `group = "<id>"` on each member plus an entry in `catalog.styleGroups` (class groups are generated
from `classGroups` in `catalog.lua`). Before adding one, check whether the playerbots context of those
strategies is created with `NamedObjectContext<Strategy>(false, true)`: then "+x" drops the siblings by
itself. Protocol: multibot-gap, section "Протокол (реализация)".

## Allowing a bot chat command

Only whitelisted playerbots commands can be sent with `CMD` / `CMDALL` (and by the modules themselves).
Exact texts are in `catalog.commands.exact`; add the text there. `co` / `nc` lists accept only names from
`catalog.style` (incl. `also`), `catalog.roleStrategies` and `catalog.commands.strategies`; formation and
raid icon names are in `catalog.commands`. `CMDROLE <scope> <cmd>` sends a whitelisted command to the bots of
one role scope (`catalog.roleScopes`); the pull card presets are `catalog.pull`.
Anything with a different shape needs a rule in `protocol.commandAllowed`. Check the command name against
`mod-playerbots\src\Ai\Base\ChatTriggerContext.h` first.

## Reloading without a restart

The worldserver reads the scripts from `Tactics.ScriptDir` (in `configs/modules/mod_lonelyice_tactics.conf`; empty = the plugin's lua/tactics).
It points at this folder, so you can edit the files in place. Then run, in the worldserver console or in
game as an admin:

```
.tactics reload      -- every Lua state reloads before its next call; prints "ok, version N" or the load error
.tactics status      -- script dir, version, call / error / limit counters, last load error
```

If a script fails to load, gambits stay off until the next successful reload and the class AI plays
normally. Runtime errors are logged, rate-limited, with the prefix `[tactics]`. Set `config.DEBUG = true`
to log every decision. It is very noisy.

Syntax check before reloading:
```
C:\Games\WoW\deps\luajit\bin\luajit.exe -bl <file>.lua > NUL
```
(run it from `C:\Games\WoW\deps\luajit\bin` so that `luajit` finds its `jit` folder).

## Deploying the party window

Order (party-window-spec section 12): build the C++ first (new `.cpp` files: `cmake` reconfigure, then the
build), install, start the server, then `.tactics reload`. The Lua modules call `bot:setVeto`,
`wow.accountBots` and the other section 3 bindings without checking that they exist, so a reload on an old
worldserver breaks tactics until the new build runs. Install the addon with `tools\install_addon.ps1` and
restart the game client (the client reads the `.toc` file list only at start).

In-game checklist (party-window-spec 10.4):
- `.tactics reload` -> ok; `.tactics status` shows no errors; the worldserver log has no `[tactics]` errors.
- `/bt` (or `/tactics`) opens the window; `/party` may be taken by party chat in the default UI.
- Roster shows the group bots and the account bots; LOGIN of an offline bot -> it appears within 10 s;
  invite -> it is in the group.
- Снаряжение: paperdoll with real items, the model rotates, the slot flyout equips a bag item, ilvl updates.
- Сумки: use a potion, sell grey at a vendor, destroy a grey item (asks first), move an item by drag, open
  trade and "Передать мне" puts the item into the trade window, bank boxes near a banker.
- Таланты: apply a build, switch spec, learn at a trainer (the trainer name shows in the header).
- Книга: order Flash Heal on me -> cast within 2 s and `ORDER done`; veto `never` on Smite -> the bot stops
  casting it.
- Стиль: role switch changes strategies (whisper `co ?` to confirm).
- Прочее: outfit save/wear, loot mode, quests list/drop, summon.
- Тактика: the AI log (`TRACE`) shows recent actions.

In-game checklist, party window extras (party-extras-spec 10; after the C++ build (cmake reconfigure: new sources),
`.tactics reload` and the addon install):
- Таланты -> `Готовые раскладки`: pick a build, confirm -> `ACK PRESPEC ok`; the tree and `TALENTS` match the build.
- Таланты -> `Символы`: put a glyph from the bags into socket 1 (the bot really casts it; the sockets update on the
  next `GLYPHS`, the status line may show "Символ ставится, обновляю..." first).
- Снаряжение sidebar: `Репутация` and `Навыки` match the bot's own character sheet (log in as the bot to compare).
- Self-test: `.tactics sim selftest` -> groups `premade`, `glyphs`, `character`, `vendor`, `qdone` PASS or SKIP.
- Сумки -> `Торговец`: at a vendor buy a stack of water, sell it, buy it back from `Выкуп`.
- Прочее -> задания -> `Выполнено`: pages through with `‹` / `›`; the range text matches the total.

In-game checklist, AI layer (ai-layer-spec 13.4; after the C++ build, `.tactics reload` and the addon install):
- `.tactics reload` -> ok; `.tactics status` shows no errors; the worldserver log has no `[tactics]` errors.
- Стиль: the "Инициатива ИИ" card shows four positions; positions above the bot's level are greyed with the
  tooltip "Доступно с уровня N". Set 1 on a low-level bot -> `STYLE` echoes it (the button stays selected
  after the reply); a greyed position does nothing.
- The line under the buttons shows the AISTAT summary ("ИИ: Прервать 1; молчал 84%") and refreshes every 5 s.
- `/bt` -> Тактика -> AI log after a fight: AI-layer lines in blue with the intent and score ("ИИ: Прервать
  0.85"), rule lines in gold, class-AI lines in the normal colour; failed entries muted.
- A bot with no rules and slider 1 drinks a potion below 35% hp and interrupts a caster; the party frame
  shows a blue "ИИ: ..." label when it happens.
- Slider 0 -> no blue lines at all.
- An emergency rule (`tank hp_lt 35 -> PW:S`) fires less often with slider 2 than with 0 over the same pull
  (eyeball; the sim does the numbers).

## Rules for scripts

- Lua 5.1 / LuaJIT. The sandbox has no `io`, `os`, `require`, `load*`, `debug` or `ffi`; `print` is `wow.log`.
- `evaluate` runs for every eligible bot on every tick with an instruction limit of 200k by default, so keep
  it cheap. Prefer `env:group()` / `env:attackers()` over new API calls.
- Unit handles are GUIDs. Don't keep them between calls. Compare units with `a:guid() == b:guid()`.
- Numbers, ids and rule values never need escaping. Names and labels always go through `util.esc`.
- The instruction and memory limits are checked every 1000 VM instructions, but one call into a C
  string function is a single instruction. Keep patterns applied to client payloads simple (anchored,
  no nested `.-`/`.*` backtracking); `string.rep` is capped at 1 MB per result.
- API return shapes that differ from the obvious: `bot:canCast(spell, u)` returns `ok, reason` with
  `ok = true` for `ok`, `range` (fixable by moving) and `moving` (the cast primitive stops the bot first);
  `bot:spellRange(spell)` returns `min, maxHostile, maxFriendly`.
