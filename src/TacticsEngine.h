/*
 * Bot tactics - playerbots engine glue (implementer B). B-private header.
 *
 * One strategy, one trigger and one action, all named "tactics". The trigger asks Lua
 * (tactics.evaluate) which rule decisions apply this tick; the action runs the first decision whose
 * C++ primitive succeeds. No behaviour policy lives here: C++ only guards dungeon/raid mechanics,
 * checks eligibility and executes primitive game commands (cast, use, attack, move, follow, stop, wait;
 * abilities-mirroring-spec 2.2: melee, shoot, stopattack, cancel, pet, petcast, command).
 *
 *
 * AI stages 0-1 (class-AI veto multiplier, decision trace, wake): party-window-spec, section 2.9.
 */

#ifndef MOD_LONELYICE_TACTICS_ENGINE_H
#define MOD_LONELYICE_TACTICS_ENGINE_H

#include "AttackAction.h"
#include "Engine.h"
#include "Multiplier.h"
#include "PlayerbotAI.h"
#include "Strategy.h"
#include "TacticsLua.h"
#include "Trigger.h"

#include <deque>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

class CastSpellAction;
class Item;
class Multiplier;
class Player;
class PlayerbotAI;
class SpellInfo;
class Unit;

namespace Tactics
{
    // ------------------------------------------------------------------ config (section 3.2)
    struct EngineConfig
    {
        bool enable = true;
        std::string scriptDir = "lua_scripts/tactics";
        float relevance = 95.0f;
        uint32 maxCandidates = 4;
        uint32 instructionLimit = 200000;
        uint32 messageInstructionLimit = 5000000;
        uint32 memoryLimitMB = 64;
        bool jit = false;
        std::vector<std::string> extraMechanics = { "avoid aoe" };
        uint32 errorLogIntervalMs = 10000;
        bool debug = false;
        uint32 traceSize = 24;            // decision trace entries kept per owned bot (0 = off)
        uint32 vetoTargetTtlMs = 3000;    // "only on <target>" veto: target refreshed by Lua within this time
        uint32 simTickMs = 250;           // headless sim: tactics.on_tick period
        std::string simDir;               // headless sim output folder; empty = <LogsDir>/sim

        // manual mode (abilities-mirroring-spec 3.2): strategies whose actions the class AI keeps running
        std::vector<std::string> manualKeep = { "chat", "default", "follow", "food", "loot", "mount", "formation",
                                                "stay", "cast time", "avoid aoe", "dead" };
        // kept too unless Lua passes its own list to bot:setManual (the "strict" checkbox passes {})
        std::vector<std::string> manualKeepOptional = { "potions", "racials" };

        // player action mirroring (abilities-mirroring-spec 5.3)
        bool mirrorEnable = true;
        float mirrorRadius = 30.0f;
    };

    // Written only by LoadConfig on the world thread (startup / .reload config), while maps are not updating.
    EngineConfig const& Config();
    void LoadConfig();

    // The real player who controls this bot (group leader, else master in the same group), or nullptr.
    // A selfbot group leader (".playerbots bot self", or the headless sim leader) counts as the owner too.
    Player* GetOwner(Player* bot);

    // ------------------------------------------------------------------ shared primitive checks
    // Used by the cast/use primitives and by the Lua bindings bot:canCast / bot:canUse.
    struct CastCheck
    {
        // "ok", "not_known", "cannot_cast", "range" (out of range or LOS, reachable by moving) or
        // "moving" (castable once the bot stands still)
        char const* reason = "ok";
        bool outOfRange = false;
        bool noLos = false;
        bool melee = false;               // max range is melee range
        float range = 0.0f;               // max range for this target (0 = no range check)
    };

    CastCheck CheckSpellCast(Player* bot, PlayerbotAI* botAI, SpellInfo const* spellInfo, Unit* target,
                             bool requireKnown);

    Item* FindBagItem(Player* bot, uint32 entry);          // first stack in backpack + bags
    uint32 ItemUseSpell(Item* item);                       // first ITEM_SPELLTRIGGER_ON_USE spell, 0 if none

    // "no_item", "level", "cooldown", "range", "ok". range/LOS details in *cast when given.
    char const* CheckItemUse(Player* bot, PlayerbotAI* botAI, uint32 entry, Unit* target, CastCheck* cast = nullptr);

    // One log line per distinct message per Tactics.ErrorLogIntervalMs.
    void LogErrorLimited(std::string const& message);
    void LogWarnLimited(std::string const& message);

    // ------------------------------------------------------------------ per-guid scratch variables
    // Thread-safe; survive script reloads; cleared on that character's logout.
    namespace Vars
    {
        struct Value
        {
            enum class Kind : uint8 { Bool, Number, String } kind = Kind::Bool;
            bool b = false;
            double n = 0.0;
            std::string s;
        };

        std::optional<Value> Get(uint32 guidLow, std::string const& key);
        void Set(uint32 guidLow, std::string const& key, std::optional<Value> value);   // nullopt = erase
        void Clear(uint32 guidLow);
    }

    // ------------------------------------------------------------------ playerbots objects
    class TacticsStrategy : public Strategy
    {
    public:
        TacticsStrategy(PlayerbotAI* botAI) : Strategy(botAI) { }

        std::string const getName() override { return "tactics"; }
        uint32 GetType() const override { return STRATEGY_TYPE_GENERIC; }
        void InitTriggers(std::vector<TriggerNode*>& triggers) override;
        void InitMultipliers(std::vector<Multiplier*>& multipliers) override;
    };

    class TacticsAction;

    // Class-AI veto (party window, spec 2.9): 0 for a CastSpellAction whose spell the player vetoed
    // ("never", or "only on X" while the action targets something else). Owned by the engine
    // (created in TacticsStrategy::InitMultipliers, deleted by Engine::Reset). TacticsAction itself is
    // not a CastSpellAction, so gambit rules and one-shot orders are never vetoed.
    class TacticsVetoMultiplier : public Multiplier
    {
    public:
        TacticsVetoMultiplier(PlayerbotAI* botAI) : Multiplier(botAI, "tactics veto") { }

        float GetValue(Action* action) override;

    private:
        TacticsAction* runtime = nullptr;   // lives in the AiObjectContext, which outlives the engines
    };

    // Manual mode ("only my rules", abilities-mirroring-spec 3.2) and the taxi mirroring opt-out (4.1):
    // 0 for every class-AI action of a loaded strategy that is neither a mechanics strategy nor in the
    // keep list; the "tactics" action itself and the dead state are never touched. Registered next to the
    // veto multiplier; only active while a real player owns the bot.
    class TacticsManualMultiplier : public Multiplier
    {
    public:
        TacticsManualMultiplier(PlayerbotAI* botAI) : Multiplier(botAI, "tactics manual") { }

        float GetValue(Action* action) override;

    private:
        TacticsAction* runtime = nullptr;   // lives in the AiObjectContext, which outlives the engines
    };

    // Decision trace (spec 2.9, stage 0). Shared between the per-bot runtime and the engine listeners:
    // Engine's listener list DELETES its listeners in its destructor, so a listener cannot be a member
    // of TacticsAction; each engine gets its own heap listener that only holds this shared buffer.
    struct TraceEntry
    {
        uint32 at = 0;
        std::string name;
        bool ok = false;
        ObjectGuid target;
        float relevance = 0.0f;
    };

    struct TraceLog
    {
        bool owned = false;               // GetOwner(bot) != nullptr on the last trigger tick
        std::deque<TraceEntry> entries;   // newest last, at most Config().traceSize
    };

    class TacticsTraceListener : public ActionExecutionListener
    {
    public:
        explicit TacticsTraceListener(std::shared_ptr<TraceLog> log) : log(std::move(log)) { }

        bool Before(Action* /*action*/, Event /*event*/) override { return true; }
        bool AllowExecution(Action* /*action*/, Event /*event*/) override { return true; }
        void After(Action* action, bool executed, Event event) override;
        bool OverrideResult(Action* /*action*/, bool executed, Event /*event*/) override { return executed; }

    private:
        std::shared_ptr<TraceLog> log;
    };

    class TacticsUseItemHelper;

    // The per-bot runtime lives in this action (one instance per bot, owned by its AiObjectContext).
    class TacticsAction : public AttackAction
    {
    public:
        TacticsAction(PlayerbotAI* botAI);
        ~TacticsAction() override;

        bool Execute(Event event) override;
        bool isUseful() override { return !decisions.empty(); }
        bool isPossible() override { return true; }

        // --- runtime, used by TacticsTrigger
        std::vector<Lua::Decision> decisions;
        std::optional<Lua::LastResult> last;
        uint32 combatStartMs = 0;

        // --- party window AI stages 0-1 (spec 2.9)
        struct VetoEntry
        {
            std::string spell;            // lowercase enGB name, as CastSpellAction::getSpell()
            bool only = false;            // false = never; true = only on `target`
            ObjectGuid target;
            uint32 targetAt = 0;          // getMSTime() of the last Lua refresh
        };

        std::vector<VetoEntry> veto;      // not persistent: Lua pushes it (bot:setVeto)
        bool wake = false;                // Lua asked to be evaluated even with an empty store
        std::shared_ptr<TraceLog> trace = std::make_shared<TraceLog>();   // .owned = "rt.owned" of the spec
        Engine* tracedEngines[BOT_STATE_MAX] = { };

        // Adds the trace listener to every engine of the bot that does not have it yet.
        void InstallTraceListeners();

        // G1: true when a trigger (or a useful, possible default action) of a loaded mechanics strategy is active.
        bool MechanicsActive();

        // --- manual mode (abilities-mirroring-spec 3.2), not persistent: Lua pushes it (bot:setManual)
        bool manual = false;
        std::optional<std::vector<std::string>> manualKeep;   // nullopt = Config().manualKeepOptional
        bool mirrorTaxiOff = false;       // bot:setTaxiMirror(false): suppress playerbots "taxi" / "remember taxi"

        // True when manual mode suppresses the named class-AI action in the current state.
        bool ManualSuppressed(std::string const& name);
        void ResetManualCache() { manualKey.clear(); manualCheckMs = 0; }

        // Manual mode: playerbots enters its combat engine only from AttackAction::Attack / pull (class-AI
        // actions such as "dps assist" / "tank assist" of the non-combat engine) and leaves it from "drop
        // target" (CombatStrategy) - all suppressed by the manual multiplier. Without this sync a manual bot
        // stays in the non-combat engine through the fight and only its nc list runs (rfc_manual M: no rule
        // ever fired). Switches the engine by the fight state; true when it changed the engine.
        bool SyncManualEngine();

    private:
        struct Result
        {
            bool ok = false;
            char const* reason = "failed";
            bool skipped = false;         // unknown verb / malformed decision: not reported as outcome
        };

        Result Run(Lua::Decision const& d);
        Result DoCast(Lua::Decision const& d);
        Result DoUse(Lua::Decision const& d);
        Result DoAttack(Lua::Decision const& d);
        Result DoMove(Lua::Decision const& d);
        Result DoFollow(Lua::Decision const& d);
        Result DoStop();

        // abilities-mirroring-spec 2.2
        Result DoMelee(Lua::Decision const& d);
        Result DoShoot(Lua::Decision const& d);
        Result DoStopAttack();
        Result DoCancel(Lua::Decision const& d);
        Result DoPet(Lua::Decision const& d);
        Result DoPetCast(Lua::Decision const& d);
        Result DoCommand(Lua::Decision const& d);

        // Range / LOS movement shared by cast and use ("reach" on success, "range" otherwise).
        Result MoveIntoRange(Unit* target, CastCheck const& check);

        // G2: false when a mechanics multiplier suppresses the probe.
        bool MechanicsAllow(Action* probe);
        Result MechanicsBlocked();        // { false, "mechanics" }, counted as guard_g2 for the headless sim
        Action* CastProbe(uint32 spellId);

        void RefreshMechanics();
        void ClearMechanics();

        std::string mechanicsKey;
        std::vector<std::string> mechanicsTriggers;
        std::vector<std::string> mechanicsDefaults;   // default actions of mechanics strategies (e.g. "avoid aoe")
        std::vector<Multiplier*> mechanicsMultipliers;

        void RefreshManual();

        std::string manualKey;            // state | loaded strategies | keep list of the cached set
        uint32 manualCheckMs = 0;         // getMSTime() of the last key check (one check per ms)
        std::set<std::string> manualSuppressed;

    public:
        // getMSTime() until which a manual bot's kept "follow" actions yield to a rule's melee approach
        // (out of combat, follow would pull the bot back to the leader every tick)
        uint32 engageUntil = 0;

    private:

        std::map<uint32, std::unique_ptr<CastSpellAction>> castProbes;
        std::unique_ptr<Action> followProbe;
        std::unique_ptr<Action> attackProbe;
        std::unique_ptr<TacticsUseItemHelper> useItem;
    };

    class TacticsTrigger : public Trigger
    {
    public:
        TacticsTrigger(PlayerbotAI* botAI) : Trigger(botAI, "tactics", 1) { }

        bool IsActive() override;
    };

    // The per-bot runtime (the bot's "tactics" action) or nullptr (tactics contexts not registered).
    TacticsAction* GetRuntime(PlayerbotAI* botAI);
}

#endif
