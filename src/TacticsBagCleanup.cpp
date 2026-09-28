/*
 * Bot tactics - clean bags of a real player's bots on the "useful" loot mode (LootStrategyValue::KeepsBagsClean):
 * when a bot turns in a quest (its own turn-in or the mirrored one), the quest's reward items and leftover quest
 * items it does not need are thrown away (rare / epic ones are sold at the next vendor instead, sellGrey). "Need" = LootStrategyValue::IsNeeded: an upgrade, a quest item of
 * another quest, a consumable / ammo / trade good the bot uses, disenchant material. Gear the bot's auto-equip
 * takes off is thrown away by playerbots' EquipAction::EquipUpgrades.
 */

#include "Bag.h"
#include "Item.h"
#include "Log.h"
#include "LootStrategyValue.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "Playerbots.h"
#include "QuestDef.h"
#include "ScriptMgr.h"

#include <set>

namespace
{
    // Bags only: equipped items are never touched. Rare / epic items are kept for the vendor (sellGrey sells
    // soulbound unneeded ones).
    uint32 DestroyInBags(Player* bot, uint32 entry)
    {
        ItemTemplate const* proto = sObjectMgr->GetItemTemplate(entry);
        if (!proto || proto->Quality >= ITEM_QUALITY_RARE)
            return 0;

        uint32 destroyed = 0;
        for (uint8 slot = INVENTORY_SLOT_ITEM_START; slot < INVENTORY_SLOT_ITEM_END; ++slot)
        {
            Item* item = bot->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
            if (item && item->GetEntry() == entry)
            {
                destroyed += item->GetCount();
                bot->DestroyItem(INVENTORY_SLOT_BAG_0, slot, true);
            }
        }

        for (uint8 bagSlot = INVENTORY_SLOT_BAG_START; bagSlot < INVENTORY_SLOT_BAG_END; ++bagSlot)
        {
            Bag* bag = bot->GetBagByPos(bagSlot);
            if (!bag)
                continue;

            for (uint32 slot = 0; slot < bag->GetBagSize(); ++slot)
            {
                Item* item = bag->GetItemByPos(uint8(slot));
                if (item && item->GetEntry() == entry)
                {
                    destroyed += item->GetCount();
                    bot->DestroyItem(bagSlot, uint8(slot), true);
                }
            }
        }
        return destroyed;
    }
}

class TacticsBagCleanupPlayerScript : public PlayerScript
{
public:
    TacticsBagCleanupPlayerScript() : PlayerScript("TacticsBagCleanupPlayerScript", { PLAYERHOOK_ON_PLAYER_COMPLETE_QUEST }) { }

    // Runs at the END of Player::RewardQuest: the rewards are in the bags, the required items were taken.
    void OnPlayerCompleteQuest(Player* player, Quest const* quest) override
    {
        if (!quest || !player || !player->GetSession() || !player->GetSession()->IsBot())
            return;

        PlayerbotAI* ai = GET_PLAYERBOT_AI(player);
        if (!ai || !LootStrategyValue::KeepsBagsClean(ai))
            return;

        std::set<uint32> entries;
        for (uint8 i = 0; i < QUEST_REWARD_CHOICES_COUNT; ++i)
            entries.insert(quest->RewardChoiceItemId[i]);
        for (uint8 i = 0; i < QUEST_REWARDS_COUNT; ++i)
            entries.insert(quest->RewardItemId[i]);
        for (uint8 i = 0; i < QUEST_ITEM_OBJECTIVES_COUNT; ++i)
            entries.insert(quest->RequiredItemId[i]);
        for (uint8 i = 0; i < QUEST_SOURCE_ITEM_IDS_COUNT; ++i)
            entries.insert(quest->ItemDrop[i]);
        entries.erase(0);

        AiObjectContext* context = ai->GetAiObjectContext();
        for (uint32 entry : entries)
        {
            if (!sObjectMgr->GetItemTemplate(entry) || LootStrategyValue::IsNeeded(context, entry))
                continue;

            if (uint32 count = DestroyInBags(player, entry))
                LOG_DEBUG("module.tactics", "{}: quest {} - discards {} x {}", player->GetName(), quest->GetQuestId(),
                          count, entry);
        }
    }
};

void AddTacticsBagCleanupScripts()
{
    new TacticsBagCleanupPlayerScript();
}
