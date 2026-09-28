/*
 * Bot tactics - player action mirroring: event detection + primitives.
 *
 * Detection only watches REAL players in a group (bots never raise events, so a mirrored bot action cannot
 * recurse). Hooks may run on map-update threads (CMSG_ACTIVATETAXI is PROCESS_THREADSAFE, teleports start in
 * Player::Update), so every hook only appends to a mutex-protected queue. The world script drains it in
 * WorldScript::OnUpdate - world thread, after MapMgr::Update has joined the map threads (World.cpp:1244 / 1345) -
 * and calls Lua tactics.on_mirror(event, player, payload) there, the same context as on_message.
 *
 * Events and payloads (k=v;... , hex = 16-digit GUID text):
 *   quest_accept   quest=<id>;giver=<hex|>           Player::AddQuestAndCheckCompletion (NPC, GO, item, share)
 *   quest_abandon  quest=<id>                        CMSG_QUESTLOG_REMOVE_QUEST
 *   quest_reward   quest=<id>;giver=<hex|>;choice=<n|-1>   end of Player::RewardQuest (the turn-in); choice from
 *                                                   the player's CMSG_QUESTGIVER_CHOOSE_REWARD, -1 when unknown
 *   taxi_start     npc=<hex>;src=<node>;dst=<node>  CMSG_ACTIVATETAXI / CMSG_ACTIVATETAXIEXPRESS
 *   taxi_done      map=<id>;x=;y=;z=                1.5 s after the player's flight ended
 *   teleport_done  map=<id>;x=;y=;z=;from=<map id>  1.5 s after a teleport (another map, or >= 100 yd away)
 *                                                   finished with the player alive at the destination
 *   vendor         npc=<hex>                         CMSG_LIST_INVENTORY
 *   repair         npc=<hex>                         Player durability repair at an NPC
 *   trainer        npc=<hex>                         CMSG_TRAINER_LIST
 *   gossip         npc=<hex>                         CMSG_GOSSIP_HELLO
 * vendor / repair / trainer / gossip are delivered at most once per player and event per 2 s.
 */

#include "TacticsMirror.h"

#include "TacticsEngine.h"
#include "TacticsLua.h"

#include "Creature.h"
#include "GameObject.h"
#include "Group.h"
#include "Item.h"
#include "ItemUsageValue.h"
#include "LastMovementValue.h"
#include "Log.h"
#include "MapMgr.h"
#include "ObjectAccessor.h"
#include "ObjectMgr.h"
#include "Pet.h"
#include "Player.h"
#include "Playerbots.h"
#include "QuestDef.h"
#include "ScriptMgr.h"
#include "StringFormat.h"
#include "Timer.h"
#include "WorldPacket.h"
#include "WorldSession.h"

#include <cmath>
#include <cstdlib>
#include <deque>
#include <mutex>
#include <unordered_map>
#include <vector>

// ====================================================================== primitives
namespace Tactics::Mirror
{
    namespace
    {
        Result Ok(char const* reason = "ok") { return { true, reason }; }
        Result Fail(char const* reason) { return { false, reason }; }

        bool InLog(Player* bot, uint32 questId)
        {
            return bot->FindQuestSlot(questId) < MAX_QUEST_LOG_SIZE;
        }

        // Player::CanRewardQuest(quest, msg) without its "all required items in the bags" part
        // (QUEST_SPECIAL_FLAGS_DELIVER): a bot turns the quest in with its leader even when it carries fewer items
        // than asked; RewardQuest takes what there is (DestroyItemCount stops at the bot's count).
        bool CanRewardWithoutItems(Player* bot, Quest const* quest)
        {
            if (!quest->IsDFQuest() && !quest->IsAutoComplete() && quest->GetQuestMethod() &&
                bot->GetQuestStatus(quest->GetQuestId()) != QUEST_STATUS_COMPLETE)
                return false;

            if (!bot->SatisfyQuestDay(quest, false) || !bot->SatisfyQuestWeek(quest, false) ||
                !bot->SatisfyQuestMonth(quest, false) || !bot->SatisfyQuestSeasonal(quest, false))
                return false;

            if (bot->GetQuestRewardStatus(quest->GetQuestId()))
                return false;

            if (quest->GetRewOrReqMoney() < 0 && !bot->HasEnoughMoney(-quest->GetRewOrReqMoney()))
                return false;

            return !bot->HasPlayerFlag(PLAYER_FLAGS_NO_PLAY_TIME);
        }

        // The bag space part of Player::CanRewardQuest(quest, reward, msg).
        bool RewardItemsFit(Player* bot, Quest const* quest, uint32 choice)
        {
            ItemPosCountVec dest;
            if (quest->GetRewChoiceItemsCount() > 0 && quest->RewardChoiceItemId[choice] &&
                bot->CanStoreNewItem(NULL_BAG, NULL_SLOT, dest, quest->RewardChoiceItemId[choice],
                                     quest->RewardChoiceItemCount[choice]) != EQUIP_ERR_OK)
                return false;

            for (uint32 i = 0; i < quest->GetRewItemsCount(); ++i)
            {
                if (quest->RewardItemId[i] &&
                    bot->CanStoreNewItem(NULL_BAG, NULL_SLOT, dest, quest->RewardItemId[i], quest->RewardItemIdCount[i]) != EQUIP_ERR_OK)
                    return false;
            }
            return true;
        }
    }

    Result QuestAccept(Player* bot, uint32 questId)
    {
        Quest const* quest = questId ? sObjectMgr->GetQuestTemplate(questId) : nullptr;
        if (!quest)
            return Fail("bad_quest");

        if (InLog(bot, questId))
            return Fail("already");

        if (!bot->CanTakeQuest(quest, false))
            return Fail("cannot_take");

        if (!bot->SatisfyQuestLog(false))
            return Fail("full_log");

        if (!bot->CanAddQuest(quest, false))
            return Fail("cannot_take");

        // nullptr giver: no creature / GO script hooks (escorts) and no quest item destruction for the bot
        bot->AddQuestAndCheckCompletion(quest, nullptr);
        return InLog(bot, questId) ? Ok() : Fail("failed");
    }

    Result QuestComplete(Player* bot, uint32 questId, bool withItems)
    {
        Quest const* quest = questId ? sObjectMgr->GetQuestTemplate(questId) : nullptr;
        if (!quest)
            return Fail("bad_quest");

        QuestStatus const status = bot->GetQuestStatus(questId);
        if (status == QUEST_STATUS_COMPLETE && !withItems)
            return Fail("already");

        if (status != QUEST_STATUS_INCOMPLETE && status != QUEST_STATUS_COMPLETE)
            return Fail("not_taken");

        bool bagsFull = false;
        if (withItems)
        {
            for (uint8 i = 0; i < QUEST_ITEM_OBJECTIVES_COUNT; ++i)
            {
                uint32 const itemId = quest->RequiredItemId[i];
                uint32 const count = quest->RequiredItemCount[i];
                if (!itemId || !count)
                    continue;

                uint32 const have = bot->GetItemCount(itemId, true);
                if (have >= count)
                    continue;

                ItemPosCountVec dest;
                if (bot->CanStoreNewItem(NULL_BAG, NULL_SLOT, dest, itemId, count - have) != EQUIP_ERR_OK)
                {
                    bagsFull = true;
                    continue;
                }

                if (Item* item = bot->StoreNewItem(dest, itemId, true))
                    bot->SendNewItem(item, count - have, true, false);
            }
        }

        if (status == QUEST_STATUS_COMPLETE)
            return bagsFull ? Ok("bags") : Fail("already");

        bot->CompleteQuest(questId);   // OnPlayerBeforeQuestComplete scripts may veto it
        if (bot->GetQuestStatus(questId) != QUEST_STATUS_COMPLETE)
            return Fail("failed");

        return Ok(bagsFull ? "bags" : "ok");
    }

    Result QuestReward(Player* bot, uint32 questId, ObjectGuid giverGuid, uint32 choice)
    {
        Quest const* quest = questId ? sObjectMgr->GetQuestTemplate(questId) : nullptr;
        if (!quest)
            return Fail("bad_quest");

        if (!InLog(bot, questId) && bot->GetQuestRewardStatus(questId))
            return Fail("already");

        if (bot->GetQuestStatus(questId) != QUEST_STATUS_COMPLETE && !quest->IsAutoComplete())
            return Fail("not_complete");

        if (quest->GetRewChoiceItemsCount() > 0)
        {
            if (choice >= QUEST_REWARD_CHOICES_COUNT || !quest->RewardChoiceItemId[choice])
                return Fail("bad_choice");
        }
        else
            choice = 0;

        // status, daily limits, money (not the required items: missing ones are simply not taken), then bag space
        if (!CanRewardWithoutItems(bot, quest))
            return Fail("failed");

        if (!RewardItemsFit(bot, quest, choice))
            return Fail("full");

        Object* giver = bot;
        if (giverGuid && bot->IsInWorld())
        {
            if (giverGuid.IsCreatureOrVehicle())
            {
                if (Creature* creature = ObjectAccessor::GetCreature(*bot, giverGuid))
                    giver = creature;
            }
            else if (giverGuid.IsGameObject())
            {
                if (GameObject* go = ObjectAccessor::GetGameObject(*bot, giverGuid))
                    giver = go;
            }
        }

        bot->RewardQuest(quest, choice, giver, true);
        return bot->GetQuestRewardStatus(questId) || quest->IsRepeatable() ? Ok() : Fail("failed");
    }

    char const* QuestStatusName(Player* bot, uint32 questId)
    {
        if (!questId)
            return "none";

        switch (bot->GetQuestStatus(questId))
        {
            case QUEST_STATUS_COMPLETE:
                return "complete";
            case QUEST_STATUS_INCOMPLETE:
                return "incomplete";
            case QUEST_STATUS_FAILED:
                return "failed";
            case QUEST_STATUS_REWARDED:
                return "rewarded";
            default:
                return bot->GetQuestRewardStatus(questId) ? "rewarded" : "none";
        }
    }

    Result SummonToOwner(Player* bot, Player* owner)
    {
        if (!owner || !owner->IsInWorld() || owner->IsBeingTeleported() || owner->IsInFlight())
            return Fail("owner_busy");

        if (!bot->IsAlive())
            return Fail("dead");

        if (bot->IsInCombat())
            return Fail("combat");

        if (bot->IsInFlight() || bot->IsBeingTeleported() || bot->GetVehicle())
            return Fail("flight");

        Map* map = owner->GetMap();
        bool const sameMap = bot->GetMap() == map;
        if (sameMap && bot->GetDistance(owner) <= 5.0f)
            return Fail("already");

        if (!sameMap && map->Instanceable() && sMapMgr->PlayerCannotEnter(map->GetId(), bot) != Map::CAN_ENTER)
            return Fail("instance");

        // a ring around the owner, spread by guid so several bots do not stack (custom_waystones.cpp OfferGroup)
        float const angle = float(M_PI) * (0.6f + 0.35f * float(bot->GetGUID().GetCounter() % 6));
        float x = owner->GetPositionX();
        float y = owner->GetPositionY();
        float z = owner->GetPositionZ();
        if (!owner->GetClosePoint(x, y, z, bot->GetCombatReach(), 2.5f, angle, bot))
        {
            x = owner->GetPositionX();
            y = owner->GetPositionY();
            z = owner->GetPositionZ();
        }

        // as playerbots SummonAction::Teleport (UseMeetingStoneAction.cpp:233-243)
        bot->GetMotionMaster()->Clear();
        if (PlayerbotAI* ai = GET_PLAYERBOT_AI(bot))
            ai->GetAiObjectContext()->GetValue<LastMovement&>("last movement")->Get().clear();

        if (!bot->TeleportTo(owner->GetMapId(), x, y, z, owner->GetOrientation()))
            return Fail("failed");

        if (sameMap)
        {
            if (Pet* pet = bot->GetPet())
                pet->NearTeleportTo(x, y, z, owner->GetOrientation());
            if (Guardian* guardian = bot->GetGuardianPet())
                guardian->NearTeleportTo(x, y, z, owner->GetOrientation());
        }

        return Ok();
    }

    char const* ItemUsageName(PlayerbotAI* ai, uint32 entry)
    {
        if (!ai || !entry || !sObjectMgr->GetItemTemplate(entry))
            return nullptr;

        switch (ai->GetAiObjectContext()->GetValue<ItemUsage>("item usage", int32(entry))->Get())
        {
            case ITEM_USAGE_EQUIP:        return "equip";
            case ITEM_USAGE_REPLACE:      return "replace";
            case ITEM_USAGE_BAD_EQUIP:    return "bad_equip";
            case ITEM_USAGE_BROKEN_EQUIP: return "broken_equip";
            case ITEM_USAGE_QUEST:        return "quest";
            case ITEM_USAGE_SKILL:        return "skill";
            case ITEM_USAGE_USE:          return "use";
            case ITEM_USAGE_GUILD_TASK:   return "guild_task";
            case ITEM_USAGE_DISENCHANT:   return "disenchant";
            case ITEM_USAGE_AH:           return "ah";
            case ITEM_USAGE_KEEP:         return "keep";
            case ITEM_USAGE_VENDOR:       return "vendor";
            case ITEM_USAGE_AMMO:         return "ammo";
            default:                      return "none";
        }
    }

    bool ItemFits(Player* bot, uint32 entry)
    {
        ItemTemplate const* proto = entry ? sObjectMgr->GetItemTemplate(entry) : nullptr;
        return proto && bot->CanUseItem(proto) == EQUIP_ERR_OK && bot->FindEquipSlot(proto, NULL_SLOT, true) != NULL_SLOT;
    }
}

// ====================================================================== event detection
namespace
{
    using namespace Tactics;

    constexpr size_t MAX_QUEUE = 256;
    constexpr uint32 SETTLE_MS = 1500;                    // "after" events: the player has been standing this long
    constexpr uint32 TAXI_START_TIMEOUT_MS = 10000;       // activation refused (no money, too far): no flight seen
    constexpr uint32 TAXI_TIMEOUT_MS = 30 * 60 * 1000;    // longest flight chain we wait for
    constexpr uint32 TELEPORT_TIMEOUT_MS = 120000;        // loading screens included
    constexpr uint32 PACKET_MEMORY_MS = 10000;            // an accept / choose packet belongs to a hook this recent
    constexpr uint32 DEDUPE_MS = 2000;
    constexpr float TELEPORT_MIN_DISTANCE = 100.0f;       // same-map teleports shorter than this (blink, charge) are ignored
    constexpr float ARRIVAL_DISTANCE = 50.0f;

    struct PendingEvent
    {
        ObjectGuid player;
        std::string name;                                  // "@teleport" = internal: start a teleport watch
        std::string payload;                               // "@teleport": the map id the player leaves
        uint32 map = 0;
        float x = 0.0f, y = 0.0f, z = 0.0f;
    };

    struct QuestPacket
    {
        uint32 quest = 0;
        ObjectGuid giver;
        uint32 choice = 0;
        uint32 at = 0;
    };

    std::mutex sLock;
    std::deque<PendingEvent> sQueue;
    std::unordered_map<ObjectGuid, QuestPacket> sLastAccept;   // CMSG_QUESTGIVER_ACCEPT_QUEST per player
    std::unordered_map<ObjectGuid, QuestPacket> sLastChoice;   // CMSG_QUESTGIVER_CHOOSE_REWARD per player

    // world thread only (OnUpdate)
    struct Watch
    {
        bool taxi = false;
        uint32 startMs = 0;
        uint32 settledMs = 0;                              // first tick seen standing (0 = not yet)
        bool seenFlight = false;
        uint32 fromMap = 0;
        uint32 map = 0;
        float x = 0.0f, y = 0.0f, z = 0.0f;
    };

    std::unordered_map<ObjectGuid, Watch> sTaxiWatches;
    std::unordered_map<ObjectGuid, Watch> sTeleportWatches;
    std::unordered_map<std::string, uint32> sLastDelivery;  // "<guid>|<event>" -> getMSTime()

    bool Enabled()
    {
        return Config().enable && Config().mirrorEnable;
    }

    // Real players in a group only; bots (and their mirrored actions) never raise events. A selfbot group
    // LEADER counts as a real player, the same rule as GetOwner() (".playerbots bot self" users and the
    // headless sim leader, so the sim's "mirror" self-test gets on_mirror events). Non-leader selfbots and
    // ordinary bots stay unwatched, so a bot's mirrored action cannot raise another event.
    bool Watched(Player* player)
    {
        if (!player || !player->GetSession())
            return false;

        Group* group = player->GetGroup();
        if (!group)
            return false;

        return IsRealPlayer(player) || (IsSelfBot(player) && group->GetLeaderGUID() == player->GetGUID());
    }

    void Push(PendingEvent&& event)
    {
        std::lock_guard<std::mutex> guard(sLock);
        if (sQueue.size() >= MAX_QUEUE)
        {
            LogWarnLimited("mirror: event queue full, dropping '" + event.name + "'");
            return;
        }

        sQueue.push_back(std::move(event));
    }

    void Push(Player* player, std::string name, std::string payload)
    {
        PendingEvent event;
        event.player = player->GetGUID();
        event.name = std::move(name);
        event.payload = std::move(payload);
        Push(std::move(event));
    }

    std::string Hex(ObjectGuid guid)
    {
        return guid ? Lua::GuidToHex(guid) : std::string();
    }

    std::string PositionText(Player* player)
    {
        return Acore::StringFormat("map={};x={:.2f};y={:.2f};z={:.2f}", player->GetMapId(), player->GetPositionX(),
                                   player->GetPositionY(), player->GetPositionZ());
    }

    // The group has at least one online playerbot (skip the Lua call otherwise). World thread.
    bool HasBots(Player* player)
    {
        Group* group = player->GetGroup();
        if (!group)
            return false;

        for (GroupReference* ref = group->GetFirstMember(); ref; ref = ref->next())
        {
            Player* member = ref->GetSource();
            if (member && member != player && GET_PLAYERBOT_AI(member))
                return true;
        }

        return false;
    }

    void Deliver(Player* player, std::string const& name, std::string const& payload)
    {
        if (!player || !player->IsInWorld() || !HasBots(player))
            return;

        if (name == "vendor" || name == "repair" || name == "trainer" || name == "gossip")
        {
            uint32 const now = getMSTime();
            std::string const key = std::to_string(player->GetGUID().GetCounter()) + "|" + name;
            auto itr = sLastDelivery.find(key);
            if (itr != sLastDelivery.end() && getMSTimeDiff(itr->second, now) < DEDUPE_MS)
                return;

            if (sLastDelivery.size() > 1000)
                sLastDelivery.clear();

            sLastDelivery[key] = now;
        }

        if (Config().debug)
            LOG_INFO("module", "[tactics] mirror {} {} {}", player->GetName(), name, payload);

        Lua::OnMirror(player, name, payload);
    }

    void UpdateTaxiWatches(uint32 now)
    {
        for (auto itr = sTaxiWatches.begin(); itr != sTaxiWatches.end();)
        {
            Watch& watch = itr->second;
            Player* player = ObjectAccessor::FindConnectedPlayer(itr->first);
            if (!player)
            {
                itr = sTaxiWatches.erase(itr);
                continue;
            }

            if (player->IsInFlight())
            {
                watch.seenFlight = true;
                watch.settledMs = 0;
            }
            else if (!watch.seenFlight)
            {
                if (getMSTimeDiff(watch.startMs, now) > TAXI_START_TIMEOUT_MS)
                {
                    itr = sTaxiWatches.erase(itr);
                    continue;
                }
            }
            else if (player->IsInWorld() && !player->IsBeingTeleported())
            {
                if (!watch.settledMs)
                    watch.settledMs = now ? now : 1;
                else if (getMSTimeDiff(watch.settledMs, now) >= SETTLE_MS)
                {
                    Deliver(player, "taxi_done", PositionText(player));
                    itr = sTaxiWatches.erase(itr);
                    continue;
                }
            }

            if (getMSTimeDiff(watch.startMs, now) > TAXI_TIMEOUT_MS)
            {
                itr = sTaxiWatches.erase(itr);
                continue;
            }

            ++itr;
        }
    }

    void UpdateTeleportWatches(uint32 now)
    {
        for (auto itr = sTeleportWatches.begin(); itr != sTeleportWatches.end();)
        {
            Watch& watch = itr->second;
            Player* player = ObjectAccessor::FindConnectedPlayer(itr->first);
            if (!player || getMSTimeDiff(watch.startMs, now) > TELEPORT_TIMEOUT_MS)
            {
                itr = sTeleportWatches.erase(itr);
                continue;
            }

            if (!player->IsInWorld() || player->IsBeingTeleported() || player->IsInFlight())
            {
                watch.settledMs = 0;
                ++itr;
                continue;
            }

            if (!watch.settledMs)
            {
                watch.settledMs = now ? now : 1;
                ++itr;
                continue;
            }

            if (getMSTimeDiff(watch.settledMs, now) < SETTLE_MS)
            {
                ++itr;
                continue;
            }

            // arrived where the teleport pointed (an aborted teleport leaves the player at the origin), alive
            // (the graveyard teleport of a released ghost is not followed)
            if (player->IsAlive() && player->GetMapId() == watch.map &&
                player->GetDistance(watch.x, watch.y, watch.z) <= ARRIVAL_DISTANCE)
                Deliver(player, "teleport_done", PositionText(player) + ";from=" + std::to_string(watch.fromMap));

            itr = sTeleportWatches.erase(itr);
        }
    }

    // Reads a client packet without touching the original (the handler still parses it).
    template <typename Fn>
    void ReadPacket(WorldPacket const& packet, Fn&& fn)
    {
        WorldPacket copy(packet);
        copy.rpos(0);
        try
        {
            fn(copy);
        }
        catch (ByteBufferException const&)
        {
        }
    }
}

class TacticsMirrorWorldScript : public WorldScript
{
public:
    TacticsMirrorWorldScript() : WorldScript("TacticsMirrorWorldScript", { WORLDHOOK_ON_UPDATE }) { }

    void OnUpdate(uint32 /*diff*/) override
    {
        std::deque<PendingEvent> events;
        {
            std::lock_guard<std::mutex> guard(sLock);
            events.swap(sQueue);
        }

        bool const enabled = Enabled();
        uint32 const now = getMSTime();
        for (PendingEvent& event : events)
        {
            if (!enabled)
                continue;

            Player* player = ObjectAccessor::FindConnectedPlayer(event.player);
            if (!player)
                continue;

            if (event.name == "@teleport")
            {
                Watch& watch = sTeleportWatches[event.player];
                watch = Watch();
                watch.startMs = now;
                watch.fromMap = uint32(std::strtoul(event.payload.c_str(), nullptr, 10));
                watch.map = event.map;
                watch.x = event.x;
                watch.y = event.y;
                watch.z = event.z;
                continue;
            }

            if (event.name == "taxi_start")
            {
                Watch& watch = sTaxiWatches[event.player];
                watch = Watch();
                watch.taxi = true;
                watch.startMs = now;
            }

            Deliver(player, event.name, event.payload);
        }

        if (!enabled)
        {
            sTaxiWatches.clear();
            sTeleportWatches.clear();
            return;
        }

        UpdateTaxiWatches(now);
        UpdateTeleportWatches(now);
    }
};

class TacticsMirrorPlayerScript : public PlayerScript
{
public:
    TacticsMirrorPlayerScript() : PlayerScript("TacticsMirrorPlayerScript",
        { PLAYERHOOK_ON_PLAYER_QUEST_ACCEPT, PLAYERHOOK_ON_QUEST_ABANDON, PLAYERHOOK_ON_PLAYER_COMPLETE_QUEST,
          PLAYERHOOK_ON_BEFORE_TELEPORT, PLAYERHOOK_ON_BEFORE_DURABILITY_REPAIR, PLAYERHOOK_ON_LOGOUT }) { }

    // Player::AddQuestAndCheckCompletion (PlayerQuest.cpp:426): quest giver NPC / GO / item, shared quests and
    // quests that follow automatically in a chain. The giver comes from the player's last accept packet.
    void OnPlayerQuestAccept(Player* player, Quest const* quest) override
    {
        if (!Enabled() || !quest || !Watched(player))
            return;

        ObjectGuid giver;
        {
            std::lock_guard<std::mutex> guard(sLock);
            auto itr = sLastAccept.find(player->GetGUID());
            if (itr != sLastAccept.end() && itr->second.quest == quest->GetQuestId() &&
                getMSTimeDiff(itr->second.at, getMSTime()) < PACKET_MEMORY_MS)
                giver = itr->second.giver;
        }

        Push(player, "quest_accept", Acore::StringFormat("quest={};giver={}", quest->GetQuestId(), Hex(giver)));
    }

    // WorldSession::HandleQuestLogRemoveQuest (QuestHandler.cpp:424)
    void OnPlayerQuestAbandon(Player* player, uint32 questId) override
    {
        if (Enabled() && questId && Watched(player))
            Push(player, "quest_abandon", Acore::StringFormat("quest={}", questId));
    }

    // Despite its name this hook runs at the END of Player::RewardQuest (PlayerQuest.cpp:903): the quest was
    // turned in. (OnPlayerQuestComputeXP also fires for the quest detail / reward windows, GossipDef.cpp:473/725.)
    void OnPlayerCompleteQuest(Player* player, Quest const* quest) override
    {
        if (!Enabled() || !quest || !Watched(player))
            return;

        ObjectGuid giver;
        int32 choice = -1;
        {
            std::lock_guard<std::mutex> guard(sLock);
            auto itr = sLastChoice.find(player->GetGUID());
            if (itr != sLastChoice.end() && itr->second.quest == quest->GetQuestId() &&
                getMSTimeDiff(itr->second.at, getMSTime()) < PACKET_MEMORY_MS)
            {
                giver = itr->second.giver;
                choice = int32(itr->second.choice);
                sLastChoice.erase(itr);
            }
        }

        Push(player, "quest_reward",
             Acore::StringFormat("quest={};giver={};choice={}", quest->GetQuestId(), Hex(giver), choice));
    }

    // Player::TeleportTo (Player.cpp:1498). Only records the destination; teleport_done is raised by the world
    // script once the player stands there.
    bool OnPlayerBeforeTeleport(Player* player, uint32 mapId, float x, float y, float z, float /*orientation*/,
                                uint32 /*options*/, Unit* /*target*/) override
    {
        if (!Enabled() || !Watched(player) || !player->IsInWorld() || player->IsInFlight() || !player->IsAlive())
            return true;

        if (mapId == player->GetMapId() && player->GetDistance(x, y, z) < TELEPORT_MIN_DISTANCE)
            return true;

        PendingEvent event;
        event.player = player->GetGUID();
        event.name = "@teleport";
        event.payload = std::to_string(player->GetMapId());
        event.map = mapId;
        event.x = x;
        event.y = y;
        event.z = z;
        Push(std::move(event));
        return true;
    }

    // WorldSession::HandleRepairItemOpcode (NPCHandler.cpp:782), once per repaired item or for "repair all"
    void OnPlayerBeforeDurabilityRepair(Player* player, ObjectGuid npcGuid, ObjectGuid /*itemGuid*/, float& /*discountMod*/,
                                        uint8 /*guildBank*/) override
    {
        if (Enabled() && Watched(player))
            Push(player, "repair", "npc=" + Hex(npcGuid));
    }

    void OnPlayerLogout(Player* player) override
    {
        std::lock_guard<std::mutex> guard(sLock);
        sLastAccept.erase(player->GetGUID());
        sLastChoice.erase(player->GetGUID());
    }
};

// Client packets of the real player, as custom_autoloot.cpp does for CMSG_LOOT_MONEY. Never blocks a packet.
// NOTE: ScriptMgr::CanPacketReceive passes the packet as `WorldPacket const&` (ServerScript.cpp:66-71), so the
// const overload is the one that is called.
class TacticsMirrorServerScript : public ServerScript
{
public:
    TacticsMirrorServerScript() : ServerScript("TacticsMirrorServerScript", { SERVERHOOK_CAN_PACKET_RECEIVE }) { }

    bool CanPacketReceive(WorldSession* session, WorldPacket const& packet) override
    {
        uint16 const opcode = packet.GetOpcode();
        switch (opcode)
        {
            case CMSG_ACTIVATETAXI:
            case CMSG_ACTIVATETAXIEXPRESS:
            case CMSG_LIST_INVENTORY:
            case CMSG_TRAINER_LIST:
            case CMSG_GOSSIP_HELLO:
            case CMSG_QUESTGIVER_ACCEPT_QUEST:
            case CMSG_QUESTGIVER_CHOOSE_REWARD:
                break;
            default:
                return true;
        }

        if (!Enabled() || !session || session->IsBot())
            return true;

        Player* player = session->GetPlayer();
        if (!Watched(player) || !player->IsInWorld())
            return true;

        switch (opcode)
        {
            case CMSG_ACTIVATETAXI:
                ReadPacket(packet, [&](WorldPacket& p)
                {
                    ObjectGuid npc;
                    uint32 src = 0, dst = 0;
                    p >> npc >> src >> dst;
                    Push(player, "taxi_start", Acore::StringFormat("npc={};src={};dst={}", Hex(npc), src, dst));
                });
                break;
            case CMSG_ACTIVATETAXIEXPRESS:
                ReadPacket(packet, [&](WorldPacket& p)
                {
                    ObjectGuid npc;
                    uint32 count = 0, src = 0, dst = 0;
                    p >> npc >> count;
                    for (uint32 i = 0; i < count && i < 64; ++i)
                    {
                        uint32 node = 0;
                        p >> node;
                        if (i == 0)
                            src = node;
                        dst = node;
                    }

                    Push(player, "taxi_start", Acore::StringFormat("npc={};src={};dst={}", Hex(npc), src, dst));
                });
                break;
            case CMSG_LIST_INVENTORY:
            case CMSG_TRAINER_LIST:
            case CMSG_GOSSIP_HELLO:
                ReadPacket(packet, [&](WorldPacket& p)
                {
                    ObjectGuid npc;
                    p >> npc;
                    char const* name = opcode == CMSG_LIST_INVENTORY ? "vendor" : opcode == CMSG_TRAINER_LIST ? "trainer" : "gossip";
                    Push(player, name, "npc=" + Hex(npc));
                });
                break;
            case CMSG_QUESTGIVER_ACCEPT_QUEST:
            case CMSG_QUESTGIVER_CHOOSE_REWARD:
                ReadPacket(packet, [&](WorldPacket& p)
                {
                    QuestPacket entry;
                    p >> entry.giver >> entry.quest;
                    if (opcode == CMSG_QUESTGIVER_CHOOSE_REWARD)
                        p >> entry.choice;
                    entry.at = getMSTime();

                    std::lock_guard<std::mutex> guard(sLock);
                    (opcode == CMSG_QUESTGIVER_ACCEPT_QUEST ? sLastAccept : sLastChoice)[player->GetGUID()] = entry;
                });
                break;
            default:
                break;
        }

        return true;
    }
};

void AddTacticsMirrorScripts()
{
    new TacticsMirrorWorldScript();
    new TacticsMirrorPlayerScript();
    new TacticsMirrorServerScript();
}
