/*
 * Bot tactics - headless bot simulation, C++ side.
 *
 * Plumbing only: world primitives for the Lua scenario driver (`wow.sim.*`), the tactics.on_tick pump
 * (world thread, after the map updates finished, like GM commands) and the CSV file sink in <LogsDir>/sim.
 * No scenario semantics: what to log in, where to fight, when a fight ends and what goes into the report
 * are decided by sim/driver.lua, sim/report.lua and sim/scenarios/*.lua.
 *
 * Every wow.sim primitive runs only inside a sim entry call (tactics.on_sim_command / tactics.on_tick,
 * CallContext::sim) and returns false, "wrong_thread" (or nil) anywhere else, so neither addon messages
 * nor evaluate can reach it. Bots are logged in through the random-bot holder without a master
 * (AddPlayerBot(guid, 0)): they are not in RandomPlayerbotMgr::currentBots, so the random-bot cycles
 * leave them alone (design 2.2).
 *
 * Party window self-test (sim/selftest.lua): wow.sim.asLeader(low, fn) runs fn with the call's anchor set
 * to a selfbot sim leader, so MessagePlayer() returns it and the party-window primitives / protocol
 * handlers take their normal message-player path. No ownership rule is changed: GetOwner() already
 * accepts a selfbot group leader (bot-sim-design 3). The exception is narrow by construction - only in a
 * sim entry call (a GM console command or the sim tick, never an addon message or evaluate), only for a
 * bot this sim logged in (sBots) that is its own master, never nested, and logout/cleanup are refused
 * while it runs (the anchor pointer must stay valid).
 */

#include "TacticsSim.h"

#include "TacticsEngine.h"
#include "TacticsMetrics.h"

#include "CharacterCache.h"
#include "Config.h"
#include "Creature.h"
#include "DatabaseEnv.h"
#include "DBCStores.h"
#include "Group.h"
#include "GroupMgr.h"
#include "Log.h"
#include "Map.h"
#include "MapMgr.h"
#include "ObjectAccessor.h"
#include "ObjectMgr.h"
#include "Pet.h"
#include "Player.h"
#include "PlayerbotFactory.h"
#include "Playerbots.h"
#include "PlayerbotsDatabase.h"
#include "ScriptMgr.h"
#include "StringFormat.h"
#include "TemporarySummon.h"
#include "Timer.h"
#include "World.h"

#include <atomic>
#include <cmath>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <list>
#include <set>
#include <tuple>
#include <unordered_map>
#include <vector>

namespace Tactics::Sim
{
    namespace
    {
        constexpr size_t MAX_FILE_WRITE = 4 * 1024 * 1024;   // bytes per fileWrite / fileAppend call
        constexpr size_t MAX_POOL_ROWS = 400;
        constexpr float MAX_FIND_RADIUS = 150.0f;
        constexpr size_t MAX_SPAWN_ROWS = 64;                // wow.sim.spawns
        constexpr uint32 MAX_TICK_FAILURES = 20;             // consecutive failed on_tick calls before the pump stops

        std::atomic<bool> sActive{ false };

        // World thread only (sim entry calls and the world script).
        uint32 sTickAccum = 0;
        uint32 sTickFailures = 0;
        std::set<uint32> sBots;                              // low guids logged in by wow.sim.login
        uint32 sAnchorLow = 0;                               // leader of a running wow.sim.asLeader, else 0

        // Keyed by Metrics::KeyOf (GUID + instance id): the same creature GUID exists in every parallel instance.
        // Lua sees the key as the creature's "guidHex".
        struct TrackedCreature
        {
            ObjectGuid guid;                                 // the real GUID in its map
            uint32 mapId = 0;
            uint32 instanceId = 0;
            bool summoned = false;                           // true: ours to despawn; false: native (wow.sim.find)
        };

        std::unordered_map<ObjectGuid, TrackedCreature> sCreatures;

        using OkReason = std::tuple<bool, std::string>;

        OkReason Fail(char const* reason) { return { false, reason }; }
        OkReason Ok(char const* reason = "ok") { return { true, reason }; }

        bool SimCall()
        {
            Lua::CallContext* call = Lua::CurrentCall();
            return call && call->sim && !call->map;
        }

        ObjectGuid PlayerGuid(uint32 low)
        {
            return ObjectGuid::Create<HighGuid::Player>(low);
        }

        // An online playerbot in the world (not in a far teleport), or nullptr.
        Player* BotInWorld(uint32 low, PlayerbotAI** ai = nullptr)
        {
            if (!low)
                return nullptr;

            Player* bot = ObjectAccessor::FindConnectedPlayer(PlayerGuid(low));
            if (!bot || !bot->IsInWorld() || !bot->GetSession())
                return nullptr;

            PlayerbotAI* botAI = GET_PLAYERBOT_AI(bot);
            if (!botAI)
                return nullptr;

            if (ai)
                *ai = botAI;

            return bot;
        }

        // BotInWorld() restricted to bots this sim logged in (wow.sim.login). Every primitive that changes a
        // bot goes through this one, so a real player's bot or a random bot can never be touched.
        Player* SimBot(uint32 low, PlayerbotAI** ai = nullptr)
        {
            return sBots.count(low) ? BotInWorld(low, ai) : nullptr;
        }

        Creature* TrackedCreatureOf(ObjectGuid key, TrackedCreature const** info = nullptr)
        {
            auto itr = sCreatures.find(key);
            if (itr == sCreatures.end())
                return nullptr;

            if (info)
                *info = &itr->second;

            Map* map = sMapMgr->FindMap(itr->second.mapId, itr->second.instanceId);
            return map ? map->GetCreature(itr->second.guid) : nullptr;
        }

        // Starts tracking a creature; returns its key (the Lua guidHex).
        ObjectGuid Track(Creature* creature, bool summoned)
        {
            ObjectGuid const key = Metrics::KeyOf(creature);
            auto itr = sCreatures.find(key);
            if (itr == sCreatures.end() || summoned)
            {
                TrackedCreature info;
                info.guid = creature->GetGUID();
                info.mapId = creature->GetMapId();
                info.instanceId = creature->GetInstanceId();
                info.summoned = summoned;
                sCreatures[key] = info;
            }

            return key;
        }

        bool ParseState(std::string const& name, BotState& out)
        {
            if (name == "co" || name == "combat")
                out = BOT_STATE_COMBAT;
            else if (name == "nc" || name == "noncombat")
                out = BOT_STATE_NON_COMBAT;
            else if (name == "dead")
                out = BOT_STATE_DEAD;
            else
                return false;

            return true;
        }

        bool PlainText(std::string const& text, size_t maxLen)
        {
            if (text.empty() || text.size() > maxLen)
                return false;

            for (char c : text)
                if (uint8(c) < 0x20 || uint8(c) == 0x7F)
                    return false;

            return true;
        }

        // "<name>.<ext>": [A-Za-z0-9_-]+ "." [A-Za-z]+ (design 4.3: ^[%w_%-]+%.%a+$)
        bool ValidFileName(std::string const& name)
        {
            size_t const dot = name.find('.');
            if (dot == std::string::npos || dot == 0 || dot + 1 >= name.size() || name.size() > 128)
                return false;

            for (size_t i = 0; i < dot; ++i)
            {
                char const c = name[i];
                if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '-'))
                    return false;
            }

            for (size_t i = dot + 1; i < name.size(); ++i)
                if (!std::isalpha(static_cast<unsigned char>(name[i])))
                    return false;

            return true;
        }

        std::filesystem::path OutputDir()
        {
            std::string dir = Config().simDir;
            if (dir.empty())
            {
                std::string logs = sConfigMgr->GetOption<std::string>("LogsDir", "", false);
                while (!logs.empty() && (logs.back() == '/' || logs.back() == '\\'))
                    logs.pop_back();

                dir = logs.empty() ? std::string("sim") : logs + "/sim";
            }

            return std::filesystem::path(dir);
        }

        // Returns ok, full path | reason.
        OkReason WriteFile(std::string const& name, std::string const& text, bool append)
        {
            if (!ValidFileName(name))
                return Fail("bad_name");

            if (text.size() > MAX_FILE_WRITE)
                return Fail("too_large");

            std::error_code ec;
            std::filesystem::path const dir = OutputDir();
            std::filesystem::create_directories(dir, ec);
            if (ec)
                return Fail("no_dir");

            std::filesystem::path const path = dir / name;
            std::ofstream file(path, std::ios::out | std::ios::binary | (append ? std::ios::app : std::ios::trunc));
            if (!file)
                return Fail("open_failed");

            file.write(text.data(), std::streamsize(text.size()));
            if (!file)
                return Fail("write_failed");

            return { true, path.generic_string() };
        }

        // Clean fight state: alive, full health/mana/energy, no rage/runic power, no cooldowns, no
        // non-passive auras, out of combat, repaired. Returns false when the bot is not in the world.
        bool Restore(Player* bot)
        {
            if (!bot->IsAlive())
            {
                bot->ResurrectPlayer(1.0f);
                bot->SpawnCorpseBones();
            }

            bot->CombatStop(true);
            bot->RemoveAllAurasOnDeath();   // everything that is not passive or death-persistent
            bot->SetFullHealth();
            for (uint8 i = 0; i < MAX_POWERS; ++i)
            {
                Powers const power = Powers(i);
                if (power == POWER_HAPPINESS || power == POWER_RUNE)
                    continue;

                bool const empty = power == POWER_RAGE || power == POWER_RUNIC_POWER;
                bot->SetPower(power, empty ? 0 : bot->GetMaxPower(power));
            }

            bot->RemoveAllSpellCooldown();
            bot->DurabilityRepairAll(false, 0.0f, false);

            if (Pet* pet = bot->GetPet())
                if (pet->IsAlive())
                {
                    pet->CombatStop(true);
                    pet->SetFullHealth();
                }

            return true;
        }

        void DespawnTracked(ObjectGuid guid)
        {
            TrackedCreature const* info = nullptr;
            Creature* creature = TrackedCreatureOf(guid, &info);
            if (creature && info && info->summoned)
            {
                if (TempSummon* summon = creature->ToTempSummon())
                    summon->UnSummon();
                else
                    creature->DespawnOrUnsummon();
            }

            sCreatures.erase(guid);
        }

        // Take the bot out of its group (groups are persistent: sim bots must not stay grouped in the DB).
        void LeaveGroup(Player* bot)
        {
            if (Group* group = bot->GetGroup())
                group->RemoveMember(bot->GetGUID());   // may disband (and delete) the group
        }

        // wow.sim.asLeader: the sim call's anchor becomes the leader for the scope. The resolution cache is
        // swapped out (a sim call without an anchor resolves players only; with one, creatures on the
        // anchor's map resolve too) and put back afterwards.
        class AnchorScope
        {
        public:
            AnchorScope(Lua::CallContext* call, Player* leader, uint32 low) : _call(call)
            {
                _saved.swap(_call->cache);
                _call->anchor = leader;
                sAnchorLow = low;
            }

            ~AnchorScope()
            {
                _call->anchor = nullptr;
                _call->cache.swap(_saved);
                sAnchorLow = 0;
            }

            AnchorScope(AnchorScope const&) = delete;
            AnchorScope& operator=(AnchorScope const&) = delete;

        private:
            Lua::CallContext* _call;
            std::unordered_map<ObjectGuid, Unit*> _saved;
        };
    }

    // ================================================================== tick pump (world thread)
    class TacticsSimWorldScript : public WorldScript
    {
    public:
        TacticsSimWorldScript() : WorldScript("TacticsSimWorldScript", { WORLDHOOK_ON_UPDATE }) { }

        // WorldScript::OnUpdate runs after sMapMgr->Update (World.cpp), while no map thread is working.
        void OnUpdate(uint32 diff) override
        {
            if (!sActive.load())
            {
                sTickAccum = 0;
                return;
            }

            sTickAccum += diff;
            if (sTickAccum < Config().simTickMs)
                return;

            uint32 const dt = sTickAccum;
            sTickAccum = 0;
            if (Lua::OnTick(dt))
            {
                sTickFailures = 0;
                return;
            }

            if (++sTickFailures >= MAX_TICK_FAILURES)
            {
                LOG_ERROR("module", "[tactics] sim: tactics.on_tick failed {} times in a row, tick pump stopped "
                          "(bots stay logged in; '.tactics sim stop' cleans up)", sTickFailures);
                sActive = false;
                sTickFailures = 0;
            }
        }
    };
}

// ================================================================== wow.sim bindings
namespace Tactics::Lua
{
    using namespace Tactics::Sim;

    void RegisterSimApi(sol::state_view& lua, sol::table& wow)
    {
        sol::table sim = lua.create_table();

        // active([on]) -> on. The tick pump calls tactics.on_tick while this is set.
        sim["active"] = [](sol::optional<bool> on)
        {
            if (on && SimCall())
            {
                sActive = *on;
                sTickAccum = 0;
                sTickFailures = 0;
            }

            return sActive.load();
        };

        // pool([class]) -> { {low, name, race, class, level, online}, ... } of the addclass accounts (type 2).
        sim["pool"] = [](sol::optional<uint32> cls, sol::this_state s)
        {
            sol::state_view view(s);
            sol::table list = view.create_table();
            if (!SimCall())
                return list;

            QueryResult accounts = PlayerbotsDatabase.Query("SELECT account_id FROM playerbots_account_type WHERE account_type = 2");
            if (!accounts)
                return list;

            std::string ids;
            do
            {
                if (!ids.empty())
                    ids += ',';
                ids += std::to_string(accounts->Fetch()[0].Get<uint32>());
            } while (accounts->NextRow());

            std::string const classFilter = (cls && *cls) ? Acore::StringFormat(" AND class = {}", *cls) : std::string();
            QueryResult chars = CharacterDatabase.Query(
                "SELECT guid, name, race, class, level FROM characters WHERE account IN ({}){} AND deleteInfos_Name IS NULL "
                "ORDER BY level DESC, guid LIMIT {}", ids, classFilter, MAX_POOL_ROWS);
            if (!chars)
                return list;

            int n = 0;
            do
            {
                Field* fields = chars->Fetch();
                uint32 const low = fields[0].Get<uint32>();
                sol::table row = view.create_table(0, 6);
                row["low"] = low;
                row["name"] = fields[1].Get<std::string>();
                row["race"] = uint32(fields[2].Get<uint8>());
                row["class"] = uint32(fields[3].Get<uint8>());
                row["level"] = uint32(fields[4].Get<uint8>());
                row["online"] = ObjectAccessor::FindConnectedPlayer(PlayerGuid(low)) != nullptr;
                list[++n] = row;
            } while (chars->NextRow());

            return list;
        };

        // login(low) -> ok, "pending" | "online" (already ours) ; bad_bot, in_use, not_addclass
        sim["login"] = [](uint32 low) -> OkReason
        {
            if (!SimCall())
                return Fail("wrong_thread");

            ObjectGuid const guid = PlayerGuid(low);
            if (!low || !sCharacterCache->GetCharacterCacheByGuid(guid))
                return Fail("bad_bot");

            if (ObjectAccessor::FindConnectedPlayer(guid))
                return (sBots.count(low) && sRandomPlayerbotMgr.GetPlayerBot(guid)) ? Ok("online") : Fail("in_use");

            if (!sRandomPlayerbotMgr.IsAddclassBot(low))
                return Fail("not_addclass");

            sBots.insert(low);
            sRandomPlayerbotMgr.AddPlayerBot(guid, 0);   // asynchronous (login query holder)
            return Ok("pending");
        };

        // logout(low): only bots this sim logged in. Leaves its group first (groups are persistent).
        sim["logout"] = [](uint32 low) -> OkReason
        {
            if (!SimCall())
                return Fail("wrong_thread");

            if (!sBots.count(low))
                return Fail("not_sim");

            if (sAnchorLow)
                return Fail("busy");   // inside wow.sim.asLeader: the anchor must stay valid

            ObjectGuid const guid = PlayerGuid(low);
            Player* bot = sRandomPlayerbotMgr.GetPlayerBot(guid);
            if (!bot)
            {
                sBots.erase(low);
                return Ok("offline");
            }

            if (bot->IsInWorld())
            {
                bot->RemovePlayerFlag(PLAYER_FLAGS_NO_XP_GAIN);   // saved on logout, like cleanup()
                LeaveGroup(bot);
            }

            if (PlayerbotAI* ai = GET_PLAYERBOT_AI(bot))
                ai->SetMaster(nullptr);

            sRandomPlayerbotMgr.LogoutPlayerBot(guid);   // deletes the Player
            if (sRandomPlayerbotMgr.GetPlayerBot(guid))
                return Fail("failed");

            sBots.erase(low);
            return Ok();
        };

        // bots() -> { {low, online, inWorld}, ... } logged in by the sim
        sim["bots"] = [](sol::this_state s)
        {
            sol::state_view view(s);
            sol::table list = view.create_table();
            int n = 0;
            for (uint32 low : sBots)
            {
                Player* bot = ObjectAccessor::FindConnectedPlayer(PlayerGuid(low));
                sol::table row = view.create_table(0, 3);
                row["low"] = low;
                row["online"] = bot != nullptr;
                row["inWorld"] = bot && bot->IsInWorld();
                list[++n] = row;
            }

            return list;
        };

        // group(leaderLow, {lows}) -> ok, reason, members. Members leave other groups first.
        sim["group"] = [](uint32 leaderLow, sol::table lows) -> std::tuple<bool, std::string, uint32>
        {
            if (!SimCall())
                return { false, "wrong_thread", 0 };

            Player* leader = SimBot(leaderLow);
            if (!leader)
                return { false, "bad_bot", 0 };

            Group* group = leader->GetGroup();
            if (group && group->GetLeaderGUID() != leader->GetGUID())
            {
                LeaveGroup(leader);
                group = leader->GetGroup();
            }

            if (!group)
            {
                group = new Group();
                if (!group->Create(leader))
                {
                    delete group;
                    return { false, "failed", 0 };
                }

                sGroupMgr->AddGroup(group);
            }

            for (size_t i = 1; i <= 40; ++i)
            {
                sol::object value = lows[i];
                if (value.get_type() != sol::type::number)
                    break;

                Player* member = SimBot(value.as<uint32>());
                if (!member || member == leader || member->GetGroup() == group)
                    continue;

                LeaveGroup(member);
                if (!group->isRaidGroup() && group->GetMembersCount() >= 5)
                    group->ConvertToRaid();

                group->AddMember(member);
            }

            return { true, "ok", group->GetMembersCount() };
        };

        // ungroup(low): disband the bot's group.
        sim["ungroup"] = [](uint32 low) -> OkReason
        {
            if (!SimCall())
                return Fail("wrong_thread");

            Player* bot = SimBot(low);
            if (!bot)
                return Fail("bad_bot");

            if (Group* group = bot->GetGroup())
                group->Disband();

            return Ok();
        };

        // selfMaster(low[, on = true]): the bot becomes its own master (selfbot, like ".playerbots bot self"),
        // so group members pick it as master and tactics treat it as the owner (design 3).
        sim["selfMaster"] = [](uint32 low, sol::optional<bool> on) -> OkReason
        {
            if (!SimCall())
                return Fail("wrong_thread");

            PlayerbotAI* ai = nullptr;
            Player* bot = SimBot(low, &ai);
            if (!bot)
                return Fail("bad_bot");

            ai->SetMaster(on.value_or(true) ? bot : nullptr);
            ai->ResetStrategies();
            return Ok();
        };

        // asLeader(leaderLow, fn) -> true, <first result of fn> | false, reason | false, <Lua error text>
        // Runs fn() with this sim call's anchor set to the leader: MessagePlayer() is the leader inside fn, so
        // bot:inventory(), bot:applyTalents(), tactics.on_message(...) etc. run their normal message-player
        // path with the leader as the requesting player (party window self-test, sim/selftest.lua). Allowed
        // only in a sim entry call without an anchor (not nested), for a bot of sBots in the world that is
        // its own master (wow.sim.selfMaster). Reasons: wrong_thread, busy (nested), bad_bot, not_selfbot.
        sim["asLeader"] = [](uint32 low, sol::protected_function fn, sol::this_state s) -> std::tuple<bool, sol::object>
        {
            auto fail = [&s](std::string const& reason)
            {
                return std::tuple<bool, sol::object>(false, sol::make_object(s, reason));
            };

            Lua::CallContext* call = Lua::CurrentCall();
            if (!SimCall())
                return fail("wrong_thread");

            if (call->anchor || sAnchorLow)
                return fail("busy");

            Player* leader = SimBot(low);
            if (!leader || leader->IsBeingTeleported())
                return fail("bad_bot");

            if (!::IsSelfBot(leader))
                return fail("not_selfbot");

            sol::object value = sol::make_object(s, sol::lua_nil);
            std::string error;
            {
                AnchorScope scope(call, leader, low);
                sol::protected_function_result result = fn();
                if (!result.valid())
                {
                    sol::error err = result;
                    error = err.what();
                }
                else if (result.return_count() > 0)
                    value = result.get<sol::object>(0);
            }

            if (!error.empty())
                return fail(error);

            return { true, value };
        };

        // strategy(low, "co" | "nc" | "dead", "+a,-b")
        sim["strategy"] = [](uint32 low, std::string const& state, std::string const& names) -> OkReason
        {
            if (!SimCall())
                return Fail("wrong_thread");

            PlayerbotAI* ai = nullptr;
            if (!SimBot(low, &ai))
                return Fail("bad_bot");

            BotState botState = BOT_STATE_NON_COMBAT;
            if (!ParseState(state, botState) || !PlainText(names, 200))
                return Fail("bad_arg");

            ai->ChangeStrategy(names, botState);
            return Ok();
        };

        // strategies(low, state) -> { names }
        sim["strategies"] = [](uint32 low, std::string const& state, sol::this_state s)
        {
            sol::state_view view(s);
            sol::table list = view.create_table();
            PlayerbotAI* ai = nullptr;
            BotState botState = BOT_STATE_NON_COMBAT;
            if (!SimCall() || !BotInWorld(low, &ai) || !ParseState(state, botState))
                return list;

            int n = 0;
            for (std::string const& name : ai->GetStrategies(botState))
                list[++n] = name;

            return list;
        };

        // teleport(low, map, x, y, z, o): GM-mode teleport (no instance limits / access requirements).
        sim["teleport"] = [](uint32 low, uint32 mapId, double x, double y, double z, sol::optional<double> o) -> OkReason
        {
            if (!SimCall())
                return Fail("wrong_thread");

            Player* bot = SimBot(low);
            if (!bot)
                return Fail("bad_bot");

            if (bot->IsBeingTeleported())
                return Fail("teleporting");

            if (!sMapStore.LookupEntry(mapId) || !std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z))
                return Fail("bad_arg");

            float const orientation = (o && std::isfinite(*o)) ? float(*o) : 0.0f;
            return bot->TeleportTo(mapId, float(x), float(y), float(z), orientation, TELE_TO_GM_MODE) ? Ok() : Fail("failed");
        };

        // summon(low, entry, x, y, z, o[, {faction, react, despawnMs}]) -> guidHex | nil, reason
        sim["summon"] = [](uint32 low, uint32 entry, double x, double y, double z, double o, sol::optional<sol::table> opts,
                           sol::this_state s)
        {
            sol::variadic_results results;
            auto fail = [&](char const* reason)
            {
                results.push_back(sol::make_object(s, sol::lua_nil));
                results.push_back(sol::make_object(s, std::string(reason)));
                return results;
            };

            if (!SimCall())
                return fail("wrong_thread");

            Player* bot = SimBot(low);
            if (!bot)
                return fail("bad_bot");

            if (!sObjectMgr->GetCreatureTemplate(entry))
                return fail("bad_entry");

            if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z) || !std::isfinite(o))
                return fail("bad_arg");

            uint32 faction = 0, react = 3, despawnMs = 0;
            if (opts)
            {
                faction = opts->get_or("faction", 0u);
                react = opts->get_or("react", 3u);
                despawnMs = opts->get_or("despawnMs", 0u);
            }

            TempSummonType const type = despawnMs ? TEMPSUMMON_TIMED_DESPAWN : TEMPSUMMON_MANUAL_DESPAWN;
            TempSummon* summon = bot->SummonCreature(entry, float(x), float(y), float(z), float(o), type, despawnMs);
            if (!summon)
                return fail("failed");

            if (faction)
                summon->SetFaction(faction);

            if (react <= uint32(REACT_AGGRESSIVE))
                summon->SetReactState(ReactStates(react));

            results.push_back(sol::make_object(s, GuidToHex(Track(summon, true))));
            return results;
        };

        // find(low, {entries}, radius) -> { guidHex } of live creatures near the bot (tracked, never despawned)
        sim["find"] = [](uint32 low, sol::table entries, float radius, sol::this_state s)
        {
            sol::state_view view(s);
            sol::table list = view.create_table();
            Player* bot = SimCall() ? SimBot(low) : nullptr;
            if (!bot || !(radius > 0.0f))
                return list;

            std::vector<uint32> ids;
            for (size_t i = 1; i <= 32; ++i)
            {
                sol::object value = entries[i];
                if (value.get_type() != sol::type::number)
                    break;
                ids.push_back(value.as<uint32>());
            }

            if (ids.empty())
                return list;

            std::list<Creature*> found;
            bot->GetCreatureListWithEntryInGrid(found, ids, std::min(radius, MAX_FIND_RADIUS));
            int n = 0;
            for (Creature* creature : found)
            {
                if (!creature->IsAlive())
                    continue;

                list[++n] = GuidToHex(Track(creature, false));
            }

            return list;
        };

        // creature(guidHex) -> { alive, hp, maxHp, hpPct, inCombat, entry, x, y, z } | nil (gone / not tracked)
        sim["creature"] = [](std::string const& hex, sol::this_state s) -> sol::object
        {
            ObjectGuid guid;
            Creature* creature = (SimCall() && HexToGuid(hex, guid)) ? TrackedCreatureOf(guid) : nullptr;
            if (!creature || !creature->IsInWorld())
                return sol::make_object(s, sol::lua_nil);

            sol::state_view view(s);
            sol::table t = view.create_table(0, 9);
            t["alive"] = creature->IsAlive();
            t["hp"] = double(creature->GetHealth());
            t["maxHp"] = double(creature->GetMaxHealth());
            t["hpPct"] = double(creature->GetHealthPct());
            t["inCombat"] = creature->IsInCombat();
            t["entry"] = creature->GetEntry();
            t["x"] = creature->GetPositionX();
            t["y"] = creature->GetPositionY();
            t["z"] = creature->GetPositionZ();
            t["guid"] = GuidToHex(creature->GetGUID());   // the real guid (the tracking key carries the instance id)
            return t;
        };

        // spawns(mapId, {entries}, x, y, radius) -> { {entry, x, y, z, o, spawnId, spawnMask} } (tactics-round2-spec
        // 7.2): the creature spawn rows (acore_world.creature, as loaded by ObjectMgr) of that map whose entry
        // (id1, id2 or id3) is listed and whose 2D distance to (x, y) is <= radius (capped at MAX_FIND_RADIUS),
        // at most MAX_SPAWN_ROWS rows. Pure read of the static spawn data, no world access.
        sim["spawns"] = [](uint32 mapId, sol::table entries, double x, double y, double radius, sol::this_state s)
        {
            sol::state_view view(s);
            sol::table list = view.create_table();
            if (!SimCall() || !std::isfinite(x) || !std::isfinite(y) || !std::isfinite(radius) || !(radius > 0.0))
                return list;

            std::set<uint32> ids;
            for (size_t i = 1; i <= 32; ++i)
            {
                sol::object value = entries[i];
                if (value.get_type() != sol::type::number)
                    break;
                ids.insert(value.as<uint32>());
            }

            if (ids.empty())
                return list;

            double const r = std::min(radius, double(MAX_FIND_RADIUS));
            int n = 0;
            for (auto const& [spawnId, data] : sObjectMgr->GetAllCreatureData())
            {
                if (data.mapid != mapId)
                    continue;

                uint32 entry = 0;
                if (ids.count(data.id))
                    entry = data.id;
                else if (data.id2 && ids.count(data.id2))
                    entry = data.id2;
                else if (data.id3 && ids.count(data.id3))
                    entry = data.id3;

                if (!entry)
                    continue;

                double const dx = double(data.posX) - x;
                double const dy = double(data.posY) - y;
                if (dx * dx + dy * dy > r * r)
                    continue;

                sol::table row = view.create_table(0, 7);
                row["entry"] = entry;
                row["x"] = data.posX;
                row["y"] = data.posY;
                row["z"] = data.posZ;
                row["o"] = data.orientation;
                row["spawnId"] = uint32(spawnId);
                row["spawnMask"] = uint32(data.spawnMask);
                list[++n] = row;
                if (n >= int(MAX_SPAWN_ROWS))
                    break;
            }

            return list;
        };

        // despawn(guidHex[, force]): unsummons creatures of wow.sim.summon; forgets natives of wow.sim.find.
        // force = true also removes a native (DespawnOrUnsummon: it respawns on its own spawn timer) - the
        // `clear` of a realistic scenario (tactics-round2-spec 5.1). Returns true when the key was tracked.
        sim["despawn"] = [](std::string const& hex, sol::optional<bool> force)
        {
            ObjectGuid guid;
            if (!SimCall() || !HexToGuid(hex, guid) || !sCreatures.count(guid))
                return false;

            if (force && *force)
            {
                TrackedCreature const* info = nullptr;
                Creature* creature = TrackedCreatureOf(guid, &info);
                if (creature && info && !info->summoned && creature->IsAlive() && !creature->ToTempSummon())
                    creature->DespawnOrUnsummon();
            }

            DespawnTracked(guid);
            return true;
        };

        // restore(low): see Restore() above.
        sim["restore"] = [](uint32 low) -> OkReason
        {
            if (!SimCall())
                return Fail("wrong_thread");

            Player* bot = SimBot(low);
            if (!bot)
                return Fail("bad_bot");

            if (bot->IsBeingTeleported())
                return Fail("teleporting");

            Restore(bot);
            return Ok();
        };

        // noXp(low, on): PLAYER_FLAGS_NO_XP_GAIN
        sim["noXp"] = [](uint32 low, bool on) -> OkReason
        {
            if (!SimCall())
                return Fail("wrong_thread");

            Player* bot = SimBot(low);
            if (!bot)
                return Fail("bad_bot");

            if (on)
                bot->SetPlayerFlag(PLAYER_FLAGS_NO_XP_GAIN);
            else
                bot->RemovePlayerFlag(PLAYER_FLAGS_NO_XP_GAIN);

            return Ok();
        };

        // mark(leaderLow, index 0..7, guidHex | nil): raid target icon of the leader's group (7 = skull).
        sim["mark"] = [](uint32 leaderLow, uint32 index, sol::optional<std::string> hex) -> OkReason
        {
            if (!SimCall())
                return Fail("wrong_thread");

            Player* leader = SimBot(leaderLow);
            Group* group = leader ? leader->GetGroup() : nullptr;
            if (!group)
                return Fail("no_group");

            ObjectGuid target;
            if (index >= TARGETICONCOUNT || (hex && !HexToGuid(*hex, target)))
                return Fail("bad_arg");

            // a tracked creature's key -> its real GUID
            auto itr = sCreatures.find(target);
            if (itr != sCreatures.end())
                target = itr->second.guid;

            group->SetTargetIcon(uint8(index), leader->GetGUID(), target);
            return Ok();
        };

        // factory(low, level, quality): PlayerbotFactory(bot, level, quality).Randomize(false) - level, talents,
        // gear, spells, consumables, as ".playerbots bot init". Slow; call once per scenario preparation.
        sim["factory"] = [](uint32 low, uint32 level, sol::optional<uint32> quality) -> OkReason
        {
            if (!SimCall())
                return Fail("wrong_thread");

            Player* bot = SimBot(low);
            if (!bot)
                return Fail("bad_bot");

            if (bot->IsInCombat() || bot->IsBeingTeleported())
                return Fail("busy");

            uint32 const maxLevel = sWorld->getIntConfig(CONFIG_MAX_PLAYER_LEVEL);
            if (level < 1 || level > maxLevel)
                return Fail("bad_arg");

            uint32 const itemQuality = std::min<uint32>(quality.value_or(ITEM_QUALITY_RARE), ITEM_QUALITY_LEGENDARY);
            PlayerbotFactory factory(bot, level, itemQuality);
            factory.Randomize(false);
            return bot->GetLevel() == level ? Ok() : Fail("verify");
        };

        sim["fileWrite"] = [](std::string const& name, std::string const& text) -> OkReason
        {
            return SimCall() ? WriteFile(name, text, false) : Fail("wrong_thread");
        };
        sim["fileAppend"] = [](std::string const& name, std::string const& text) -> OkReason
        {
            return SimCall() ? WriteFile(name, text, true) : Fail("wrong_thread");
        };
        sim["dir"] = []() { return OutputDir().generic_string(); };

        // stamp() -> "yyyymmdd_hhmmss" (server local time), for file names
        sim["stamp"] = []()
        {
            std::tm const tm = Acore::Time::TimeBreakdown(std::time(nullptr));
            return Acore::StringFormat("{:04}{:02}{:02}_{:02}{:02}{:02}", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                                       tm.tm_hour, tm.tm_min, tm.tm_sec);
        };

        // cleanup() -> bots logged out, creatures despawned. Stops the pump and clears all metrics.
        // Works from any driver state (also after a script reload lost the Lua-side run).
        sim["cleanup"] = []() -> std::tuple<uint32, uint32>
        {
            if (!SimCall() || sAnchorLow)
                return { 0, 0 };

            uint32 creatures = 0;
            std::vector<ObjectGuid> guids;
            for (auto const& [guid, info] : sCreatures)
                guids.push_back(guid);

            for (ObjectGuid const& guid : guids)
            {
                if (sCreatures[guid].summoned)
                    ++creatures;

                DespawnTracked(guid);
            }

            uint32 bots = 0;
            std::set<uint32> const lows = sBots;
            for (uint32 low : lows)
            {
                ObjectGuid const guid = PlayerGuid(low);
                Player* bot = sRandomPlayerbotMgr.GetPlayerBot(guid);
                if (bot)
                {
                    if (bot->IsInWorld())
                    {
                        bot->RemovePlayerFlag(PLAYER_FLAGS_NO_XP_GAIN);
                        LeaveGroup(bot);
                    }

                    if (PlayerbotAI* ai = GET_PLAYERBOT_AI(bot))
                        ai->SetMaster(nullptr);

                    sRandomPlayerbotMgr.LogoutPlayerBot(guid);
                    ++bots;
                }

                sBots.erase(low);
            }

            sActive = false;
            Metrics::Clear();
            return { bots, creatures };
        };

        wow["sim"] = sim;
    }
}

void AddTacticsSimScripts()
{
    new Tactics::Sim::TacticsSimWorldScript();
}
