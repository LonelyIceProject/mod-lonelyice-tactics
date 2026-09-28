/*
 * Bot tactics - party window extras, Lua bindings (party-extras-spec section 3): wow.premadeSpecs,
 * bot:reputations, bot:skills, bot:glyphs, bot:glyphApply, bot:glyphRemove, bot:vendorItems, bot:vendorBuy,
 * bot:buyback, bot:buybackBuy, bot:rewardedQuests.
 *
 * Thin conversions between TacticsExtras.h rows and Lua tables. Every bot method requires a world-thread
 * message call whose player owns the bot (OwnedBot: wrong_thread / bad_bot / Party::CheckOwned); the
 * primitives re-check it themselves. Listings return nil as the reason on success (trainerSpells contract).
 *
 *
 */

#include "TacticsExtras.h"
#include "TacticsPartyApi.h"

#include "Player.h"

#include <tuple>

namespace Tactics::Lua
{
    namespace
    {
        using sol::lua_nil;

        // Spec 2.1 (party-window) OwnedBot: wrong_thread / bad_bot, else nullptr with bot set.
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

        // Out-of-range integers become 254: never a glyph socket, a bag (INVENTORY_SLOT_BAG_0 is 255)
        // nor a carried slot, so the primitive answers with its own reason (bad_pos / stale) in its
        // own check order. 255 itself is kept: it is the backpack.
        uint8 Byte(uint32 value)
        {
            return value > 255 ? uint8(254) : uint8(value);
        }

        sol::object Reason(sol::this_state s, char const* reason)
        {
            return reason ? sol::make_object(s, std::string(reason)) : sol::make_object(s, lua_nil);
        }

        // rows, reason (nil on success)
        sol::variadic_results RowsReason(sol::this_state s, sol::table rows, char const* reason)
        {
            sol::variadic_results results;
            results.push_back(sol::make_object(s, rows));
            results.push_back(Reason(s, reason));
            return results;
        }
    }

    void RegisterExtrasApi(sol::state_view& /*lua*/, sol::usertype<UnitHandle>& unit, sol::table& wow)
    {
        // array of { no, name, glyphItems = {entry,...}, entries = { {tab,row,col,rank}, ... } }; {} for bad input.
        // Config only: no bot, no ownership.
        wow["premadeSpecs"] = [](sol::object cls, sol::object level, sol::this_state s) -> sol::table
        {
            sol::state_view lua(s);
            std::vector<Party::PremadeSpec> specs;
            if (cls.get_type() == sol::type::number && level.get_type() == sol::type::number)
            {
                double const c = cls.as<double>();
                double const l = level.as<double>();
                if (c >= 1 && c <= 255 && l >= 1 && l <= 255)
                    Party::PremadeSpecs(uint8(c), uint8(l), specs);   // the primitive range-checks class and level
            }

            sol::table list = lua.create_table(int(specs.size()), 0);
            int n = 0;
            for (Party::PremadeSpec const& spec : specs)
            {
                sol::table t = lua.create_table(0, 4);
                t["no"] = spec.no;
                t["name"] = spec.name;

                sol::table glyphs = lua.create_table(int(spec.glyphItems.size()), 0);
                int g = 0;
                for (uint32 item : spec.glyphItems)
                    glyphs[++g] = item;
                t["glyphItems"] = glyphs;

                sol::table entries = lua.create_table(int(spec.entries.size()), 0);
                int e = 0;
                for (Party::PremadeEntry const& p : spec.entries)
                {
                    sol::table row = lua.create_table(4, 0);
                    row[1] = uint32(p.tab);
                    row[2] = uint32(p.row);
                    row[3] = uint32(p.col);
                    row[4] = uint32(p.rank);
                    entries[++e] = row;
                }
                t["entries"] = entries;

                list[++n] = t;
            }

            return list;
        };

        // rows, reason - rows = array of { id, name, parent, rank, bar, max, flags }
        unit["reputations"] = [](UnitHandle const& h, sol::this_state s)
        {
            sol::state_view lua(s);
            std::vector<Party::ReputationRow> rows;
            Player* bot = nullptr;
            char const* reason = OwnedBot(h, bot);
            if (!reason)
            {
                Party::InvResult const r = Party::Reputations(bot, rows);
                if (!r.ok)
                    reason = r.reason;
            }

            sol::table list = lua.create_table(int(rows.size()), 0);
            int n = 0;
            for (Party::ReputationRow const& row : rows)
            {
                sol::table t = lua.create_table(0, 7);
                t["id"] = row.id;
                t["name"] = row.name;
                t["parent"] = row.parent;
                t["rank"] = uint32(row.rank);
                t["bar"] = row.bar;
                t["max"] = row.max;
                t["flags"] = row.flags;
                list[++n] = t;
            }

            return RowsReason(s, list, reason);
        };

        // rows, reason - rows = array of { id, cat, value, base, max, pureMax, step }
        unit["skills"] = [](UnitHandle const& h, sol::this_state s)
        {
            sol::state_view lua(s);
            std::vector<Party::SkillRow> rows;
            Player* bot = nullptr;
            char const* reason = OwnedBot(h, bot);
            if (!reason)
            {
                Party::InvResult const r = Party::Skills(bot, rows);
                if (!r.ok)
                    reason = r.reason;
            }

            sol::table list = lua.create_table(int(rows.size()), 0);
            int n = 0;
            for (Party::SkillRow const& row : rows)
            {
                sol::table t = lua.create_table(0, 7);
                t["id"] = row.id;
                t["cat"] = row.cat;
                t["value"] = uint32(row.value);
                t["base"] = uint32(row.base);
                t["max"] = uint32(row.max);
                t["pureMax"] = uint32(row.pureMax);
                t["step"] = uint32(row.step);
                list[++n] = t;
            }

            return RowsReason(s, list, reason);
        };

        // { enabled, slots = { {slot, kind, level, glyph, spell} x6 }, bag = { {bag, slot, guid, entry, glyph, kind, spell}, ... } }
        // or nil, reason
        unit["glyphs"] = [](UnitHandle const& h, sol::this_state s)
        {
            sol::state_view lua(s);
            sol::variadic_results results;
            Player* bot = nullptr;
            char const* reason = OwnedBot(h, bot);
            Party::GlyphsOut out;
            if (!reason)
            {
                Party::InvResult const r = Party::Glyphs(bot, out);
                if (!r.ok)
                    reason = r.reason;
            }

            if (reason)
            {
                results.push_back(sol::make_object(s, lua_nil));
                results.push_back(Reason(s, reason));
                return results;
            }

            sol::table t = lua.create_table(0, 3);
            t["enabled"] = out.enabled;

            sol::table slots = lua.create_table(int(out.slots.size()), 0);
            int n = 0;
            for (Party::GlyphSlotRow const& row : out.slots)
            {
                sol::table r = lua.create_table(0, 5);
                r["slot"] = uint32(row.slot);
                r["kind"] = row.kind;
                r["level"] = uint32(row.level);
                r["glyph"] = row.glyph;
                r["spell"] = row.spell;
                slots[++n] = r;
            }
            t["slots"] = slots;

            sol::table bag = lua.create_table(int(out.bag.size()), 0);
            n = 0;
            for (Party::GlyphBagRow const& row : out.bag)
            {
                sol::table r = lua.create_table(0, 7);
                r["bag"] = uint32(row.bag);
                r["slot"] = uint32(row.slot);
                r["guid"] = row.guidLow;
                r["entry"] = row.entry;
                r["glyph"] = row.glyph;
                r["kind"] = row.kind;
                r["spell"] = row.spell;
                bag[++n] = r;
            }
            t["bag"] = bag;

            results.push_back(sol::make_object(s, t));
            return results;
        };

        // ok, reason, a (1 verified / 0 pending; the socket level on "level")
        unit["glyphApply"] = [](UnitHandle const& h, uint32 glyphSlot, uint32 bag, uint32 slot, uint32 guid)
            -> std::tuple<bool, std::string, int32>
        {
            Player* bot = nullptr;
            if (char const* reason = OwnedBot(h, bot))
                return { false, reason, 0 };

            Party::InvResult const r = Party::GlyphApply(bot, Byte(glyphSlot), Byte(bag), Byte(slot), guid);
            return { r.ok, r.reason, r.a };
        };

        // ok, reason
        unit["glyphRemove"] = [](UnitHandle const& h, uint32 glyphSlot) -> std::tuple<bool, std::string>
        {
            Player* bot = nullptr;
            if (char const* reason = OwnedBot(h, bot))
                return { false, reason };

            Party::InvResult const r = Party::GlyphRemove(bot, Byte(glyphSlot));
            return { r.ok, r.reason };
        };

        // rows, reason, npcName - rows = array of { slot, entry, price, count, ext }; {} "no_vendor" nil without a vendor
        unit["vendorItems"] = [](UnitHandle const& h, sol::this_state s)
        {
            sol::state_view lua(s);
            std::vector<Party::VendorRow> rows;
            std::string name;
            Player* bot = nullptr;
            char const* reason = OwnedBot(h, bot);
            if (!reason)
            {
                Party::InvResult const r = Party::VendorItems(bot, rows, &name);
                if (!r.ok)
                {
                    reason = r.reason;
                    rows.clear();
                }
            }

            sol::table list = lua.create_table(int(rows.size()), 0);
            int n = 0;
            for (Party::VendorRow const& row : rows)
            {
                sol::table t = lua.create_table(0, 5);
                t["slot"] = row.slot;
                t["entry"] = row.entry;
                t["price"] = row.price;
                t["count"] = row.count;
                t["ext"] = row.ext;
                list[++n] = t;
            }

            sol::variadic_results results = RowsReason(s, list, reason);
            results.push_back(reason ? sol::make_object(s, lua_nil) : sol::make_object(s, name));
            return results;
        };

        // ok, reason, items gained, money spent
        unit["vendorBuy"] = [](UnitHandle const& h, uint32 slot, uint32 entry, uint32 count)
            -> std::tuple<bool, std::string, int32, int32>
        {
            Player* bot = nullptr;
            if (char const* reason = OwnedBot(h, bot))
                return { false, reason, 0, 0 };

            Party::InvResult const r = Party::VendorBuy(bot, slot, entry, count);
            return { r.ok, r.reason, r.a, r.b };
        };

        // rows, reason - rows = array of { slot, entry, count, price }
        unit["buyback"] = [](UnitHandle const& h, sol::this_state s)
        {
            sol::state_view lua(s);
            std::vector<Party::BuybackRow> rows;
            Player* bot = nullptr;
            char const* reason = OwnedBot(h, bot);
            if (!reason)
            {
                Party::InvResult const r = Party::Buyback(bot, rows);
                if (!r.ok)
                    reason = r.reason;
            }

            sol::table list = lua.create_table(int(rows.size()), 0);
            int n = 0;
            for (Party::BuybackRow const& row : rows)
            {
                sol::table t = lua.create_table(0, 4);
                t["slot"] = row.slot;
                t["entry"] = row.entry;
                t["count"] = row.count;
                t["price"] = row.price;
                list[++n] = t;
            }

            return RowsReason(s, list, reason);
        };

        // ok, reason, money spent
        unit["buybackBuy"] = [](UnitHandle const& h, uint32 slot, uint32 entry) -> std::tuple<bool, std::string, int32>
        {
            Player* bot = nullptr;
            if (char const* reason = OwnedBot(h, bot))
                return { false, reason, 0 };

            Party::InvResult const r = Party::BuybackBuy(bot, slot, entry);
            return { r.ok, r.reason, r.a };
        };

        // rows, total, reason - rows = array of { id, level, title } (ascending id); {}, 0, reason on error
        unit["rewardedQuests"] = [](UnitHandle const& h, sol::optional<uint32> offset, sol::optional<uint32> limit,
                                    sol::this_state s)
        {
            sol::state_view lua(s);
            std::vector<Party::DoneQuestRow> rows;
            uint32 total = 0;
            Player* bot = nullptr;
            char const* reason = OwnedBot(h, bot);
            if (!reason)
            {
                Party::InvResult const r = Party::RewardedQuests(bot, offset.value_or(0), limit.value_or(50), rows, total);
                if (!r.ok)
                {
                    reason = r.reason;
                    rows.clear();
                    total = 0;
                }
            }

            sol::table list = lua.create_table(int(rows.size()), 0);
            int n = 0;
            for (Party::DoneQuestRow const& row : rows)
            {
                sol::table t = lua.create_table(0, 3);
                t["id"] = row.id;
                t["level"] = row.level;
                t["title"] = row.title;
                list[++n] = t;
            }

            sol::variadic_results results;
            results.push_back(sol::make_object(s, list));
            results.push_back(sol::make_object(s, total));
            results.push_back(Reason(s, reason));
            return results;
        };
    }
}
