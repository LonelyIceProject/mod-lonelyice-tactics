/*
 * Bot tactics - party window Lua bindings, package P1 (spec 3.1): bot:inventory, bot:itemAction,
 * bot:sellGrey, bot:stats, bot:trainerSpells, bot:trainerLearnAll, bot:quests, bot:dropQuest.
 *
 * Thin conversions between TacticsInventory.h rows and Lua tables. Ownership: every binding except
 * stats() and quests() (read-only facts) requires a world-thread message call whose player owns the
 * bot (Party::CheckOwned); the primitives re-check it themselves.
 *
 *
 */

#include "TacticsInventory.h"
#include "TacticsPartyApi.h"

#include "Player.h"

#include <tuple>

namespace Tactics::Lua
{
    namespace
    {
        using sol::lua_nil;

        // Spec 2.1 OwnedBot: wrong_thread / bad_bot, else nullptr with bot set.
        char const* OwnedBot(UnitHandle const& h, Player*& bot)
        {
            bot = nullptr;
            if (!MessagePlayer())
                return "wrong_thread";

            PlayerbotAI* ai = nullptr;
            bot = ResolvePlayerbot(h, ai);
            if (!bot)
                return "bad_bot";

            return Party::CheckOwned(bot);
        }

        using ResultTuple = std::tuple<bool, std::string, int32, int32>;

        ResultTuple ToTuple(Party::InvResult const& r)
        {
            return { r.ok, r.reason, r.a, r.b };
        }

        sol::variadic_results NilReason(sol::this_state s, char const* reason)
        {
            sol::variadic_results results;
            results.push_back(sol::make_object(s, lua_nil));
            results.push_back(sol::make_object(s, std::string(reason)));
            return results;
        }
    }

    void RegisterPartyApi(sol::state_view& /*lua*/, sol::usertype<UnitHandle>& unit, sol::table& /*wow*/)
    {
        // { money, flags, containers = {...}, items = {...} } or nil, reason
        unit["inventory"] = [](UnitHandle const& h, sol::this_state s)
        {
            Player* bot = nullptr;
            if (char const* reason = OwnedBot(h, bot))
                return NilReason(s, reason);

            Party::SnapshotOut snap;
            Party::InvResult const r = Party::Snapshot(bot, snap);
            if (!r.ok)
                return NilReason(s, r.reason);

            sol::state_view lua(s);
            sol::table t = lua.create_table(0, 4);
            t["money"] = snap.money;
            t["flags"] = snap.flags;

            sol::table containers = lua.create_table(int(snap.containers.size()), 0);
            int n = 0;
            for (Party::ContainerRow const& c : snap.containers)
            {
                sol::table row = lua.create_table(0, 5);
                row["kind"] = std::string(1, c.kind);
                row["bag"] = uint32(c.bag);
                row["start"] = uint32(c.start);
                row["size"] = uint32(c.size);
                row["entry"] = c.entry;
                containers[++n] = row;
            }
            t["containers"] = containers;

            sol::table items = lua.create_table(int(snap.items.size()), 0);
            n = 0;
            for (Party::ItemRow const& i : snap.items)
            {
                sol::table row = lua.create_table(0, 15);
                row["bag"] = uint32(i.bag);
                row["slot"] = uint32(i.slot);
                row["guid"] = i.guidLow;
                row["entry"] = i.entry;
                row["count"] = i.count;
                row["ench"] = i.enchant;
                row["gem1"] = i.gem[0];
                row["gem2"] = i.gem[1];
                row["gem3"] = i.gem[2];
                row["rprop"] = i.randomProperty;
                row["suffix"] = i.suffixFactor;
                row["dur"] = i.durability;
                row["maxdur"] = i.maxDurability;
                row["flags"] = i.flags;
                row["fits"] = i.fits;
                items[++n] = row;
            }
            t["items"] = items;

            sol::variadic_results results;
            results.push_back(sol::make_object(s, t));
            return results;
        };

        // ok, reason, a, b
        unit["itemAction"] = [](UnitHandle const& h, std::string const& op, uint32 bag, uint32 slot, uint32 guid,
                                sol::optional<uint32> a, sol::optional<uint32> b) -> ResultTuple
        {
            Player* bot = nullptr;
            if (char const* reason = OwnedBot(h, bot))
                return { false, reason, 0, 0 };

            if (bag > 255 || slot > 255)
                return { false, "bad_pos", 0, 0 };

            return ToTuple(Party::ItemAction(bot, op, uint8(bag), uint8(slot), guid, a ? *a : 0, b ? *b : 0));
        };

        // ok, reason, sold stacks, money gained
        unit["sellGrey"] = [](UnitHandle const& h) -> ResultTuple
        {
            Player* bot = nullptr;
            if (char const* reason = OwnedBot(h, bot))
                return { false, reason, 0, 0 };

            return ToTuple(Party::SellGrey(bot));
        };

        // key -> number, or nil when the handle is not an online playerbot
        unit["stats"] = [](UnitHandle const& h, sol::this_state s) -> sol::object
        {
            PlayerbotAI* ai = nullptr;
            Player* bot = ResolvePlayerbot(h, ai);
            if (!bot)
                return sol::make_object(s, lua_nil);

            std::map<std::string, double> values;
            Party::Stats(bot, values);

            sol::state_view lua(s);
            sol::table t = lua.create_table(0, int(values.size()));
            for (auto const& [key, value] : values)
                t[key] = value;
            return t;
        };

        // rows, reason (nil on success), trainer name (in the calling player's locale)
        unit["trainerSpells"] = [](UnitHandle const& h, sol::this_state s)
        {
            sol::state_view lua(s);
            sol::variadic_results results;
            Player* bot = nullptr;
            std::vector<Party::TrainerSpellRow> rows;
            std::string name;
            char const* reason = OwnedBot(h, bot);
            if (!reason)
            {
                Party::InvResult const r = Party::TrainerSpells(bot, rows, &name);
                if (!r.ok)
                    reason = r.reason;
            }

            sol::table list = lua.create_table(int(rows.size()), 0);
            int n = 0;
            for (Party::TrainerSpellRow const& row : rows)
            {
                sol::table entry = lua.create_table(0, 3);
                entry["spell"] = row.spell;
                entry["cost"] = row.cost;
                entry["canLearn"] = row.canLearn;
                list[++n] = entry;
            }

            results.push_back(sol::make_object(s, list));
            results.push_back(reason ? sol::make_object(s, std::string(reason)) : sol::make_object(s, lua_nil));
            results.push_back(reason ? sol::make_object(s, lua_nil) : sol::make_object(s, name));
            return results;
        };

        // ok, reason, learned, money spent
        unit["trainerLearnAll"] = [](UnitHandle const& h) -> ResultTuple
        {
            Player* bot = nullptr;
            if (char const* reason = OwnedBot(h, bot))
                return { false, reason, 0, 0 };

            return ToTuple(Party::TrainerLearnAll(bot));
        };

        // array of { id, level, complete, title }
        unit["quests"] = [](UnitHandle const& h, sol::this_state s)
        {
            sol::state_view lua(s);
            PlayerbotAI* ai = nullptr;
            Player* bot = ResolvePlayerbot(h, ai);
            std::vector<Party::QuestRow> rows;
            if (bot)
                Party::Quests(bot, rows);

            sol::table list = lua.create_table(int(rows.size()), 0);
            int n = 0;
            for (Party::QuestRow const& row : rows)
            {
                sol::table entry = lua.create_table(0, 4);
                entry["id"] = row.id;
                entry["level"] = row.level;
                entry["complete"] = row.complete;
                entry["title"] = row.title;
                list[++n] = entry;
            }

            return list;
        };

        // ok, reason
        unit["dropQuest"] = [](UnitHandle const& h, uint32 questId) -> std::tuple<bool, std::string>
        {
            Player* bot = nullptr;
            if (char const* reason = OwnedBot(h, bot))
                return { false, reason };

            Party::InvResult const r = Party::DropQuest(bot, questId);
            return { r.ok, r.reason };
        };
    }
}
