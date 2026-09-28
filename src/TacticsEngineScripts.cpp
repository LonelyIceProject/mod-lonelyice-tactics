/*
 * Bot tactics - script registration (implementer B): playerbots contexts, config, .tactics command
 * (reload / status / sim), per-guid variable cleanup on logout.
 */

#include "Chat.h"
#include "CommandScript.h"
#include "ExternalContexts.h"
#include "Player.h"
#include "ScriptMgr.h"
#include "TacticsEngine.h"
#include "TacticsLua.h"

using namespace Acore::ChatCommands;

namespace
{
    using namespace Tactics;

    class TacticsStrategyContext : public NamedObjectContext<Strategy>
    {
    public:
        TacticsStrategyContext() : NamedObjectContext<Strategy>(false, false)
        {
            creators["tactics"] = [](PlayerbotAI* botAI) -> Strategy* { return new TacticsStrategy(botAI); };
        }
    };

    class TacticsActionContext : public NamedObjectContext<Action>
    {
    public:
        TacticsActionContext() : NamedObjectContext<Action>(false, false)
        {
            creators["tactics"] = [](PlayerbotAI* botAI) -> Action* { return new TacticsAction(botAI); };
        }
    };

    class TacticsTriggerContext : public NamedObjectContext<Trigger>
    {
    public:
        TacticsTriggerContext() : NamedObjectContext<Trigger>(false, false)
        {
            creators["tactics"] = [](PlayerbotAI* botAI) -> Trigger* { return new TacticsTrigger(botAI); };
        }
    };

    class TacticsEngineWorldScript : public WorldScript
    {
    public:
        TacticsEngineWorldScript() : WorldScript("TacticsEngineWorldScript", { WORLDHOOK_ON_AFTER_CONFIG_LOAD }) { }

        void OnAfterConfigLoad(bool /*reload*/) override
        {
            LoadConfig();
        }
    };

    class TacticsEnginePlayerScript : public PlayerScript
    {
    public:
        TacticsEnginePlayerScript() : PlayerScript("TacticsEnginePlayerScript", { PLAYERHOOK_ON_LOGOUT }) { }

        void OnPlayerLogout(Player* player) override
        {
            Vars::Clear(player->GetGUID().GetCounter());
        }
    };

    class TacticsCommandScript : public CommandScript
    {
    public:
        TacticsCommandScript() : CommandScript("TacticsCommandScript") { }

        ChatCommandTable GetCommands() const override
        {
            static ChatCommandTable tacticsCommandTable =
            {
                { "reload", HandleReload, SEC_ADMINISTRATOR, Console::Yes },
                { "status", HandleStatus, SEC_ADMINISTRATOR, Console::Yes },
                { "sim",    HandleSim,    SEC_ADMINISTRATOR, Console::Yes },
            };
            static ChatCommandTable commandTable =
            {
                { "tactics", tacticsCommandTable },
            };
            return commandTable;
        }

        static bool HandleReload(ChatHandler* handler)
        {
            std::string const error = Lua::ReloadNow();
            if (!error.empty())
            {
                handler->PSendSysMessage("tactics: reload failed (version {}): {}", Lua::Version(), error);
                return true;
            }

            handler->PSendSysMessage("tactics: ok, version {}", Lua::Version());
            return true;
        }

        static bool HandleStatus(ChatHandler* handler)
        {
            EngineConfig const& cfg = Config();
            Lua::Stats const stats = Lua::GetStats();
            handler->PSendSysMessage("tactics: enable {}, script dir '{}', version {}", cfg.enable ? 1 : 0,
                                     cfg.scriptDir, Lua::Version());
            handler->PSendSysMessage("tactics: live Lua states {}, evaluate calls {}, errors {}, instruction limit hits {}",
                                     stats.liveStates, stats.evaluateCalls, stats.errors, stats.limitHits);
            handler->PSendSysMessage("tactics: last load error: {}",
                                     stats.lastLoadError.empty() ? std::string("none") : stats.lastLoadError);
            return true;
        }

        // Headless bot simulation: the arguments go to Lua
        // tactics.on_sim_command unchanged (start <scenario> [iterations] [groups] | stop | status | list).
        static bool HandleSim(ChatHandler* handler, Tail args)
        {
            std::vector<std::string> lines;
            Lua::OnSimCommand(std::string(args), lines);
            for (std::string const& line : lines)
                handler->SendSysMessage(line);

            return true;
        }
    };
}

void AddTacticsEngineScripts()
{
    Tactics::LoadConfig();

    PlayerbotExternalContexts::Register<Strategy>([]() -> NamedObjectContext<Strategy>* { return new TacticsStrategyContext(); });
    PlayerbotExternalContexts::Register<Action>([]() -> NamedObjectContext<Action>* { return new TacticsActionContext(); });
    PlayerbotExternalContexts::Register<Trigger>([]() -> NamedObjectContext<Trigger>* { return new TacticsTriggerContext(); });

    new TacticsEngineWorldScript();
    new TacticsEnginePlayerScript();
    new TacticsCommandScript();
}
