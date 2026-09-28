/*
 * Bot tactics - party window Lua bindings of package P2:
 * bot lifecycle, chat commands, strategies, talents and the AI stages 0-1 runtime (veto, wake, trace).
 *
 * Thin pass-throughs to TacticsBots.cpp and the per-bot runtime (TacticsAction). Handles are resolved
 * on every call (ResolvePlayerbot). Ownership is re-checked here for every mutating call (spec rules):
 *   - world-thread message calls: the message player must be GetOwner(bot) (bot:command also accepts
 *     the bot's playerbots master; lifecycle functions take the message player's own guid);
 *   - map-thread evaluate calls: only the evaluated bot itself (command, setVeto, vetoTarget, wake).
 */

#include "TacticsBots.h"
#include "TacticsEngine.h"
#include "TacticsLua.h"

#include "DBCStructure.h"
#include "Player.h"
#include "Playerbots.h"
#include "Timer.h"
#include "Util.h"

#include "TacticsPartyApi.h"

#include <cmath>
#include <optional>
#include <tuple>

namespace Tactics::Lua
{
    namespace
    {
        using sol::lua_nil;

        constexpr size_t MAX_VETO = 64;           // Lua caps at VETO_MAX (40)
        constexpr size_t MAX_VETO_NAME = 64;
        constexpr size_t MAX_BUILD = 128;         // entries of one talent build
        constexpr size_t MAX_MANUAL_KEEP = 32;    // strategy names of one bot:setManual keep list

        using OkReason = std::tuple<bool, std::string>;

        OkReason Pair(Party::AiResult const& result)
        {
            return { result.ok, result.reason };
        }

        // Spec 2.1 OwnedBot: the world-thread message player must own the bot.
        char const* OwnedBot(UnitHandle const& h, Player*& bot, PlayerbotAI*& ai)
        {
            bot = nullptr;
            ai = nullptr;
            Player* requester = MessagePlayer();
            if (!requester)
                return "wrong_thread";

            Player* resolved = ResolvePlayerbot(h, ai);
            if (!resolved || !resolved->IsInWorld() || GetOwner(resolved) != requester)
                return "bad_bot";

            bot = resolved;
            return nullptr;
        }

        // Runtime settings (veto, wake): the owner from a message, or the bot itself from its evaluate.
        TacticsAction* ControlledRuntime(UnitHandle const& h)
        {
            CallContext* call = CurrentCall();
            PlayerbotAI* ai = nullptr;
            Player* bot = ResolvePlayerbot(h, ai);
            if (!call || !bot)
                return nullptr;

            if (Player* requester = MessagePlayer())
            {
                if (GetOwner(bot) != requester)
                    return nullptr;
            }
            else if (!call->map || call->anchor != bot)
                return nullptr;

            return GetRuntime(ai);
        }

        // lowercase like playerbots' spell action names (CastSpellAction::getSpell)
        std::string LowerName(std::string name)
        {
            std::wstring wname;
            if (Utf8toWStr(name, wname))
            {
                wstrToLower(wname);
                WStrToUtf8(wname, name);
            }

            return name;
        }

        bool IntField(sol::object const& value, uint32 max, uint32& out)
        {
            if (value.get_type() != sol::type::number)
                return false;

            double const n = value.as<double>();
            if (!std::isfinite(n) || n < 0.0 || n > double(max) || std::floor(n) != n)
                return false;

            out = uint32(n);
            return true;
        }

        // Only the message player's own guid is accepted as `playerLow` (spec 3.2).
        Player* Requester(uint32 playerLow)
        {
            Player* player = MessagePlayer();
            return (player && playerLow && player->GetGUID().GetCounter() == playerLow) ? player : nullptr;
        }

        template <typename T>
        sol::table ArrayOf(sol::state_view& lua, std::vector<T> const& values)
        {
            sol::table t = lua.create_table(int(values.size()), 0);
            for (size_t i = 0; i < values.size(); ++i)
                t[i + 1] = values[i];
            return t;
        }
    }

    void RegisterAiApi(sol::state_view& /*lua*/, sol::usertype<UnitHandle>& unit, sol::table& wow)
    {
        // ------------------------------------------------------------------ bots (2.7)
        unit["masterLow"] = [](UnitHandle const& h) -> uint32
        {
            PlayerbotAI* ai = nullptr;
            Player* bot = ResolvePlayerbot(h, ai);
            return bot ? Party::Master(bot) : 0;
        };

        unit["command"] = [](UnitHandle const& h, std::string const& text) -> OkReason
        {
            CallContext* call = CurrentCall();
            if (!call)
                return { false, "wrong_thread" };

            PlayerbotAI* ai = nullptr;
            Player* bot = ResolvePlayerbot(h, ai);
            if (!bot || !bot->IsInWorld())
                return { false, "bad_bot" };

            Player* requester = nullptr;
            if (Player* player = MessagePlayer())
            {
                // owner (group), or the master of an online bot outside the group
                if (GetOwner(bot) == player || Party::Master(bot) == player->GetGUID().GetCounter())
                    requester = player;
            }
            else if (call->map && call->anchor == bot)
            {
                // the bot re-applies its own persistent settings from evaluate (spec 5.8); the command
                // is queued as a whisper of its owner and runs on the bot's next tick
                requester = GetOwner(bot);
                if (!requester)
                    requester = ai->GetMaster();
            }

            if (!requester)
                return { false, "bad_bot" };

            return Pair(Party::Command(bot, requester, text));
        };

        // tactics-round2-spec 7.1: a party chat callout of the coordination layer (ai/coord.lua). Only from
        // the bot's own evaluate (map thread; SayToParty sends to the real players' sessions, as TellMaster
        // does from there) or from its owner's message. CHAT_MSG_PARTY to the real players of the group.
        unit["sayParty"] = [](UnitHandle const& h, std::string const& text) -> OkReason
        {
            CallContext* call = CurrentCall();
            if (!call)
                return { false, "wrong_thread" };

            PlayerbotAI* ai = nullptr;
            Player* bot = ResolvePlayerbot(h, ai);
            if (!bot || !ai || !bot->IsInWorld())
                return { false, "bad_bot" };

            if (Player* player = MessagePlayer())
            {
                if (GetOwner(bot) != player)
                    return { false, "bad_bot" };
            }
            else if (!call->map || call->anchor != bot)
                return { false, "bad_bot" };

            if (text.empty() || text.size() > 200 || text.find_first_of(std::string("|\n\r\0", 4)) != std::string::npos)
                return { false, "bad_arg" };

            if (!bot->GetGroup())
                return { false, "no_group" };

            if (!ai->SayToParty(text))
                return { false, "no_group" };

            return { true, "ok" };
        };

        unit["strategies"] = [](UnitHandle const& h, std::string const& list, sol::this_state s)
        {
            sol::state_view lua(s);
            std::vector<std::string> names;
            PlayerbotAI* ai = nullptr;
            Player* bot = ResolvePlayerbot(h, ai);
            if (bot && (list == "co" || list == "nc"))
                Party::Strategies(bot, list == "co" ? BOT_STATE_COMBAT : BOT_STATE_NON_COMBAT, names);

            return ArrayOf(lua, names);
        };

        wow["accountBots"] = [](uint32 playerLow, sol::this_state s)
        {
            sol::state_view lua(s);
            sol::table list = lua.create_table();
            Player* requester = Requester(playerLow);
            if (!requester)
                return list;

            std::vector<Party::BotRow> rows;
            Party::AccountBots(requester, rows);
            int n = 0;
            for (Party::BotRow const& row : rows)
            {
                sol::table entry = lua.create_table(0, 5);
                entry["guid"] = row.guidLow;
                entry["name"] = row.name;
                entry["class"] = uint32(row.cls);
                entry["level"] = uint32(row.level);
                entry["state"] = uint32(row.state);
                list[++n] = entry;
            }

            return list;
        };

        wow["botLogin"] = [](uint32 playerLow, uint32 botLow) -> OkReason
        {
            if (!MessagePlayer())
                return { false, "wrong_thread" };

            Player* requester = Requester(playerLow);
            if (!requester)
                return { false, "bad_bot" };

            return Pair(Party::BotLogin(requester, botLow));
        };

        wow["botLogout"] = [](uint32 playerLow, uint32 botLow) -> OkReason
        {
            if (!MessagePlayer())
                return { false, "wrong_thread" };

            Player* requester = Requester(playerLow);
            if (!requester)
                return { false, "bad_bot" };

            Party::AiResult const result = Party::BotLogout(requester, botLow);

            // the Player object is gone: drop it from this call's resolution cache
            if (CallContext* call = CurrentCall())
                call->cache.erase(ObjectGuid::Create<HighGuid::Player>(botLow));

            return Pair(result);
        };

        // ------------------------------------------------------------------ talents (2.8)
        wow["talents"] = [](uint32 cls, sol::this_state s)
        {
            sol::state_view lua(s);
            std::vector<Party::TalentRow> const& rows = Party::TalentRows(uint8(cls < 256 ? cls : 0));
            sol::table list = lua.create_table(int(rows.size()), 0);
            int n = 0;
            for (Party::TalentRow const& row : rows)
            {
                sol::table entry = lua.create_table(0, 8);
                entry["id"] = row.id;
                entry["tab"] = uint32(row.tab);
                entry["row"] = uint32(row.row);
                entry["col"] = uint32(row.col);
                entry["max"] = uint32(row.maxRank);
                entry["dep"] = row.dependsOn;
                entry["depRank"] = row.dependsOnRank;

                sol::table ranks = lua.create_table(int(row.maxRank), 0);
                for (uint8 r = 0; r < row.maxRank; ++r)
                    ranks[r + 1] = row.ranks[r];
                entry["ranks"] = ranks;

                list[++n] = entry;
            }

            return list;
        };

        unit["talentInfo"] = [](UnitHandle const& h, sol::this_state s) -> sol::object
        {
            PlayerbotAI* ai = nullptr;
            Player* bot = ResolvePlayerbot(h, ai);
            if (!bot)
                return sol::make_object(s, lua_nil);

            Party::TalentInfoOut const info = Party::TalentInfo(bot);
            sol::state_view lua(s);
            sol::table t = lua.create_table(0, 5);
            t["active"] = info.active;
            t["count"] = info.count;
            t["free"] = info.free;
            t["total"] = info.total;
            t["minDualLevel"] = info.minDualLevel;
            return t;
        };

        unit["talentRanks"] = [](UnitHandle const& h, sol::optional<uint32> spec, sol::this_state s)
        {
            sol::state_view lua(s);
            sol::table t = lua.create_table();
            PlayerbotAI* ai = nullptr;
            Player* bot = ResolvePlayerbot(h, ai);
            uint32 const which = spec ? *spec : 0;
            if (!bot || which > 2)
                return t;

            std::map<uint32, uint8> ranks;
            Party::TalentRanks(bot, uint8(which), ranks);
            for (auto const& [id, rank] : ranks)
                t[id] = uint32(rank);

            return t;
        };

        unit["applyTalents"] = [](UnitHandle const& h, sol::object build)
            -> std::tuple<bool, std::string, uint32, uint32, uint32>
        {
            Player* bot = nullptr;
            PlayerbotAI* ai = nullptr;
            if (char const* reason = OwnedBot(h, bot, ai))
                return { false, reason, 0, 0, 0 };

            std::array<uint32, 3> tabs = Party::TalentTabPoints(bot);
            auto fail = [&tabs](char const* reason) -> std::tuple<bool, std::string, uint32, uint32, uint32>
            {
                return { false, reason, tabs[0], tabs[1], tabs[2] };
            };

            if (build.get_type() != sol::type::table)
                return fail("bad_build");

            sol::table entries = build.as<sol::table>();
            size_t const count = entries.size();
            if (count > MAX_BUILD)
                return fail("bad_build");

            std::vector<std::array<uint32, 4>> parsed;
            parsed.reserve(count);
            for (size_t i = 1; i <= count; ++i)
            {
                sol::object item = entries.get<sol::object>(i);
                if (item.get_type() != sol::type::table)
                    return fail("bad_build");

                sol::table fields = item.as<sol::table>();
                std::array<uint32, 4> entry = { };
                uint32 const limits[4] = { 2, 15, 15, MAX_TALENT_RANK };   // tab, row, col, rank
                for (int f = 0; f < 4; ++f)
                    if (!IntField(fields.get<sol::object>(f + 1), limits[f], entry[f]))
                        return fail("bad_build");

                parsed.push_back(entry);
            }

            Party::AiResult const result = Party::ApplyTalents(bot, parsed, tabs);
            return { result.ok, result.reason, tabs[0], tabs[1], tabs[2] };
        };

        unit["activateSpec"] = [](UnitHandle const& h, uint32 spec) -> OkReason
        {
            Player* bot = nullptr;
            PlayerbotAI* ai = nullptr;
            if (char const* reason = OwnedBot(h, bot, ai))
                return { false, reason };

            return Pair(Party::ActivateSpec(bot, uint8(spec <= 2 ? spec : 0)));
        };

        // ok, reason [, required level when reason == "level"]
        unit["learnDualSpec"] = [](UnitHandle const& h) -> std::tuple<bool, std::string, int32>
        {
            Player* bot = nullptr;
            PlayerbotAI* ai = nullptr;
            if (char const* reason = OwnedBot(h, bot, ai))
                return { false, reason, 0 };

            Party::AiResult const result = Party::LearnDualSpec(bot);
            return { result.ok, result.reason, result.a };
        };

        // ------------------------------------------------------------------ AI stages 0-1 (2.9)
        // list = array of { spell = <enGB name>, only = bool }; replaces the set, targets start empty.
        unit["setVeto"] = [](UnitHandle const& h, sol::object list) -> OkReason
        {
            TacticsAction* rt = ControlledRuntime(h);
            if (!rt)
                return { false, "bad_bot" };

            if (list.get_type() != sol::type::table)
                return { false, "bad_spell" };

            sol::table entries = list.as<sol::table>();
            size_t const count = entries.size();
            if (count > MAX_VETO)
                return { false, "too_many" };

            std::vector<TacticsAction::VetoEntry> veto;
            veto.reserve(count);
            for (size_t i = 1; i <= count; ++i)
            {
                sol::object item = entries.get<sol::object>(i);
                if (item.get_type() != sol::type::table)
                    return { false, "bad_spell" };

                sol::table fields = item.as<sol::table>();
                sol::object spell = fields.get<sol::object>("spell");
                sol::object only = fields.get<sol::object>("only");
                if (spell.get_type() != sol::type::string)
                    return { false, "bad_spell" };

                TacticsAction::VetoEntry entry;
                entry.spell = LowerName(spell.as<std::string>());
                entry.only = only.get_type() == sol::type::boolean && only.as<bool>();
                if (entry.spell.empty() || entry.spell.size() > MAX_VETO_NAME)
                    return { false, "bad_spell" };

                veto.push_back(std::move(entry));
            }

            rt->veto = std::move(veto);
            return { true, "ok" };
        };

        // Refreshes the target of an "only" entry; guidHex nil clears it. Returns true when an entry matched.
        unit["vetoTarget"] = [](UnitHandle const& h, std::string const& spell, sol::optional<std::string> guidHex)
        {
            TacticsAction* rt = ControlledRuntime(h);
            if (!rt || rt->veto.empty())
                return false;

            ObjectGuid target;
            if (guidHex && !HexToGuid(*guidHex, target))
                return false;

            std::string const name = LowerName(spell);
            uint32 const now = getMSTime();
            bool found = false;
            for (TacticsAction::VetoEntry& entry : rt->veto)
            {
                if (!entry.only || entry.spell != name)
                    continue;

                entry.target = target;
                entry.targetAt = now;
                found = true;
            }

            return found;
        };

        unit["wake"] = [](UnitHandle const& h, bool on)
        {
            TacticsAction* rt = ControlledRuntime(h);
            if (!rt)
                return false;

            rt->wake = on;
            return true;
        };

        // abilities-mirroring-spec 3.2: manual mode ("only my rules"). keep = nil: the class AI also keeps the
        // strategies of Tactics.ManualKeepOptional (potions, racials); keep = array of strategy names: those
        // instead ({} = strict). Tactics.ManualKeepStrategies, mechanics and "tactics" are always kept.
        unit["setManual"] = [](UnitHandle const& h, bool on, sol::object keep) -> OkReason
        {
            TacticsAction* rt = ControlledRuntime(h);
            if (!rt)
                return { false, "bad_bot" };

            std::optional<std::vector<std::string>> names;
            if (keep.get_type() == sol::type::table)
            {
                sol::table entries = keep.as<sol::table>();
                size_t const count = entries.size();
                if (count > MAX_MANUAL_KEEP)
                    return { false, "too_many" };

                names.emplace();
                for (size_t i = 1; i <= count; ++i)
                {
                    sol::object item = entries.get<sol::object>(i);
                    if (item.get_type() != sol::type::string)
                        return { false, "bad_arg" };

                    std::string name = item.as<std::string>();
                    if (name.empty() || name.size() > MAX_VETO_NAME)
                        return { false, "bad_arg" };

                    names->push_back(std::move(name));
                }
            }
            else if (keep.get_type() != sol::type::lua_nil && keep.get_type() != sol::type::none)
                return { false, "bad_arg" };

            if (rt->manual != on || rt->manualKeep != names)
                rt->ResetManualCache();

            rt->manual = on;
            rt->manualKeep = std::move(names);
            return { true, "ok" };
        };

        // abilities-mirroring-spec 4.1: false = this bot does not copy its owner's flights (playerbots actions
        // "taxi" / "remember taxi" are zeroed by the manual-mode multiplier). Default true (not persistent).
        unit["setTaxiMirror"] = [](UnitHandle const& h, bool on)
        {
            TacticsAction* rt = ControlledRuntime(h);
            if (!rt)
                return false;

            rt->mirrorTaxiOff = !on;
            return true;
        };

        // bool (manual mode currently on for this bot's runtime)
        unit["manual"] = [](UnitHandle const& h)
        {
            PlayerbotAI* ai = nullptr;
            Player* bot = ResolvePlayerbot(h, ai);
            TacticsAction* rt = bot ? GetRuntime(ai) : nullptr;
            return rt && rt->manual;
        };

        unit["trace"] = [](UnitHandle const& h, sol::this_state s)
        {
            sol::state_view lua(s);
            sol::table list = lua.create_table();
            PlayerbotAI* ai = nullptr;
            Player* bot = ResolvePlayerbot(h, ai);
            TacticsAction* rt = bot ? GetRuntime(ai) : nullptr;
            if (!rt)
                return list;

            int n = 0;
            for (TraceEntry const& entry : rt->trace->entries)
            {
                sol::table t = lua.create_table(0, 5);
                t["at"] = entry.at;
                t["name"] = entry.name;
                t["ok"] = entry.ok;
                if (entry.target)
                    t["target"] = GuidToHex(entry.target);
                t["relevance"] = entry.relevance;
                list[++n] = t;
            }

            return list;
        };
    }
}
