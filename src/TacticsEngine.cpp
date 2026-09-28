/*
 * Bot tactics - playerbots engine glue (implementer B).
 *
 * Plumbing only: eligibility, mechanics guard (G1/G2), primitive executors. Which rule fires, on
 * whom and why is decided by the Lua scripts (tactics.evaluate).
 */

#include "TacticsEngine.h"

#include "Bag.h"
#include "CharmInfo.h"
#include "ChooseTargetActions.h"
#include "Config.h"
#include "CreatureAI.h"
#include "DungeonStrategyContext.h"
#include "FollowActions.h"
#include "GenericSpellActions.h"
#include "Group.h"
#include "Item.h"
#include "Log.h"
#include "MotionMaster.h"
#include "ObjectAccessor.h"
#include "Pet.h"
#include "Player.h"
#include "Playerbots.h"
#include "RaidStrategyContext.h"
#include "Spell.h"
#include "SpellAuras.h"
#include "SpellInfo.h"
#include "SpellMgr.h"
#include "TacticsBots.h"
#include "TacticsHost.h"
#include "TacticsMetrics.h"
#include "Timer.h"
#include "UseItemAction.h"
#include "Util.h"

#include <algorithm>
#include <cmath>
#include <mutex>
#include <set>
#include <unordered_map>
#if __has_include("PluginMgr.h")
#include "PluginMgr.h"
#endif

namespace Tactics
{
    // ================================================================== config
    namespace
    {
        EngineConfig sConfig;

        std::vector<std::string> SplitList(std::string const& text)
        {
            std::vector<std::string> out;
            std::string current;
            auto flush = [&]()
            {
                size_t b = current.find_first_not_of(" \t");
                size_t e = current.find_last_not_of(" \t");
                if (b != std::string::npos)
                    out.push_back(current.substr(b, e - b + 1));
                current.clear();
            };

            for (char c : text)
            {
                if (c == ',')
                    flush();
                else
                    current += c;
            }

            flush();
            return out;
        }
    }

    EngineConfig const& Config()
    {
        return sConfig;
    }

    // lua/tactics of the plugin folder when loaded as a plugin, the installed lua_scripts/tactics otherwise.
    std::string DefaultScriptDir()
    {
#if __has_include("PluginMgr.h")
        if (PluginInfo const* plugin = sPluginMgr->Find("lonelyice.tactics"))
            return (plugin->dir / "lua" / "tactics").generic_string();
#endif
        return "lua_scripts/tactics";
    }

    void LoadConfig()
    {
        EngineConfig cfg;
        cfg.enable = sConfigMgr->GetOption<bool>("Tactics.Enable", true, false);
        cfg.scriptDir = sConfigMgr->GetOption<std::string>("Tactics.ScriptDir", "", false);
        if (cfg.scriptDir.empty())
            cfg.scriptDir = DefaultScriptDir();
        cfg.relevance = sConfigMgr->GetOption<float>("Tactics.Relevance", 95.0f, false);
        cfg.maxCandidates = std::max<uint32>(1, sConfigMgr->GetOption<uint32>("Tactics.MaxCandidates", 4, false));
        cfg.instructionLimit = std::max<uint32>(1000, sConfigMgr->GetOption<uint32>("Tactics.InstructionLimit", 200000, false));
        cfg.messageInstructionLimit = std::max<uint32>(1000,
            sConfigMgr->GetOption<uint32>("Tactics.MessageInstructionLimit", 5000000, false));
        cfg.memoryLimitMB = std::max<uint32>(4, sConfigMgr->GetOption<uint32>("Tactics.MemoryLimitMB", 64, false));
        cfg.jit = sConfigMgr->GetOption<bool>("Tactics.Jit", false, false);
        cfg.extraMechanics = SplitList(sConfigMgr->GetOption<std::string>("Tactics.ExtraMechanicsStrategies", "avoid aoe", false));
        cfg.errorLogIntervalMs = sConfigMgr->GetOption<uint32>("Tactics.ErrorLogIntervalMs", 10000, false);
        cfg.debug = sConfigMgr->GetOption<bool>("Tactics.Debug", false, false);
        cfg.traceSize = std::min<uint32>(256, sConfigMgr->GetOption<uint32>("Tactics.TraceSize", 24, false));
        cfg.vetoTargetTtlMs = sConfigMgr->GetOption<uint32>("Tactics.VetoTargetTtlMs", 3000, false);
        cfg.simTickMs = std::max<uint32>(50, sConfigMgr->GetOption<uint32>("Tactics.SimTickMs", 250, false));
        cfg.simDir = sConfigMgr->GetOption<std::string>("Tactics.SimDir", "", false);
        cfg.manualKeep = SplitList(sConfigMgr->GetOption<std::string>("Tactics.ManualKeepStrategies",
            "chat,default,follow,food,loot,mount,formation,stay,cast time,avoid aoe,dead,quest", false));
        cfg.manualKeepOptional = SplitList(sConfigMgr->GetOption<std::string>("Tactics.ManualKeepOptional",
            "potions,racials", false));
        cfg.mirrorEnable = sConfigMgr->GetOption<bool>("Tactics.Mirror.Enable", true, false);
        cfg.mirrorRadius = std::clamp(sConfigMgr->GetOption<float>("Tactics.Mirror.Radius", 30.0f, false), 5.0f, 100.0f);

        while (!cfg.scriptDir.empty() && (cfg.scriptDir.back() == '/' || cfg.scriptDir.back() == '\\'))
            cfg.scriptDir.pop_back();

        sConfig = std::move(cfg);
    }

    // ================================================================== logging
    namespace
    {
        std::mutex sLogLock;
        std::unordered_map<std::string, uint32> sLogTimes;

        bool ShouldLog(std::string const& message)
        {
            uint32 const now = getMSTime();
            std::lock_guard<std::mutex> guard(sLogLock);
            if (sLogTimes.size() > 1000)
                sLogTimes.clear();

            auto itr = sLogTimes.find(message);
            if (itr != sLogTimes.end() && getMSTimeDiff(itr->second, now) < Config().errorLogIntervalMs)
                return false;

            sLogTimes[message] = now;
            return true;
        }
    }

    void LogErrorLimited(std::string const& message)
    {
        if (ShouldLog(message))
            LOG_ERROR("module", "[tactics] {}", message);
    }

    void LogWarnLimited(std::string const& message)
    {
        if (ShouldLog(message))
            LOG_WARN("module", "[tactics] {}", message);
    }

    // ================================================================== vars
    namespace Vars
    {
        namespace
        {
            std::mutex sVarLock;
            std::unordered_map<uint32, std::unordered_map<std::string, Value>> sVars;
        }

        std::optional<Value> Get(uint32 guidLow, std::string const& key)
        {
            std::lock_guard<std::mutex> guard(sVarLock);
            auto itr = sVars.find(guidLow);
            if (itr == sVars.end())
                return std::nullopt;

            auto var = itr->second.find(key);
            if (var == itr->second.end())
                return std::nullopt;

            return var->second;
        }

        void Set(uint32 guidLow, std::string const& key, std::optional<Value> value)
        {
            std::lock_guard<std::mutex> guard(sVarLock);
            if (!value)
            {
                auto itr = sVars.find(guidLow);
                if (itr == sVars.end())
                    return;

                itr->second.erase(key);
                if (itr->second.empty())
                    sVars.erase(itr);

                return;
            }

            sVars[guidLow][key] = std::move(*value);
        }

        void Clear(uint32 guidLow)
        {
            std::lock_guard<std::mutex> guard(sVarLock);
            sVars.erase(guidLow);
        }
    }

    // ================================================================== eligibility
    Player* GetOwner(Player* bot)
    {
        if (!bot || !bot->IsInWorld())
            return nullptr;

        Group* group = bot->GetGroup();
        if (!group)
            return nullptr;

        PlayerbotAI* botAI = GET_PLAYERBOT_AI(bot);
        if (!botAI)
            return nullptr;

        // A selfbot leader stands in for a real player: that is how the headless sim runs tactics
        // without a game client. Also applies to ".playerbots bot self" users.
        Player* leader = ObjectAccessor::FindConnectedPlayer(group->GetLeaderGUID());
        if (leader && (IsRealPlayer(leader) || IsSelfBot(leader)))
            return leader;

        Player* master = botAI->GetMaster();
        if (master && IsRealPlayer(master) && master->GetGroup() == group)
            return master;

        return nullptr;
    }

    // ================================================================== shared checks
    CastCheck CheckSpellCast(Player* bot, PlayerbotAI* botAI, SpellInfo const* spellInfo, Unit* target,
                             bool requireKnown)
    {
        CastCheck check;
        if (!spellInfo || (requireKnown && !bot->HasSpell(spellInfo->Id)))
        {
            check.reason = "not_known";
            return check;
        }

        if (!target)
            target = bot;

        if (target != bot)
        {
            bool const friendly = bot->IsFriendlyTo(target);
            check.range = spellInfo->GetMaxRange(friendly, bot);
            if (check.range > 0.0f)
            {
                check.melee = check.range <= NOMINAL_MELEE_RANGE;
                check.outOfRange = check.melee ? !bot->IsWithinMeleeRange(target)
                                               : bot->GetDistance(target) > check.range;
            }

            check.noLos = !bot->IsWithinLOSInMap(target);
        }

        bool const hasCastTime = spellInfo->CalcCastTime(bot) > 0 || spellInfo->IsChanneled() ||
                                 spellInfo->IsAutoRepeatRangedSpell();
        bool const moving = hasCastTime && bot->isMoving();

        if (!botAI->CanCastSpell(spellInfo->Id, target, requireKnown))
        {
            // CanCastSpell rejects out-of-LOS targets and cast-time spells while moving; both are fixable.
            // Rule out the causes that moving/stopping cannot fix first.
            if (bot->HasUnitState(UNIT_STATE_LOST_CONTROL) || bot->HasSpellCooldown(spellInfo->Id) ||
                (target != bot && target->IsImmunedToSpell(spellInfo)))
                check.reason = "cannot_cast";
            else if (target != bot && check.noLos)
                check.reason = "range";
            else if (moving)
                check.reason = "moving";
            else
                check.reason = "cannot_cast";

            return check;
        }

        if (check.outOfRange || check.noLos)
            check.reason = "range";
        else if (moving)
            check.reason = "moving";

        return check;
    }

    Item* FindBagItem(Player* bot, uint32 entry)
    {
        if (!entry)
            return nullptr;

        for (uint8 slot = INVENTORY_SLOT_ITEM_START; slot < INVENTORY_SLOT_ITEM_END; ++slot)
            if (Item* item = bot->GetItemByPos(INVENTORY_SLOT_BAG_0, slot))
                if (item->GetEntry() == entry)
                    return item;

        for (uint8 bag = INVENTORY_SLOT_BAG_START; bag < INVENTORY_SLOT_BAG_END; ++bag)
        {
            Bag* container = bot->GetBagByPos(bag);
            if (!container)
                continue;

            for (uint32 slot = 0; slot < container->GetBagSize(); ++slot)
                if (Item* item = container->GetItemByPos(uint8(slot)))
                    if (item->GetEntry() == entry)
                        return item;
        }

        return nullptr;
    }

    uint32 ItemUseSpell(Item* item)
    {
        ItemTemplate const* proto = item ? item->GetTemplate() : nullptr;
        if (!proto)
            return 0;

        for (uint8 i = 0; i < MAX_ITEM_PROTO_SPELLS; ++i)
            if (proto->Spells[i].SpellId > 0 && proto->Spells[i].SpellTrigger == ITEM_SPELLTRIGGER_ON_USE)
                return uint32(proto->Spells[i].SpellId);

        return 0;
    }

    char const* CheckItemUse(Player* bot, PlayerbotAI* botAI, uint32 entry, Unit* target, CastCheck* cast)
    {
        Item* item = FindBagItem(bot, entry);
        if (!item)
            return "no_item";

        if (bot->CanUseItem(item) != EQUIP_ERR_OK)
            return "level";

        uint32 const spellId = ItemUseSpell(item);
        if (spellId && bot->HasSpellCooldown(spellId))
            return "cooldown";

        // a potion used in this fight: its cooldown only starts when combat ends (Player::m_lastPotionId)
        if (bot->GetLastPotionId() && item->GetTemplate()->IsPotion())
            return "cooldown";

        if (!target || target == bot || !spellId)
            return "ok";

        SpellInfo const* spellInfo = sSpellMgr->GetSpellInfo(spellId);
        if (!spellInfo)
            return "ok";

        CastCheck check = CheckSpellCast(bot, botAI, spellInfo, target, false);
        if (cast)
            *cast = check;

        return (check.outOfRange || check.noLos) ? "range" : "ok";
    }

    // ================================================================== mechanics set (spec 2.4)
    namespace
    {
        std::set<std::string> const& BuiltinMechanics()
        {
            static std::set<std::string> const names = []()
            {
                std::set<std::string> result = DungeonStrategyContext().supports();
                std::set<std::string> raid = RaidStrategyContext().supports();
                result.insert(raid.begin(), raid.end());
                return result;
            }();
            return names;
        }

        bool IsMechanicsStrategy(std::string const& name)
        {
            if (BuiltinMechanics().count(name))
                return true;

            for (std::string const& extra : Config().extraMechanics)
                if (extra == name)
                    return true;

            return false;
        }

        char const* StateName(BotState state)
        {
            switch (state)
            {
                case BOT_STATE_COMBAT:
                    return "combat";
                case BOT_STATE_NON_COMBAT:
                    return "noncombat";
                default:
                    return nullptr;
            }
        }
    }

    // ================================================================== strategy
    void TacticsStrategy::InitTriggers(std::vector<TriggerNode*>& triggers)
    {
        triggers.push_back(new TriggerNode("tactics", { NextAction("tactics", Config().relevance) }));
    }

    void TacticsStrategy::InitMultipliers(std::vector<Multiplier*>& multipliers)
    {
        multipliers.push_back(new TacticsVetoMultiplier(botAI));
        multipliers.push_back(new TacticsManualMultiplier(botAI));
    }

    TacticsAction* GetRuntime(PlayerbotAI* botAI)
    {
        AiObjectContext* context = botAI ? botAI->GetAiObjectContext() : nullptr;
        return context ? dynamic_cast<TacticsAction*>(context->GetAction("tactics")) : nullptr;
    }

    namespace
    {
        // Action::GetTarget() dereferences its target value unchecked; an action whose GetTargetName()
        // names no value would crash, so look the value up first.
        Unit* ActionTarget(Action* action)
        {
            return action->GetTargetValue() ? action->GetTarget() : nullptr;
        }
    }

    // ================================================================== veto multiplier (party spec 2.9)
    float TacticsVetoMultiplier::GetValue(Action* action)
    {
        if (!runtime)
            runtime = dynamic_cast<TacticsAction*>(context->GetAction("tactics"));

        // vetoes are a party-window setting: they constrain the class AI only while a real player owns the bot
        if (!runtime || runtime->veto.empty() || !runtime->trace->owned)
            return 1.0f;

        CastSpellAction* cast = dynamic_cast<CastSpellAction*>(action);
        if (!cast)
            return 1.0f;

        std::string const spell = cast->getSpell();
        for (TacticsAction::VetoEntry const& entry : runtime->veto)
        {
            if (entry.spell != spell)
                continue;

            if (!entry.only)
                return 0.0f;

            if (!entry.target || getMSTimeDiff(entry.targetAt, getMSTime()) > Config().vetoTargetTtlMs)
                return 0.0f;

            Unit* target = ActionTarget(action);
            return (target && target->GetGUID() == entry.target) ? 1.0f : 0.0f;
        }

        return 1.0f;
    }

    // ================================================================== manual mode (abilities-mirroring-spec 3.2)
    namespace
    {
        constexpr size_t MAX_MANUAL_NAMES = 4000;   // guard against pathological action graphs

        bool Contains(std::vector<std::string> const& list, std::string const& name)
        {
            return std::find(list.begin(), list.end(), name) != list.end();
        }

        // Every action name the given strategies can put into an engine queue: trigger handlers and default
        // actions, then (transitively) the prerequisites / alternatives / continuers of those actions. The
        // action node of a name comes from the first loaded strategy that has a factory for it (the engine
        // merges all factories of its strategies), else a plain node, as Engine::CreateActionNode does.
        // Needed because an action zeroed by a multiplier still pushes its alternatives (Engine.cpp:231-235).
        void CollectActionNames(PlayerbotAI* botAI, std::vector<Strategy*> const& from,
                                std::vector<Strategy*> const& nodeSources, std::set<std::string>& out)
        {
            AiObjectContext* context = botAI->GetAiObjectContext();
            std::vector<std::string> pending;
            for (Strategy* strategy : from)
            {
                std::vector<TriggerNode*> nodes;
                strategy->InitTriggers(nodes);
                for (TriggerNode* node : nodes)
                {
                    for (NextAction next : node->getHandlers())
                        pending.push_back(next.getName());

                    delete node;
                }

                for (NextAction next : strategy->getDefaultActions())
                    pending.push_back(next.getName());
            }

            while (!pending.empty() && out.size() < MAX_MANUAL_NAMES)
            {
                std::string const name = pending.back();
                pending.pop_back();
                if (name.empty() || !out.insert(name).second)
                    continue;

                Action* action = context->GetAction(name);
                if (!action)
                    continue;

                ActionNode* node = nullptr;
                for (Strategy* source : nodeSources)
                    if ((node = source->GetAction(name)))
                        break;

                if (!node)
                    node = new ActionNode(name);

                node->setAction(action);
                for (NextAction next : node->getPrerequisites())
                    pending.push_back(next.getName());
                for (NextAction next : node->getAlternatives())
                    pending.push_back(next.getName());
                for (NextAction next : node->getContinuers())
                    pending.push_back(next.getName());

                delete node;
            }
        }
    }

    float TacticsManualMultiplier::GetValue(Action* action)
    {
        if (!runtime)
            runtime = dynamic_cast<TacticsAction*>(context->GetAction("tactics"));

        // both settings belong to the party window: they constrain the class AI only while a real player owns the bot
        if (!runtime || !action || !runtime->trace->owned || (!runtime->manual && !runtime->mirrorTaxiOff))
            return 1.0f;

        std::string const name = action->getName();
        if (name == "tactics")
            return 1.0f;

        // mirroring opt-out (spec 4.1): playerbots copies the owner's flight through these two actions
        if (runtime->mirrorTaxiOff && (name == "taxi" || name == "remember taxi"))
            return 0.0f;

        if (!runtime->manual || botAI->GetState() == BOT_STATE_DEAD)
            return 1.0f;

        // a rule is walking the bot to its melee target: the kept follow must not pull it back meanwhile
        if (runtime->engageUntil && getMSTimeDiff(getMSTime(), runtime->engageUntil) < 4000 &&
            name.find("follow") != std::string::npos)
            return 0.0f;

        return runtime->ManualSuppressed(name) ? 0.0f : 1.0f;
    }

    bool TacticsAction::ManualSuppressed(std::string const& name)
    {
        RefreshManual();
        return manualSuppressed.count(name) != 0;
    }

    void TacticsAction::RefreshManual()
    {
        // the multiplier asks once per queued action: rebuild the key at most once per millisecond
        uint32 const now = getMSTime();
        if (!manualKey.empty() && manualCheckMs == now)
            return;

        manualCheckMs = now;

        BotState const state = botAI->GetState();
        std::vector<std::string> const loaded = botAI->GetStrategies(state);
        std::vector<std::string> const& optional = manualKeep ? *manualKeep : Config().manualKeepOptional;

        std::string key = std::to_string(uint32(state)) + "|";
        for (std::string const& name : loaded)
            key += name + ",";
        key += "|";
        for (std::string const& name : optional)
            key += name + ",";

        if (key == manualKey)
            return;

        manualKey = key;
        manualSuppressed.clear();

        std::vector<Strategy*> kept;
        std::vector<Strategy*> other;
        std::vector<Strategy*> all;
        for (std::string const& name : loaded)
        {
            Strategy* strategy = botAI->GetStrategy(name, state);
            if (!strategy)
                continue;

            all.push_back(strategy);
            if (name == "tactics" || IsMechanicsStrategy(name) || Contains(Config().manualKeep, name) ||
                Contains(optional, name))
                kept.push_back(strategy);
            else
                other.push_back(strategy);
        }

        std::set<std::string> suppressed;
        std::set<std::string> allowed;
        CollectActionNames(botAI, other, all, suppressed);
        CollectActionNames(botAI, kept, all, allowed);

        // an action reachable from a kept or mechanics strategy stays allowed
        for (std::string const& name : suppressed)
            if (!allowed.count(name) && name != "tactics")
                manualSuppressed.insert(name);
    }

    namespace
    {
        // Another group member (alive, on the bot's map, within sight distance) is in combat.
        bool GroupFighting(Player* bot)
        {
            Group* group = bot->GetGroup();
            if (!group)
                return false;

            for (GroupReference* ref = group->GetFirstMember(); ref; ref = ref->next())
            {
                Player* member = ref->GetSource();
                if (!member || member == bot || !member->IsInWorld() || !member->IsAlive() ||
                    member->GetMapId() != bot->GetMapId())
                    continue;

                if (member->IsInCombat() && bot->GetDistance2d(member) <= sPlayerbotAIConfig.sightDistance)
                    return true;
            }

            return false;
        }
    }

    bool TacticsAction::SyncManualEngine()
    {
        if (!manual || !trace->owned || !bot->IsAlive())
            return false;

        BotState const state = botAI->GetState();
        if (state != BOT_STATE_NON_COMBAT && state != BOT_STATE_COMBAT)
            return false;

        bool const fighting = bot->IsInCombat() || GroupFighting(bot);
        if (state == BOT_STATE_NON_COMBAT && fighting)
        {
            // what AttackAction::Attack does for the class AI (AttackAction.cpp:192)
            botAI->ChangeEngine(BOT_STATE_COMBAT);
            if (Config().debug)
                LOG_INFO("module", "[tactics] {} manual: combat engine (fight started)", bot->GetName());
            return true;
        }

        // what the suppressed "invalid target" -> "drop target" pair does (CombatStrategy.cpp:21-28,
        // ChooseTargetActions.cpp:41-63); a rule still walking to a valid target keeps the combat engine
        if (state == BOT_STATE_COMBAT && !fighting &&
            context->GetValue<bool>("invalid target", "current target")->Get())
        {
            context->GetValue<Unit*>("current target")->Set(nullptr);
            botAI->ChangeEngine(BOT_STATE_NON_COMBAT);
            if (Config().debug)
                LOG_INFO("module", "[tactics] {} manual: non-combat engine (fight over)", bot->GetName());
            return true;
        }

        return false;
    }

    // ================================================================== decision trace (party spec 2.9)
    void TacticsTraceListener::After(Action* action, bool executed, Event /*event*/)
    {
        uint32 const size = Config().traceSize;
        if (!action || !log->owned || !size)
            return;

        TraceEntry entry;
        entry.at = getMSTime();
        entry.name = action->getName();
        entry.ok = executed;
        if (Unit* target = ActionTarget(action))
            entry.target = target->GetGUID();
        entry.relevance = action->getRelevance();

        log->entries.push_back(std::move(entry));
        while (log->entries.size() > size)
            log->entries.pop_front();
    }

    void TacticsAction::InstallTraceListeners()
    {
        for (uint8 i = 0; i < BOT_STATE_MAX; ++i)
        {
            Engine* engine = botAI->GetEngine(BotState(i));
            if (!engine || tracedEngines[i] == engine)
                continue;

            // the engine owns (and deletes) the listener; it shares only the trace buffer with us
            engine->AddActionExecutionListener(new TacticsTraceListener(trace));
            tracedEngines[i] = engine;
        }
    }

    // ================================================================== action
    class TacticsUseItemHelper : public UseItemAction
    {
    public:
        TacticsUseItemHelper(PlayerbotAI* botAI) : UseItemAction(botAI, "tactics use item") { }

        bool Use(Item* item, Unit* target) { return UseItem(item, ObjectGuid::Empty, nullptr, target); }
    };

    TacticsAction::TacticsAction(PlayerbotAI* botAI) : AttackAction(botAI, "tactics") { }

    TacticsAction::~TacticsAction()
    {
        ClearMechanics();
    }

    void TacticsAction::ClearMechanics()
    {
        for (Multiplier* multiplier : mechanicsMultipliers)
            delete multiplier;

        mechanicsMultipliers.clear();
        mechanicsTriggers.clear();
        mechanicsDefaults.clear();
        mechanicsKey.clear();
    }

    void TacticsAction::RefreshMechanics()
    {
        BotState const state = botAI->GetState();
        std::vector<std::string> loaded;
        std::string key = std::to_string(uint32(state)) + "|";
        for (std::string const& name : botAI->GetStrategies(state))
        {
            if (!IsMechanicsStrategy(name))
                continue;

            loaded.push_back(name);
            key += name;
            key += ',';
        }

        if (key == mechanicsKey)
            return;

        ClearMechanics();
        mechanicsKey = key;

        std::set<std::string> triggerNames;
        std::set<std::string> defaultNames;
        for (std::string const& name : loaded)
        {
            Strategy* strategy = botAI->GetStrategy(name, state);
            if (!strategy)
                continue;

            std::vector<TriggerNode*> nodes;
            strategy->InitTriggers(nodes);
            for (TriggerNode* node : nodes)
            {
                triggerNames.insert(node->getName());
                delete node;
            }

            strategy->InitMultipliers(mechanicsMultipliers);

            // Strategies such as "avoid aoe" work only through default actions (no triggers).
            // Those with a relevance below ours would be starved by the tactics action.
            for (NextAction next : strategy->getDefaultActions())
                if (next.getRelevance() < Config().relevance)
                    defaultNames.insert(next.getName());
        }

        mechanicsTriggers.assign(triggerNames.begin(), triggerNames.end());
        mechanicsDefaults.assign(defaultNames.begin(), defaultNames.end());
    }

    bool TacticsAction::MechanicsActive()
    {
        RefreshMechanics();
        for (std::string const& name : mechanicsTriggers)
        {
            Trigger* trigger = context->GetTrigger(name);
            if (trigger && trigger->IsActive())
                return true;
        }

        for (std::string const& name : mechanicsDefaults)
        {
            Action* action = context->GetAction(name);
            if (action && action != this && action->isUseful() && action->isPossible())
                return true;
        }

        return false;
    }

    bool TacticsAction::MechanicsAllow(Action* probe)
    {
        if (!probe)
            return true;

        for (Multiplier* multiplier : mechanicsMultipliers)
            if (multiplier->GetValue(probe) <= 0.0f)
                return false;

        return true;
    }

    TacticsAction::Result TacticsAction::MechanicsBlocked()
    {
        Metrics::Add(bot->GetGUID(), "guard_g2", 1.0);
        return { false, "mechanics" };
    }

    Action* TacticsAction::CastProbe(uint32 spellId)
    {
        auto itr = castProbes.find(spellId);
        if (itr != castProbes.end())
            return itr->second.get();

        SpellInfo const* spellInfo = sSpellMgr->GetSpellInfo(spellId);
        if (!spellInfo)
            return nullptr;

        // playerbots names spell actions after the lower-case enUS spell name
        std::string name = spellInfo->SpellName[0] ? spellInfo->SpellName[0] : "";
        std::wstring wname;
        if (Utf8toWStr(name, wname))
        {
            wstrToLower(wname);
            WStrToUtf8(wname, name);
        }

        if (castProbes.size() >= 64)
            castProbes.clear();

        CastSpellAction* probe = new CastSpellAction(botAI, name);
        castProbes[spellId].reset(probe);
        return probe;
    }

    TacticsAction::Result TacticsAction::MoveIntoRange(Unit* target, CastCheck const& check)
    {
        if (check.outOfRange && ReachCombatTo(target, check.melee ? 0.0f : std::max(0.0f, check.range - 1.5f)))
            return { true, "reach" };

        if (check.noLos && MoveTo(target->GetMapId(), target->GetPositionX(), target->GetPositionY(),
                                  target->GetPositionZ()))
            return { true, "reach" };

        return { false, "range" };
    }

    namespace
    {
        Unit* ResolveTarget(Player* bot, ObjectGuid guid)
        {
            if (!guid)
                return nullptr;

            Unit* unit = ObjectAccessor::GetUnit(*bot, guid);
            if (!unit || !unit->IsInWorld() || unit->GetMap() != bot->GetMap())
                return nullptr;

            return unit;
        }

        // True when the bot's movement is not its own (fear, confuse, charm, knockback, flight...):
        // stopping must never clear those movement generators.
        bool MovementControlled(Player* bot)
        {
            if (bot->HasUnitState(UNIT_STATE_LOST_CONTROL | UNIT_STATE_CONFUSED | UNIT_STATE_FLEEING))
                return true;

            switch (bot->GetMotionMaster()->GetCurrentMovementGeneratorType())
            {
                case CONFUSED_MOTION_TYPE:
                case FLEEING_MOTION_TYPE:
                case TIMED_FLEEING_MOTION_TYPE:
                case DISTRACT_MOTION_TYPE:
                case ASSISTANCE_MOTION_TYPE:
                case ASSISTANCE_DISTRACT_MOTION_TYPE:
                case FLIGHT_MOTION_TYPE:
                case EFFECT_MOTION_TYPE:
                case ROTATE_MOTION_TYPE:
                    return true;
                default:
                    return false;
            }
        }
    }

    TacticsAction::Result TacticsAction::DoCast(Lua::Decision const& d)
    {
        Unit* target = bot;
        if (d.hasTarget && !(target = ResolveTarget(bot, d.target)))
            return { false, "invalid_target" };

        SpellInfo const* spellInfo = d.spell ? sSpellMgr->GetSpellInfo(d.spell) : nullptr;
        if (!spellInfo || !bot->HasSpell(d.spell))
            return { false, "not_known" };

        if (bot->IsNonMeleeSpellCast(false, false, true))
            return { false, "busy" };

        CastCheck const check = CheckSpellCast(bot, botAI, spellInfo, target, true);
        std::string const reason = check.reason;
        if (reason == "not_known" || reason == "cannot_cast")
            return { false, check.reason };

        if (!MechanicsAllow(CastProbe(d.spell)))
            return MechanicsBlocked();

        if (reason == "range")
            return d.reach ? MoveIntoRange(target, check) : Result{ false, "range" };

        if (reason == "moving")
        {
            // stand still this tick, cast on the next one
            if (MovementControlled(bot))
                return { false, "cannot_cast" };

            bot->StopMoving();
            bot->GetMotionMaster()->Clear();
            return { true, "reach" };
        }

        Metrics::TacticsCastScope scope;   // "casts_tactics" for the headless sim
        return botAI->CastSpell(d.spell, target) ? Result{ true, "ok" } : Result{ false, "failed" };
    }

    TacticsAction::Result TacticsAction::DoUse(Lua::Decision const& d)
    {
        Unit* target = bot;
        if (d.hasTarget && !(target = ResolveTarget(bot, d.target)))
            return { false, "invalid_target" };

        CastCheck check;
        std::string const reason = CheckItemUse(bot, botAI, d.item, target, &check);
        if (reason == "no_item")
            return { false, "no_item" };

        if (reason == "cooldown")
            return { false, "cooldown" };

        if (reason == "level")
            return { false, "failed" };

        if (bot->IsNonMeleeSpellCast(false, false, true))
            return { false, "busy" };

        if (reason == "range")
            return d.reach ? MoveIntoRange(target, check) : Result{ false, "range" };

        Item* item = FindBagItem(bot, d.item);
        if (!item)
            return { false, "no_item" };

        if (!useItem)
            useItem = std::make_unique<TacticsUseItemHelper>(botAI);

        Metrics::TacticsCastScope scope;   // "casts_tactics" for the headless sim
        return useItem->Use(item, target == bot ? nullptr : target) ? Result{ true, "ok" } : Result{ false, "failed" };
    }

    TacticsAction::Result TacticsAction::DoAttack(Lua::Decision const& d)
    {
        Unit* target = d.hasTarget ? ResolveTarget(bot, d.target) : nullptr;
        if (!target || !bot->IsValidAttackTarget(target))
            return { false, "invalid_target" };

        if (!attackProbe)
            attackProbe = std::make_unique<DpsAssistAction>(botAI);

        if (!MechanicsAllow(attackProbe.get()))
            return MechanicsBlocked();

        SET_AI_VALUE(Unit*, "current target", target);
        return Attack(target) ? Result{ true, "ok" } : Result{ false, "failed" };
    }

    TacticsAction::Result TacticsAction::DoMove(Lua::Decision const& d)
    {
        if (!d.hasPos || !std::isfinite(d.x) || !std::isfinite(d.y) || !std::isfinite(d.z))
            return { false, "failed", true };

        if (!MechanicsAllow(this))
            return MechanicsBlocked();

        return MoveTo(bot->GetMapId(), d.x, d.y, d.z) ? Result{ true, "ok" } : Result{ false, "failed" };
    }

    TacticsAction::Result TacticsAction::DoFollow(Lua::Decision const& d)
    {
        Unit* target = d.hasTarget ? ResolveTarget(bot, d.target) : nullptr;
        if (!d.hasTarget)
        {
            Player* owner = GetOwner(bot);
            if (owner && owner->IsInWorld() && owner->GetMap() == bot->GetMap())
                target = owner;
        }

        if (!target)
            return { false, "invalid_target" };

        if (!followProbe)
            followProbe = std::make_unique<FollowAction>(botAI);

        if (!MechanicsAllow(followProbe.get()))
            return MechanicsBlocked();

        float const dist = (d.hasDist && std::isfinite(d.dist) && d.dist >= 0.0f) ? d.dist
                                                                                 : sPlayerbotAIConfig.followDistance;
        return Follow(target, dist) ? Result{ true, "ok" } : Result{ false, "failed" };
    }

    TacticsAction::Result TacticsAction::DoStop()
    {
        if (MovementControlled(bot))
            return { false, "failed" };

        bot->StopMoving();
        bot->GetMotionMaster()->Clear();
        return { true, "ok" };
    }

    // ================================================================== abilities-mirroring-spec 2.2 primitives
    namespace
    {
        Unit* AttackTarget(Player* bot, Lua::Decision const& d)
        {
            Unit* target = d.hasTarget ? ResolveTarget(bot, d.target) : nullptr;
            if (!target || !target->IsAlive() || !bot->IsValidAttackTarget(target))
                return nullptr;

            return target;
        }

        bool AutoRepeatOn(Player* bot, uint32 spellId, Unit* target)
        {
            Spell* current = bot->GetCurrentSpell(CURRENT_AUTOREPEAT_SPELL);
            return current && current->GetSpellInfo() && current->GetSpellInfo()->Id == spellId &&
                   current->m_targets.GetUnitTargetGUID() == target->GetGUID();
        }
    }

    // Hold melee auto-attack on the target: walk into melee range first ("reach"), then start (or keep) it.
    TacticsAction::Result TacticsAction::DoMelee(Lua::Decision const& d)
    {
        Unit* target = AttackTarget(bot, d);
        if (!target)
            return { false, "invalid_target" };

        if (!attackProbe)
            attackProbe = std::make_unique<DpsAssistAction>(botAI);

        if (!MechanicsAllow(attackProbe.get()))
            return MechanicsBlocked();

        SET_AI_VALUE(Unit*, "current target", target);

        if (!bot->IsWithinMeleeRange(target))
        {
            if (MovementControlled(bot))
                return { false, "failed" };

            if (!ReachCombatTo(target, 0.0f))
                return { false, "failed" };

            engageUntil = getMSTime() + 4000;   // a manual bot's kept follow yields while it closes in
            return { true, "reach" };
        }

        if (bot->GetVictim() == target && bot->HasUnitState(UNIT_STATE_MELEE_ATTACKING))
            return { true, "already" };

        // a running auto shot / wand would keep the bot in ranged mode
        if (bot->GetCurrentSpell(CURRENT_AUTOREPEAT_SPELL))
            bot->InterruptSpell(CURRENT_AUTOREPEAT_SPELL);

        // AttackAction::Attack (AttackAction.cpp:55-218): selection, facing, combat engine, bot->Attack(target,
        // melee = in melee range). Its second argument is `with_pet` (unused), not "melee".
        if (Attack(target))
            return { true, "ok" };

        bot->SetSelection(target->GetGUID());
        return bot->Attack(target, true) ? Result{ true, "ok" } : Result{ false, "failed" };
    }

    // Auto Shot / Shoot (wand) / Throw: an auto-repeat ranged spell the core keeps repeating by itself.
    TacticsAction::Result TacticsAction::DoShoot(Lua::Decision const& d)
    {
        Unit* target = AttackTarget(bot, d);
        if (!target)
            return { false, "invalid_target" };

        SpellInfo const* spellInfo = d.spell ? sSpellMgr->GetSpellInfo(d.spell) : nullptr;
        if (!spellInfo || !spellInfo->IsAutoRepeatRangedSpell() || !bot->HasSpell(d.spell))
            return { false, "not_known" };

        if (AutoRepeatOn(bot, d.spell, target))
            return { true, "already" };

        if (bot->IsNonMeleeSpellCast(false, false, true))
            return { false, "busy" };

        CastCheck const check = CheckSpellCast(bot, botAI, spellInfo, target, true);
        std::string const reason = check.reason;
        if (reason == "not_known" || reason == "cannot_cast")
            return { false, check.reason };

        if (!attackProbe)
            attackProbe = std::make_unique<DpsAssistAction>(botAI);

        if (!MechanicsAllow(attackProbe.get()))
            return MechanicsBlocked();

        SET_AI_VALUE(Unit*, "current target", target);

        if (reason == "range")
            return d.reach ? MoveIntoRange(target, check) : Result{ false, "range" };

        if (reason == "moving")
        {
            if (MovementControlled(bot))
                return { false, "cannot_cast" };

            bot->StopMoving();
            bot->GetMotionMaster()->Clear();
            return { true, "reach" };
        }

        bot->SetSelection(target->GetGUID());
        Metrics::TacticsCastScope scope;   // "casts_tactics" for the headless sim
        return botAI->CastSpell(d.spell, target) ? Result{ true, "ok" } : Result{ false, "failed" };
    }

    TacticsAction::Result TacticsAction::DoStopAttack()
    {
        bot->AttackStop();
        if (bot->GetCurrentSpell(CURRENT_AUTOREPEAT_SPELL))
            bot->InterruptSpell(CURRENT_AUTOREPEAT_SPELL);

        SET_AI_VALUE(Unit*, "current target", nullptr);
        bot->SetSelection(ObjectGuid::Empty);
        return { true, "ok" };
    }

    // Removes the bot's own aura of every rank of the spell's chain, under the client's CMSG_CANCEL_AURA
    // rules (SpellHandler.cpp:568-602): positive, not passive, no SPELL_ATTR0_NO_AURA_CANCEL.
    TacticsAction::Result TacticsAction::DoCancel(Lua::Decision const& d)
    {
        SpellInfo const* spellInfo = d.spell ? sSpellMgr->GetSpellInfo(d.spell) : nullptr;
        if (!spellInfo)
            return { false, "failed", true };

        uint32 const first = sSpellMgr->GetFirstSpellInChain(d.spell);
        std::vector<uint32> ranks;
        for (auto const& applied : bot->GetAppliedAuras())
        {
            uint32 const auraId = applied.first;
            if (auraId == d.spell || (first && sSpellMgr->GetFirstSpellInChain(auraId) == first))
                if (std::find(ranks.begin(), ranks.end(), auraId) == ranks.end())
                    ranks.push_back(auraId);
        }

        if (ranks.empty())
            return { true, "already" };

        bool removed = false;
        for (uint32 rank : ranks)
        {
            SpellInfo const* info = sSpellMgr->GetSpellInfo(rank);
            if (!info || info->HasAttribute(SPELL_ATTR0_NO_AURA_CANCEL) || !info->IsPositive() || info->IsPassive())
                continue;

            bot->RemoveOwnedAura(rank, ObjectGuid::Empty, 0, AURA_REMOVE_BY_CANCEL);
            removed = true;
        }

        return removed ? Result{ true, "ok" } : Result{ false, "cannot_cancel" };
    }

    // Pet commands, as playerbots' PetsAction (PB\Ai\Base\Actions\PetsAction.cpp:153-340) does them for the
    // bot's own pet (Player::GetPet); guardians are left to the class AI.
    TacticsAction::Result TacticsAction::DoPet(Lua::Decision const& d)
    {
        Pet* pet = bot->GetPet();
        if (!pet || !pet->IsInWorld() || !pet->IsAlive())
            return { false, "no_pet" };

        CharmInfo* charmInfo = pet->GetCharmInfo();
        if (!charmInfo)
            return { false, "failed" };

        std::string const& cmd = d.cmd;
        if (cmd == "attack")
        {
            Unit* target = AttackTarget(bot, d);
            if (!target)
                return { false, "invalid_target" };

            if (pet->GetVictim() == target && charmInfo->IsCommandAttack())
                return { true, "already" };

            pet->ClearUnitState(UNIT_STATE_FOLLOW);
            if (pet->GetVictim())
                pet->AttackStop();

            charmInfo->SetIsCommandAttack(true);
            charmInfo->SetIsAtStay(false);
            charmInfo->SetIsFollowing(false);
            charmInfo->SetIsCommandFollow(false);
            charmInfo->SetIsReturning(false);

            if (pet->IsAIEnabled && pet->AI())
                pet->AI()->AttackStart(target);
            else
                pet->Attack(target, true);

            return { true, "ok" };
        }

        if (cmd == "follow")
        {
            botAI->PetFollow();
            return { true, "ok" };
        }

        if (cmd == "stay")
        {
            bool const controlledMotion =
                pet->GetMotionMaster()->GetMotionSlotType(MOTION_SLOT_CONTROLLED) != NULL_MOTION_TYPE;
            if (!controlledMotion)
            {
                pet->StopMovingOnCurrentPos();
                pet->GetMotionMaster()->Clear(false);
                pet->GetMotionMaster()->MoveIdle();
            }

            charmInfo->SetCommandState(COMMAND_STAY);
            charmInfo->SetIsCommandAttack(false);
            charmInfo->SetIsCommandFollow(false);
            charmInfo->SetIsFollowing(false);
            charmInfo->SetIsReturning(false);
            charmInfo->SetIsAtStay(!controlledMotion);
            charmInfo->SaveStayPosition(controlledMotion);
            pet->ClearCastWhenWillAvailable();
            charmInfo->SetForcedSpell(0);
            charmInfo->SetForcedTargetGUID();
            return { true, "ok" };
        }

        ReactStates react;
        if (cmd == "passive")
            react = REACT_PASSIVE;
        else if (cmd == "defensive")
            react = REACT_DEFENSIVE;
        else if (cmd == "aggressive")
            react = REACT_AGGRESSIVE;
        else
            return { false, "failed", true };   // malformed decision

        pet->SetReactState(react);
        charmInfo->SetPlayerReactState(react);
        return { true, "ok" };
    }

    TacticsAction::Result TacticsAction::DoPetCast(Lua::Decision const& d)
    {
        Pet* pet = bot->GetPet();
        if (!pet || !pet->IsInWorld() || !pet->IsAlive())
            return { false, "no_pet" };

        SpellInfo const* spellInfo = d.spell ? sSpellMgr->GetSpellInfo(d.spell) : nullptr;
        if (!spellInfo || spellInfo->IsPassive() || !pet->HasSpell(d.spell))
            return { false, "not_known" };

        // Creature::HasSpellCooldown (Creature.h:168); there is no Pet::GetSpellCooldownDelay
        if (pet->HasSpellCooldown(d.spell))
            return { false, "cooldown" };

        Unit* target = nullptr;
        if (d.hasTarget && !(target = ResolveTarget(bot, d.target)))
            return { false, "invalid_target" };

        if (!target)
            target = pet->GetVictim();
        if (!target)
            target = bot;

        if (pet->IsNonMeleeSpellCast(false))
            return { false, "failed" };

        Metrics::TacticsCastScope scope;   // "casts_tactics" for the headless sim
        return pet->CastSpell(target, d.spell, false) == SPELL_CAST_OK ? Result{ true, "ok" } : Result{ false, "failed" };
    }

    // Same path as the Lua binding bot:command (Party::Command, TacticsBots.cpp): a queued whisper of the
    // owner (else the playerbots master) that the bot runs on its next tick. The whitelist is Lua's.
    TacticsAction::Result TacticsAction::DoCommand(Lua::Decision const& d)
    {
        if (d.text.empty())
            return { false, "bad_cmd" };

        Player* requester = GetOwner(bot);
        if (!requester)
            requester = botAI->GetMaster();

        if (!requester)
            return { false, "failed" };

        Party::AiResult const result = Party::Command(bot, requester, d.text);
        return { result.ok, result.reason };
    }

    TacticsAction::Result TacticsAction::Run(Lua::Decision const& d)
    {
        std::string const& verb = d.verb;
        if (verb == "cast")
            return DoCast(d);
        if (verb == "use")
            return DoUse(d);
        if (verb == "attack")
            return DoAttack(d);
        if (verb == "move")
            return DoMove(d);
        if (verb == "follow")
            return DoFollow(d);
        if (verb == "stop")
            return DoStop();
        if (verb == "wait")
            return { true, "ok" };
        if (verb == "melee")
            return DoMelee(d);
        if (verb == "shoot")
            return DoShoot(d);
        if (verb == "stopattack")
            return DoStopAttack();
        if (verb == "cancel")
            return DoCancel(d);
        if (verb == "pet")
            return DoPet(d);
        if (verb == "petcast")
            return DoPetCast(d);
        if (verb == "command")
            return DoCommand(d);

        return { false, "failed", true };
    }

    bool TacticsAction::Execute(Event /*event*/)
    {
        if (decisions.empty())
            return false;

        std::vector<Lua::Decision> candidates;
        candidates.swap(decisions);

        std::optional<Lua::LastResult> first;
        for (Lua::Decision const& d : candidates)
        {
            Result const result = Run(d);

            if (result.skipped)
            {
                LogWarnLimited("skipped malformed decision (verb '" + d.verb + "', slot " + std::to_string(d.slot) + ")");
                continue;
            }

            if (Config().debug)
                LOG_INFO("module", "[tactics] {} {}#{} {} {} -> {} {}", bot->GetName(), d.list, d.slot, d.verb,
                         d.tag, result.ok ? "ok" : "fail", result.reason);

            Lua::LastResult outcome;
            outcome.slot = d.slot;
            outcome.list = d.list;
            outcome.verb = d.verb;
            outcome.ok = result.ok;
            outcome.reason = result.reason;
            outcome.at = getMSTime();

            if (result.ok)
            {
                last = std::move(outcome);
                return true;
            }

            if (!first)
                first = std::move(outcome);
        }

        if (first)
            last = std::move(first);

        return false;
    }

    // ================================================================== trigger (spec 2.6)
    bool TacticsTrigger::IsActive()
    {
        TacticsAction* runtime = dynamic_cast<TacticsAction*>(context->GetAction("tactics"));
        if (!runtime)
            return false;

        runtime->decisions.clear();

        uint32 const now = getMSTime();
        if (bot->IsInCombat())
        {
            if (!runtime->combatStartMs)
                runtime->combatStartMs = now ? now : 1;
        }
        else
            runtime->combatStartMs = 0;

        EngineConfig const& cfg = Config();
        if (!cfg.enable)
        {
            runtime->trace->owned = false;
            return false;
        }

        runtime->trace->owned = GetOwner(bot) != nullptr;
        if (!runtime->trace->owned)
            return false;

        // 4a: decision trace listeners (party spec 2.9), installed once per engine
        runtime->InstallTraceListeners();

        // manual mode: the suppressed class AI no longer switches the engine; the state below (and so the
        // co / nc list) must follow the fight
        runtime->SyncManualEngine();

        char const* state = StateName(botAI->GetState());
        if (!state)
            return false;

        // no rules stored and Lua did not ask to be woken up (one-shot order pending)
        if (!Store::Revision(bot->GetGUID().GetCounter()) && !runtime->wake)
            return false;

        if (runtime->MechanicsActive())
        {
            Metrics::Add(bot->GetGUID(), "guard_g1", 1.0);   // headless sim counter (no-op unless watched)
            return false;
        }

        Lua::EvalInput input;
        input.state = state;
        input.now = now;
        input.combatMs = runtime->combatStartMs ? getMSTimeDiff(runtime->combatStartMs, now) : 0;
        input.last = std::move(runtime->last);
        runtime->last.reset();

        Lua::Evaluate(bot, input, cfg.maxCandidates, runtime->decisions);
        return !runtime->decisions.empty();
    }
}
