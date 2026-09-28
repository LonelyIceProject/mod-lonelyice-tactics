/*
 * Bot tactics - player action mirroring, Lua bindings: bot:questAccept,
 * bot:questComplete, bot:questReward, bot:questStatus, bot:summonToOwner, bot:itemUsage, bot:itemFits,
 * wow.questRewards, wow.mirrorConfig.
 *
 * Mutating methods require a world-thread message call (on_message / on_mirror) whose player owns the bot
 * (Party::CheckOwned: wrong_thread / bad_bot); they return ok, reason. Read-only methods work in any entry call.
 */

#include "TacticsEngine.h"
#include "TacticsInventory.h"
#include "TacticsMirror.h"
#include "TacticsPartyApi.h"

#include "ObjectMgr.h"
#include "Player.h"
#include "Playerbots.h"
#include "QuestDef.h"

#include <tuple>

namespace Tactics::Lua
{
    namespace
    {
        using sol::lua_nil;
        using OkReason = std::tuple<bool, std::string>;

        // wrong_thread / bad_bot, else nullptr with bot (and ai) set
        char const* OwnedBot(UnitHandle const& h, Player*& bot, PlayerbotAI*& ai)
        {
            bot = nullptr;
            ai = nullptr;
            if (!MessagePlayer())
                return "wrong_thread";

            bot = ResolvePlayerbot(h, ai);
            if (!bot)
                return "bad_bot";

            return Party::CheckOwned(bot);
        }

        OkReason Pair(Mirror::Result const& result)
        {
            return { result.ok, result.reason };
        }

        // optional GUID text argument: true and guid empty for nil, false for malformed text
        bool GuidArg(sol::optional<std::string> const& hex, ObjectGuid& out)
        {
            out = ObjectGuid::Empty;
            if (!hex || hex->empty())
                return true;

            return HexToGuid(*hex, out);
        }
    }

    void RegisterMirrorApi(sol::state_view& /*lua*/, sol::usertype<UnitHandle>& unit, sol::table& wow)
    {
        // ok, reason: bad_quest, already, cannot_take, full_log, failed (+ wrong_thread, bad_bot, bad_arg).
        // giverHex is validated but not handed to the core (no escort / script starts for the bot).
        unit["questAccept"] = [](UnitHandle const& h, uint32 questId, sol::optional<std::string> giverHex) -> OkReason
        {
            Player* bot = nullptr;
            PlayerbotAI* ai = nullptr;
            if (char const* reason = OwnedBot(h, bot, ai))
                return { false, reason };

            ObjectGuid giver;
            if (!GuidArg(giverHex, giver))
                return { false, "bad_arg" };

            return Pair(Mirror::QuestAccept(bot, questId));
        };

        // ok, reason: bad_quest, not_taken, already, bags (ok = true: completed, some required items did not fit), failed.
        // items = true: create the missing required items first (turnin_items).
        unit["questComplete"] = [](UnitHandle const& h, uint32 questId, sol::optional<bool> items) -> OkReason
        {
            Player* bot = nullptr;
            PlayerbotAI* ai = nullptr;
            if (char const* reason = OwnedBot(h, bot, ai))
                return { false, reason };

            return Pair(Mirror::QuestComplete(bot, questId, items.value_or(false)));
        };

        // ok, reason: bad_quest, already, not_complete, bad_choice, full, failed. choice is 0-based (default 0).
        unit["questReward"] = [](UnitHandle const& h, uint32 questId, sol::optional<std::string> giverHex,
                                 sol::optional<uint32> choice) -> OkReason
        {
            Player* bot = nullptr;
            PlayerbotAI* ai = nullptr;
            if (char const* reason = OwnedBot(h, bot, ai))
                return { false, reason };

            ObjectGuid giver;
            if (!GuidArg(giverHex, giver))
                return { false, "bad_arg" };

            return Pair(Mirror::QuestReward(bot, questId, giver, choice.value_or(0)));
        };

        // "none" | "incomplete" | "complete" | "failed" | "rewarded"; nil for a non-bot handle
        unit["questStatus"] = [](UnitHandle const& h, uint32 questId) -> sol::optional<std::string>
        {
            PlayerbotAI* ai = nullptr;
            Player* bot = ResolvePlayerbot(h, ai);
            if (!bot)
                return sol::nullopt;

            return std::string(Mirror::QuestStatusName(bot, questId));
        };

        // ok, reason: already, dead, combat, flight, owner_busy, instance, failed (+ wrong_thread, bad_bot)
        unit["summonToOwner"] = [](UnitHandle const& h) -> OkReason
        {
            Player* bot = nullptr;
            PlayerbotAI* ai = nullptr;
            if (char const* reason = OwnedBot(h, bot, ai))
                return { false, reason };

            OkReason const result = Pair(Mirror::SummonToOwner(bot, GetOwner(bot)));

            // a far teleport takes the bot out of the world: drop it from this call's resolution cache
            if (CallContext* call = CurrentCall())
                call->cache.erase(bot->GetGUID());

            return result;
        };

        // playerbots "item usage" of an item entry for this bot (equip, replace, use, ...), nil for a bad entry / non-bot
        unit["itemUsage"] = [](UnitHandle const& h, uint32 entry) -> sol::optional<std::string>
        {
            PlayerbotAI* ai = nullptr;
            Player* bot = ResolvePlayerbot(h, ai);
            char const* usage = bot ? Mirror::ItemUsageName(ai, entry) : nullptr;
            if (!usage)
                return sol::nullopt;

            return std::string(usage);
        };

        // bool: the bot can use the item and has an equipment slot for it
        unit["itemFits"] = [](UnitHandle const& h, uint32 entry)
        {
            PlayerbotAI* ai = nullptr;
            Player* bot = ResolvePlayerbot(h, ai);
            return bot && Mirror::ItemFits(bot, entry);
        };

        // rewards, choiceCount. rewards = array: first the choice rewards, then the fixed ones; each entry is
        // { entry, count } (also named: entry, count, choice (bool), index (0-based choice index, choices only)).
        // {}, 0 for an unknown quest.
        wow["questRewards"] = [](uint32 questId, sol::this_state s)
        {
            sol::state_view lua(s);
            sol::table list = lua.create_table();
            uint32 choices = 0;
            Quest const* quest = questId ? sObjectMgr->GetQuestTemplate(questId) : nullptr;
            if (quest)
            {
                int n = 0;
                for (uint32 i = 0; i < QUEST_REWARD_CHOICES_COUNT; ++i)
                {
                    if (!quest->RewardChoiceItemId[i])
                        continue;

                    sol::table t = lua.create_table(2, 4);
                    t[1] = quest->RewardChoiceItemId[i];
                    t[2] = quest->RewardChoiceItemCount[i];
                    t["entry"] = quest->RewardChoiceItemId[i];
                    t["count"] = quest->RewardChoiceItemCount[i];
                    t["choice"] = true;
                    t["index"] = i;
                    list[++n] = t;
                    ++choices;
                }

                for (uint32 i = 0; i < QUEST_REWARDS_COUNT; ++i)
                {
                    if (!quest->RewardItemId[i])
                        continue;

                    sol::table t = lua.create_table(2, 3);
                    t[1] = quest->RewardItemId[i];
                    t[2] = quest->RewardItemIdCount[i];
                    t["entry"] = quest->RewardItemId[i];
                    t["count"] = quest->RewardItemIdCount[i];
                    t["choice"] = false;
                    list[++n] = t;
                }
            }

            sol::variadic_results results;
            results.push_back(sol::make_object(s, list));
            results.push_back(sol::make_object(s, choices));
            return results;
        };

        // { enable, radius } of Tactics.Mirror.* (read at config load)
        wow["mirrorConfig"] = [](sol::this_state s)
        {
            sol::state_view lua(s);
            sol::table t = lua.create_table(0, 2);
            t["enable"] = Config().enable && Config().mirrorEnable;
            t["radius"] = Config().mirrorRadius;
            return t;
        };
    }
}
