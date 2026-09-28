/*
 * Bot tactics - party window primitives, package P1 (TacticsInventory.h).
 *
 * Ported from the MultiBot bridge (mod-multibot-bridge/src/MultiBotBridge.cpp) with the checks the
 * party window spec adds: ownership re-check against the message player, world thread only, guid
 * staleness, combat / trade locks, real distance-checked NPC interaction and no money edits.
 * Every mutation is the packet a real client would send, handed to the bot's own session handler, and
 * is verified afterwards by re-reading the inventory.
 *
 *
 */

#include "TacticsInventory.h"
#include "TacticsEngine.h"
#include "TacticsPartyApi.h"

#include "AiObjectContext.h"
#include "Bag.h"
#include "CellImpl.h"
#include "Creature.h"
#include "GridNotifiers.h"
#include "GridNotifiersImpl.h"
#include "Item.h"
#include "ItemPackets.h"
#include "ItemUsageValue.h"
#include "LootStrategyValue.h"
#include "NPCPackets.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "Playerbots.h"
#include "QuestDef.h"
#include "QuestPackets.h"
#include "SpellInfo.h"
#include "SpellMgr.h"
#include "TradeData.h"
#include "Trainer.h"
#include "WorldPacket.h"
#include "WorldSession.h"

#include <algorithm>
#include <cmath>
#include <list>

namespace Tactics::Party
{
    namespace
    {
        constexpr float NPC_SEARCH_RADIUS = 12.0f;      // grid search; interaction itself is INTERACTION_DISTANCE
        constexpr uint32 HEARTHSTONE_ENTRY = 6948;
        constexpr uint32 MAX_LEARN_PASSES = 8;          // later ranks become teachable after earlier ones

        InvResult Fail(char const* reason)
        {
            InvResult r;
            r.reason = reason;
            return r;
        }

        InvResult Ok(int32 a = 0, int32 b = 0)
        {
            InvResult r;
            r.ok = true;
            r.reason = "ok";
            r.a = a;
            r.b = b;
            return r;
        }

        // Locale of the player whose call this is (message player, or the evaluating bot).
        LocaleConstant CallerLocale()
        {
            Lua::CallContext* call = Lua::CurrentCall();
            Player* anchor = call ? call->anchor : nullptr;
            if (!anchor || !anchor->GetSession())
                return LOCALE_enUS;

            LocaleConstant const locale = anchor->GetSession()->GetSessionDbcLocale();
            return locale < TOTAL_LOCALES ? locale : LOCALE_enUS;
        }

        // ------------------------------------------------------------------ interactable NPC (spec 2.1)
        class NpcFlagCheck
        {
        public:
            NpcFlagCheck(Player* bot, uint32 npcFlag) : _bot(bot), _npcFlag(npcFlag) { }

            bool operator()(Creature* creature) const
            {
                return creature->HasNpcFlag(NPCFlags(_npcFlag)) && !creature->IsHostileTo(_bot) &&
                       _bot->IsWithinDistInMap(creature, NPC_SEARCH_RADIUS);
            }

        private:
            Player* _bot;
            uint32 _npcFlag;
        };

        using NpcFilter = bool (*)(Player* bot, Creature* npc);

        // Nearest creature with the flag that the bot can really interact with now (distance, faction,
        // alive), optionally filtered (e.g. a trainer that teaches this bot).
        Creature* FindInteractableNpc(Player* bot, uint32 npcFlag, NpcFilter filter = nullptr)
        {
            if (!bot || !bot->IsInWorld())
                return nullptr;

            std::list<Creature*> found;
            NpcFlagCheck check(bot, npcFlag);
            Acore::CreatureListSearcher<NpcFlagCheck> searcher(bot, found, check);
            Cell::VisitObjects(bot, searcher, NPC_SEARCH_RADIUS);

            Creature* best = nullptr;
            float bestDist = 0.0f;
            for (Creature* creature : found)
            {
                Creature* npc = bot->GetNPCIfCanInteractWith(creature->GetGUID(), npcFlag);
                if (!npc || (filter && !filter(bot, npc)))
                    continue;

                float const dist = bot->GetDistance(npc);
                if (!best || dist < bestDist)
                {
                    best = npc;
                    bestDist = dist;
                }
            }

            return best;
        }

        bool TrainerTeachesBot(Player* bot, Creature* npc)
        {
            Trainer::Trainer* trainer = sObjectMgr->GetTrainer(npc->GetEntry());
            return trainer && trainer->IsTrainerValidForPlayer(bot);
        }

        // Banker lookup done at most once per primitive call.
        class BankerLookup
        {
        public:
            explicit BankerLookup(Player* bot) : _bot(bot) { }

            Creature* Get()
            {
                if (!_done)
                {
                    _banker = FindInteractableNpc(_bot, UNIT_NPC_FLAG_BANKER);
                    _done = true;
                }

                return _banker;
            }

        private:
            Player* _bot;
            Creature* _banker = nullptr;
            bool _done = false;
        };

        // ------------------------------------------------------------------ item facts
        bool IsQuestUsage(Player* bot, Item* item)
        {
            PlayerbotAI* ai = GET_PLAYERBOT_AI(bot);
            AiObjectContext* context = ai ? ai->GetAiObjectContext() : nullptr;
            return context && context->GetValue<ItemUsage>("item usage", item->GetEntry())->Get() == ITEM_USAGE_QUEST;
        }

        // Quest item, key or hearthstone: never sold (MB L7916-7928).
        bool IsProtectedFromSale(Player* bot, Item* item)
        {
            ItemTemplate const* proto = item->GetTemplate();
            return proto->Class == ITEM_CLASS_QUEST || proto->Class == ITEM_CLASS_KEY ||
                   item->GetEntry() == HEARTHSTONE_ENTRY || IsQuestUsage(bot, item);
        }

        // Rare / epic gear a bot on the "useful" loot mode keeps for the vendor instead of throwing it away (gear its
        // auto-equip replaced, quest rewards): soulbound - nobody else can use it - and not needed by the bot.
        bool IsUnneededBoundGear(Player* bot, Item* item, ItemTemplate const* proto)
        {
            if (proto->Quality < ITEM_QUALITY_RARE || !item->IsSoulBound() ||
                (proto->Class != ITEM_CLASS_ARMOR && proto->Class != ITEM_CLASS_WEAPON))
                return false;

            PlayerbotAI* ai = GET_PLAYERBOT_AI(bot);
            return ai && LootStrategyValue::KeepsBagsClean(ai) &&
                   !LootStrategyValue::IsNeeded(ai->GetAiObjectContext(), proto->ItemId);
        }

        // MB L5524 IsBridgeSellGreyCandidate, plus IsUnneededBoundGear.
        bool IsSellGreyCandidate(Player* bot, Item* item)
        {
            ItemTemplate const* proto = item ? item->GetTemplate() : nullptr;
            if (!proto || !proto->SellPrice || item->IsEquipped())
                return false;

            if (proto->Quality != ITEM_QUALITY_POOR && !IsUnneededBoundGear(bot, item, proto))
                return false;

            return !item->IsNotEmptyBag() && !IsProtectedFromSale(bot, item);
        }

        // Equipment slots the item could be equipped into right now, "a:b".
        std::string FitsSlots(Player* bot, Item* item)
        {
            std::string fits;
            ItemTemplate const* proto = item->GetTemplate();
            if (item->IsBag() || bot->CanUseItem(item) != EQUIP_ERR_OK ||
                bot->FindEquipSlot(proto, NULL_SLOT, true) == NULL_SLOT)
                return fits;

            for (uint8 slot = EQUIPMENT_SLOT_START; slot < EQUIPMENT_SLOT_END; ++slot)
            {
                if (bot->FindEquipSlot(proto, slot, true) != slot)
                    continue;

                uint16 dest = 0;
                if (bot->CanEquipItem(slot, dest, item, true) != EQUIP_ERR_OK)
                    continue;

                if (!fits.empty())
                    fits += ':';
                fits += std::to_string(slot);
            }

            return fits;
        }

        // ------------------------------------------------------------------ positions (MB L3780 / L3802)
        enum PosKind : uint8
        {
            POS_NONE    = 0,
            POS_EQUIP   = 1,        // 255, 0..18
            POS_BAGS    = 2,        // backpack 255, 23..38 and equipped bags 19..22
            POS_KEYRING = 4,        // 255, 86..
            POS_BANK    = 8         // bank 255, 39..66 and bank bags 67..73 (need an interactable banker)
        };

        PosKind Classify(Player* bot, uint8 bag, uint8 slot)
        {
            if (bag == INVENTORY_SLOT_BAG_0)
            {
                if (slot < EQUIPMENT_SLOT_END)
                    return POS_EQUIP;
                if (slot >= INVENTORY_SLOT_ITEM_START && slot < INVENTORY_SLOT_ITEM_END)
                    return POS_BAGS;
                if (slot >= BANK_SLOT_ITEM_START && slot < BANK_SLOT_ITEM_END)
                    return POS_BANK;
                if (slot >= KEYRING_SLOT_START && uint32(slot) < uint32(KEYRING_SLOT_START) + bot->GetMaxKeyringSize())
                    return POS_KEYRING;
                return POS_NONE;
            }

            bool const inventoryBag = bag >= INVENTORY_SLOT_BAG_START && bag < INVENTORY_SLOT_BAG_END;
            bool const bankBag = bag >= BANK_SLOT_BAG_START && bag < BANK_SLOT_BAG_END;
            if (!inventoryBag && !bankBag)
                return POS_NONE;

            Bag* container = bot->GetBagByPos(bag);
            if (!container || uint32(slot) >= container->GetBagSize())
                return POS_NONE;

            return inventoryBag ? POS_BAGS : POS_BANK;
        }

        enum class Op : uint8 { None, Equip, Unequip, Use, Sell, Destroy, Move, Give, Deposit, Withdraw };

        Op ParseOp(std::string const& op)
        {
            static std::pair<char const*, Op> const ops[] = {
                { "equip", Op::Equip }, { "unequip", Op::Unequip }, { "use", Op::Use }, { "sell", Op::Sell },
                { "destroy", Op::Destroy }, { "move", Op::Move }, { "give", Op::Give }, { "deposit", Op::Deposit },
                { "withdraw", Op::Withdraw } };

            for (auto const& [name, value] : ops)
                if (op == name)
                    return value;

            return Op::None;
        }

        // Source positions allowed per op.
        uint8 SourceKinds(Op op)
        {
            switch (op)
            {
                case Op::Equip:
                case Op::Sell:
                case Op::Deposit:
                    return POS_BAGS;
                case Op::Unequip:
                    return POS_EQUIP;
                case Op::Use:
                    return POS_BAGS | POS_EQUIP;                  // on-use trinkets / equipped items too
                case Op::Destroy:
                    return POS_BAGS | POS_KEYRING | POS_EQUIP | POS_BANK;
                case Op::Move:
                    return POS_BAGS | POS_KEYRING | POS_BANK;
                case Op::Give:
                    return POS_BAGS | POS_KEYRING;
                case Op::Withdraw:
                    return POS_BANK;
                default:
                    return POS_NONE;
            }
        }

        bool BlockedByTrade(Op op)
        {
            return op != Op::Use && op != Op::Give;
        }

        // ------------------------------------------------------------------ move bookkeeping (MB L3825-3856)
        struct PosState
        {
            bool present = false;
            uint32 guidLow = 0;
            uint32 entry = 0;
            uint32 count = 0;

            bool operator==(PosState const& o) const
            {
                return present == o.present && guidLow == o.guidLow && entry == o.entry && count == o.count;
            }
        };

        PosState ReadPos(Player* bot, uint8 bag, uint8 slot)
        {
            PosState state;
            if (Item* item = bot->GetItemByPos(bag, slot))
            {
                state.present = true;
                state.guidLow = item->GetGUID().GetCounter();
                state.entry = item->GetEntry();
                state.count = item->GetCount();
            }

            return state;
        }

        // ------------------------------------------------------------------ single ops
        InvResult DoEquip(Player* bot, uint8 bag, uint8 slot, Item* item)
        {
            ItemTemplate const* proto = item->GetTemplate();
            if (item->IsBag() || proto->InventoryType == INVTYPE_AMMO || bot->CanUseItem(item) != EQUIP_ERR_OK ||
                bot->FindEquipSlot(proto, NULL_SLOT, true) == NULL_SLOT)
                return Fail("cannot");

            ObjectGuid const guid = item->GetGUID();

            // An out-of-combat buff cast (paladin blessings etc.) makes the core answer "can't do that right now";
            // a player's equip order wins over it (item actions are refused in combat before this point).
            if (bot->IsNonMeleeSpellCast(false))
                bot->InterruptNonMeleeSpells(false);

            // MB L7469
            WorldPacket packet(CMSG_AUTOEQUIP_ITEM, 2);
            packet << bag << slot;
            WorldPackets::Item::AutoEquipItem autoEquip(std::move(packet));
            autoEquip.Read();
            bot->GetSession()->HandleAutoEquipItemOpcode(autoEquip);

            Item* equipped = bot->GetItemByGuid(guid);
            if (!equipped || equipped->GetBagSlot() != INVENTORY_SLOT_BAG_0 || equipped->GetSlot() >= EQUIPMENT_SLOT_END)
                return Fail("failed");

            return Ok(equipped->GetSlot());
        }

        InvResult DoUnequip(Player* bot, uint8 slot, Item* item)
        {
            if (bot->CanUnequipItem(item->GetPos(), true) != EQUIP_ERR_OK)
                return Fail("cannot");

            ItemPosCountVec dest;
            if (bot->CanStoreItem(NULL_BAG, NULL_SLOT, dest, item, false) != EQUIP_ERR_OK)
                return Fail("full");

            ObjectGuid const guid = item->GetGUID();

            if (bot->IsNonMeleeSpellCast(false))   // see DoEquip
                bot->InterruptNonMeleeSpells(false);

            // MB L7567
            WorldPacket packet(CMSG_AUTOSTORE_BAG_ITEM, 3);
            packet << uint8(INVENTORY_SLOT_BAG_0) << slot << uint8(NULL_BAG);
            WorldPackets::Item::AutoStoreBagItem autoStore(std::move(packet));
            autoStore.Read();
            bot->GetSession()->HandleAutoStoreBagItemOpcode(autoStore);

            Item* stored = bot->GetItemByGuid(guid);
            if (!stored || Player::IsEquipmentPos(stored->GetPos()))
                return Fail("failed");

            return Ok(stored->GetBagSlot(), stored->GetSlot());
        }

        // Items that need an item / game object / trade slot target are not supported by DoUse.
        constexpr uint32 UNSUPPORTED_USE_TARGETS = TARGET_FLAG_ITEM | TARGET_FLAG_GAMEOBJECT | TARGET_FLAG_TRADE_ITEM;

        // The static part of DoUse (no bot state): a quest starter, or an on-use spell DoUse can cast.
        // Drives the snapshot's 'u' flag, so the addon never offers a use that always fails.
        bool UseSupported(Item* item)
        {
            ItemTemplate const* proto = item->GetTemplate();
            if (item->IsBag() || proto->Class == ITEM_CLASS_GEM)
                return false;

            if (proto->StartQuest && sObjectMgr->GetQuestTemplate(proto->StartQuest))
                return true;

            uint32 const spellId = ItemUseSpell(item);
            SpellInfo const* spellInfo = spellId ? sSpellMgr->GetSpellInfo(spellId) : nullptr;
            return spellInfo && !(spellInfo->Targets & UNSUPPORTED_USE_TARGETS);
        }

        InvResult DoUse(Player* bot, uint8 bag, uint8 slot, Item* item)
        {
            ItemTemplate const* proto = item->GetTemplate();
            if (item->IsBag() || bot->CanUseItem(item) != EQUIP_ERR_OK || proto->Class == ITEM_CLASS_GEM)
                return Fail("cannot");

            if (bot->IsNonMeleeSpellCast(false))
                return Fail("busy");

            // Quest starter item (MB L7762): accept the quest it starts.
            if (proto->StartQuest && sObjectMgr->GetQuestTemplate(proto->StartQuest))
            {
                uint32 const questId = proto->StartQuest;
                QuestStatus const before = bot->GetQuestStatus(questId);

                WorldPacket packet(CMSG_QUESTGIVER_ACCEPT_QUEST, 8 + 4 + 4);
                packet << item->GetGUID() << questId << uint32(0);
                bot->GetSession()->HandleQuestgiverAcceptQuestOpcode(packet);

                if (before == QUEST_STATUS_NONE && bot->GetQuestStatus(questId) != QUEST_STATUS_NONE)
                    return Ok();

                return Fail("failed");
            }

            uint32 const spellId = ItemUseSpell(item);
            SpellInfo const* spellInfo = spellId ? sSpellMgr->GetSpellInfo(spellId) : nullptr;
            if (!spellInfo)
                return Fail("cannot");

            if (spellInfo->Targets & UNSUPPORTED_USE_TARGETS)
                return Fail("cannot");

            PlayerbotAI* ai = GET_PLAYERBOT_AI(bot);
            if (!ai || !ai->CanCastSpell(spellId, bot, false, nullptr, item))
                return Fail("cannot");

            bot->ClearUnitState(UNIT_STATE_CHASE);
            bot->ClearUnitState(UNIT_STATE_FOLLOW);
            if (bot->isMoving())
            {
                bot->StopMoving();
                return Fail("moving");                        // the addon retries after 1 s
            }

            ObjectGuid const guid = item->GetGUID();
            uint32 const countBefore = item->GetCount();
            bool const hadCooldown = bot->HasSpellCooldown(spellId);
            SendUseItem(bot, bag, slot, item, spellId, 0);

            // MB L7829-7833: consumed, cooldown started or cast in progress.
            Item* after = bot->GetItemByGuid(guid);
            bool const consumed = !after || after->GetCount() < countBefore;
            bool const cooldownStarted = !hadCooldown && bot->HasSpellCooldown(spellId);
            if (consumed || cooldownStarted || bot->IsNonMeleeSpellCast(false))
                return Ok();

            return Fail("failed");
        }

        InvResult DoSell(Player* bot, uint8 bag, uint8 slot, Item* item, uint32 count)
        {
            ItemTemplate const* proto = item->GetTemplate();
            if (!proto->SellPrice || item->IsNotEmptyBag() || IsProtectedFromSale(bot, item) || count > item->GetCount())
                return Fail("cannot");

            Creature* vendor = FindInteractableNpc(bot, UNIT_NPC_FLAG_VENDOR);
            if (!vendor)
                return Fail("no_vendor");

            ObjectGuid const guid = item->GetGUID();
            uint32 const countBefore = item->GetCount();
            uint32 const moneyBefore = bot->GetMoney();

            // MB L7939 (count 0 = whole stack). No gold-cheat money restore (spec 2.4).
            WorldPacket packet(CMSG_SELL_ITEM, 8 + 8 + 4);
            packet << vendor->GetGUID() << guid << count;
            WorldPackets::Item::SellItem sell(std::move(packet));
            sell.Read();
            bot->GetSession()->HandleSellItemOpcode(sell);

            Item* after = bot->GetItemByPos(bag, slot);
            uint32 sold = 0;
            if (!after || after->GetGUID() != guid)
                sold = countBefore;
            else if (after->GetCount() < countBefore)
                sold = countBefore - after->GetCount();

            if (!sold)
                return Fail("failed");

            return Ok(int32(sold), int32(int64(bot->GetMoney()) - int64(moneyBefore)));
        }

        InvResult DoDestroy(Player* bot, uint8 bag, uint8 slot, Item* item)
        {
            if (item->IsNotEmptyBag() || item->GetTemplate()->HasFlag(ITEM_FLAG_NO_USER_DESTROY))
                return Fail("cannot");

            ObjectGuid const guid = item->GetGUID();

            // MB L7666 (count 0 = whole stack)
            WorldPacket packet(CMSG_DESTROYITEM, 6);
            packet << bag << slot << uint8(0) << uint8(0) << uint8(0) << uint8(0);
            WorldPackets::Item::DestroyItem destroy(std::move(packet));
            destroy.Read();
            bot->GetSession()->HandleDestroyItemOpcode(destroy);

            return bot->GetItemByGuid(guid) ? Fail("failed") : Ok();
        }

        InvResult DoMove(Player* bot, uint8 srcBag, uint8 srcSlot, uint8 dstBag, uint8 dstSlot)
        {
            PosState const beforeSrc = ReadPos(bot, srcBag, srcSlot);
            PosState const beforeDst = ReadPos(bot, dstBag, dstSlot);
            Item* source = bot->GetItemByPos(srcBag, srcSlot);
            Item* destination = bot->GetItemByPos(dstBag, dstSlot);

            // Merge rule (MB L7085): a stack merge must fit completely, partial stacks are not supported.
            bool merge = false;
            uint32 mergedCount = 0;
            if (destination && !source->IsBag() && !destination->IsBag())
            {
                ItemPosCountVec mergeDest;
                if (bot->CanStoreItem(dstBag, dstSlot, mergeDest, source, false) == EQUIP_ERR_OK)
                {
                    uint64 const combined = uint64(beforeSrc.count) + beforeDst.count;
                    if (combined > source->GetMaxStackCount())
                        return Fail("cannot");

                    merge = true;
                    mergedCount = uint32(combined);
                }
            }

            // MB L7111: no client packet carries a validated swap for a bot; SwapItem runs the same checks.
            bot->SwapItem(uint16(srcBag) << 8 | srcSlot, uint16(dstBag) << 8 | dstSlot);

            PosState const afterSrc = ReadPos(bot, srcBag, srcSlot);
            PosState const afterDst = ReadPos(bot, dstBag, dstSlot);

            bool done = false;
            if (!beforeDst.present)
                done = !afterSrc.present && afterDst == beforeSrc;
            else if (merge)
                done = !afterSrc.present && afterDst.present && afterDst.entry == beforeSrc.entry &&
                       afterDst.count == mergedCount;
            else
                done = afterSrc == beforeDst && afterDst == beforeSrc;

            return done ? Ok() : Fail("failed");
        }

        InvResult DoGive(Player* bot, uint8 bag, uint8 slot, Item* item)
        {
            Player* owner = GetOwner(bot);
            TradeData* botTrade = bot->GetTradeData();
            TradeData* ownerTrade = owner ? owner->GetTradeData() : nullptr;
            if (!botTrade || !ownerTrade || botTrade->GetTrader() != owner || ownerTrade->GetTrader() != bot)
                return Fail("no_trade");

            ObjectGuid const guid = item->GetGUID();
            if (botTrade->HasItem(guid))
                return Fail("already");

            if (!item->CanBeTraded(false, true) || item->IsBindedNotWith(owner))
                return Fail("not_tradable");

            uint8 tradeSlot = TRADE_SLOT_TRADED_COUNT;
            for (uint8 candidate = 0; candidate < TRADE_SLOT_TRADED_COUNT; ++candidate)
            {
                if (!botTrade->GetItem(TradeSlots(candidate)))
                {
                    tradeSlot = candidate;
                    break;
                }
            }

            if (tradeSlot >= TRADE_SLOT_TRADED_COUNT)
                return Fail("full");

            // MB L7377
            WorldPacket packet(CMSG_SET_TRADE_ITEM, 3);
            packet << tradeSlot << bag << slot;
            bot->GetSession()->HandleSetTradeItemOpcode(packet);

            TradeData* trade = bot->GetTradeData();
            Item* traded = trade && trade->GetTrader() == owner ? trade->GetItem(TradeSlots(tradeSlot)) : nullptr;
            if (!traded || traded->GetGUID() != guid)
                return Fail("failed");

            return Ok(tradeSlot);
        }

        // Same steps as WorldSession::HandleAutoBankItemOpcode minus its banker-session check (a bot
        // session never "opened" a bank window); the banker distance is checked by the caller.
        InvResult DoDeposit(Player* bot, uint8 bag, uint8 slot, Item* item)
        {
            ItemPosCountVec dest;
            if (bot->CanBankItem(NULL_BAG, NULL_SLOT, dest, item, false) != EQUIP_ERR_OK)
                return Fail("full");

            ObjectGuid const guid = item->GetGUID();
            bot->RemoveItem(bag, slot, true);
            bot->ItemRemovedQuestCheck(item->GetEntry(), item->GetCount());
            bot->BankItem(dest, item, true);                   // may merge and delete `item`
            bot->UpdateTitansGrip();

            Item* remaining = bot->GetItemByPos(bag, slot);
            return remaining && remaining->GetGUID() == guid ? Fail("failed") : Ok();
        }

        // WorldSession::HandleAutoStoreBankItemOpcode, bank -> inventory branch.
        InvResult DoWithdraw(Player* bot, uint8 bag, uint8 slot, Item* item)
        {
            ItemPosCountVec dest;
            if (bot->CanStoreItem(NULL_BAG, NULL_SLOT, dest, item, false) != EQUIP_ERR_OK)
                return Fail("full");

            ObjectGuid const guid = item->GetGUID();
            bot->RemoveItem(bag, slot, true);
            if (Item const* stored = bot->StoreItem(dest, item, true))   // may merge and delete `item`
                bot->ItemAddedQuestCheck(stored->GetEntry(), stored->GetCount());

            Item* remaining = bot->GetItemByPos(bag, slot);
            return remaining && remaining->GetGUID() == guid ? Fail("failed") : Ok();
        }

        // ------------------------------------------------------------------ trainer helpers
        Creature* FindTrainer(Player* bot)
        {
            return FindInteractableNpc(bot, UNIT_NPC_FLAG_TRAINER, &TrainerTeachesBot);
        }

        void CollectTrainerSpells(Player* bot, Creature* npc, Trainer::Trainer* trainer, std::vector<TrainerSpellRow>& out)
        {
            float const discount = bot->GetReputationPriceDiscount(npc);
            uint32 const money = bot->GetMoney();
            for (Trainer::Spell const& spell : trainer->GetSpells())
            {
                if (!sSpellMgr->GetSpellInfo(spell.SpellId) || !trainer->CanTeachSpell(bot, &spell))
                    continue;

                TrainerSpellRow row;
                row.spell = spell.SpellId;
                row.cost = uint32(std::floor(spell.MoneyCost * discount));   // MB L4579, same as Trainer::TeachSpell
                row.canLearn = row.cost <= money;
                out.push_back(row);
            }
        }
    }

    // ------------------------------------------------------------------ ownership
    char const* CheckOwned(Player* bot)
    {
        Player* requester = Lua::MessagePlayer();
        if (!requester)
            return "wrong_thread";

        if (!bot || !bot->IsInWorld() || !bot->GetSession() || !GET_PLAYERBOT_AI(bot))
            return "bad_bot";

        return GetOwner(bot) == requester ? nullptr : "bad_bot";
    }

    // ------------------------------------------------------------------ 2.2 snapshot
    InvResult Snapshot(Player* bot, SnapshotOut& out)
    {
        if (char const* reason = CheckOwned(bot))
            return Fail(reason);

        out = SnapshotOut();
        out.money = bot->GetMoney();

        Creature* banker = FindInteractableNpc(bot, UNIT_NPC_FLAG_BANKER);
        if (banker)
            out.flags += 'b';
        if (FindInteractableNpc(bot, UNIT_NPC_FLAG_VENDOR))
            out.flags += 'v';
        if (FindInteractableNpc(bot, UNIT_NPC_FLAG_REPAIR))
            out.flags += 'r';
        if (FindTrainer(bot))
            out.flags += 't';
        if (bot->IsInCombat())
            out.flags += 'c';
        if (!bot->IsAlive())
            out.flags += 'd';
        if (bot->GetTradeData())
            out.flags += 'x';
        if (bot->isMoving())
            out.flags += 'm';

        // Containers in the order of spec 2.2 (positions: Player.h InventorySlots / BankItemSlots / KeyRingSlots).
        out.containers.push_back({ 'E', INVENTORY_SLOT_BAG_0, EQUIPMENT_SLOT_START, EQUIPMENT_SLOT_END - EQUIPMENT_SLOT_START, 0 });
        out.containers.push_back({ 'B', INVENTORY_SLOT_BAG_0, INVENTORY_SLOT_ITEM_START,
                                   INVENTORY_SLOT_ITEM_END - INVENTORY_SLOT_ITEM_START, 0 });
        for (uint8 bag = INVENTORY_SLOT_BAG_START; bag < INVENTORY_SLOT_BAG_END; ++bag)
            if (Bag* container = bot->GetBagByPos(bag))
                out.containers.push_back({ 'G', bag, 0, uint8(container->GetBagSize()), container->GetEntry() });
        out.containers.push_back({ 'K', INVENTORY_SLOT_BAG_0, KEYRING_SLOT_START, uint8(bot->GetMaxKeyringSize()), 0 });
        if (banker)
        {
            out.containers.push_back({ 'N', INVENTORY_SLOT_BAG_0, BANK_SLOT_ITEM_START,
                                       BANK_SLOT_ITEM_END - BANK_SLOT_ITEM_START, 0 });
            for (uint8 bag = BANK_SLOT_BAG_START; bag < BANK_SLOT_BAG_END; ++bag)
                if (Bag* container = bot->GetBagByPos(bag))
                    out.containers.push_back({ 'H', bag, 0, uint8(container->GetBagSize()), container->GetEntry() });
        }

        for (ContainerRow const& c : out.containers)
        {
            for (uint32 i = 0; i < c.size; ++i)
            {
                uint8 const slot = uint8(c.start + i);
                Item* item = bot->GetItemByPos(c.bag, slot);
                ItemTemplate const* proto = item ? item->GetTemplate() : nullptr;
                if (!proto)
                    continue;

                ItemRow row;
                row.bag = c.bag;
                row.slot = slot;
                row.guidLow = item->GetGUID().GetCounter();
                row.entry = item->GetEntry();
                row.count = item->GetCount();
                row.enchant = item->GetEnchantmentId(PERM_ENCHANTMENT_SLOT);
                for (uint8 g = 0; g < 3; ++g)
                    row.gem[g] = item->GetEnchantmentId(EnchantmentSlot(SOCK_ENCHANTMENT_SLOT + g));
                row.randomProperty = item->GetItemRandomPropertyId();
                row.suffixFactor = item->GetItemSuffixFactor();
                row.durability = item->GetUInt32Value(ITEM_FIELD_DURABILITY);
                row.maxDurability = item->GetUInt32Value(ITEM_FIELD_MAXDURABILITY);

                if (item->IsSoulBound())
                    row.flags += 's';
                // Item usage is a playerbots calculation: skipped for worn equipment.
                if (proto->Class == ITEM_CLASS_QUEST || (c.kind != 'E' && IsQuestUsage(bot, item)))
                    row.flags += 'q';
                if (proto->Class == ITEM_CLASS_KEY)
                    row.flags += 'k';
                if (item->GetEntry() == HEARTHSTONE_ENTRY)
                    row.flags += 'h';
                if (!item->CanBeTraded(false, true))
                    row.flags += 'x';
                if (proto->HasFlag(ITEM_FLAG_NO_USER_DESTROY))
                    row.flags += 'n';
                if (proto->SellPrice > 0)
                    row.flags += 'p';
                if (item->IsBag())
                    row.flags += 'b';
                if (item->IsNotEmptyBag())
                    row.flags += 'e';
                if (UseSupported(item))                        // spec 2.2 says ItemUseSpell != 0; see UseSupported
                    row.flags += 'u';

                // Only items the bot carries can be equipped directly.
                if (c.kind == 'B' || c.kind == 'G')
                    row.fits = FitsSlots(bot, item);

                out.items.push_back(std::move(row));
            }
        }

        return Ok();
    }

    // ------------------------------------------------------------------ 2.3 item actions
    InvResult ItemAction(Player* bot, std::string const& op, uint8 bag, uint8 slot, uint32 guidLow, uint32 a, uint32 b)
    {
        if (char const* reason = CheckOwned(bot))
            return Fail(reason);

        Op const kind = ParseOp(op);
        if (kind == Op::None)
            return Fail("bad_op");

        if (!bot->IsAlive())
            return Fail("dead");

        BankerLookup banker(bot);
        PosKind const src = Classify(bot, bag, slot);
        if (!(SourceKinds(kind) & src))
            return Fail("bad_pos");
        if (src == POS_BANK && !banker.Get())
            return Fail("no_banker");

        uint8 dstBag = 0;
        uint8 dstSlot = 0;
        if (kind == Op::Move)
        {
            if (a > 255 || b > 255)
                return Fail("bad_pos");

            dstBag = uint8(a);
            dstSlot = uint8(b);
            PosKind const dst = Classify(bot, dstBag, dstSlot);
            if (!(SourceKinds(Op::Move) & dst) || (dstBag == bag && dstSlot == slot))
                return Fail("bad_pos");
            if (dst == POS_BANK && !banker.Get())
                return Fail("no_banker");
        }

        Item* item = bot->GetItemByPos(bag, slot);
        if (!item || !item->GetTemplate() || item->GetGUID().GetCounter() != guidLow)
            return Fail("stale");

        if (kind != Op::Use && bot->IsInCombat())
            return Fail("combat");

        if (BlockedByTrade(kind) && bot->GetTradeData())
            return Fail("trading");

        switch (kind)
        {
            case Op::Equip:
                return DoEquip(bot, bag, slot, item);
            case Op::Unequip:
                return DoUnequip(bot, slot, item);
            case Op::Use:
                return DoUse(bot, bag, slot, item);
            case Op::Sell:
                return DoSell(bot, bag, slot, item, a);
            case Op::Destroy:
                return DoDestroy(bot, bag, slot, item);
            case Op::Move:
                return DoMove(bot, bag, slot, dstBag, dstSlot);
            case Op::Give:
                return DoGive(bot, bag, slot, item);
            case Op::Deposit:
                return banker.Get() ? DoDeposit(bot, bag, slot, item) : Fail("no_banker");
            case Op::Withdraw:
                return DoWithdraw(bot, bag, slot, item);      // banker checked with the position
            default:
                return Fail("bad_op");
        }
    }

    // ------------------------------------------------------------------ 2.4 sell grey (MB L5581)
    InvResult SellGrey(Player* bot)
    {
        if (char const* reason = CheckOwned(bot))
            return Fail(reason);

        if (!bot->IsAlive())
            return Fail("dead");

        if (bot->IsInCombat())
            return Fail("combat");

        if (bot->GetTradeData())
            return Fail("trading");

        Creature* vendor = FindInteractableNpc(bot, UNIT_NPC_FLAG_VENDOR);
        if (!vendor)
            return Fail("no_vendor");

        // Snapshot candidate guids first: selling mutates the bags being iterated.
        std::vector<ObjectGuid> candidates;
        for (uint8 slot = INVENTORY_SLOT_ITEM_START; slot < INVENTORY_SLOT_ITEM_END; ++slot)
        {
            Item* item = bot->GetItemByPos(INVENTORY_SLOT_BAG_0, slot);
            if (IsSellGreyCandidate(bot, item))
                candidates.push_back(item->GetGUID());
        }

        for (uint8 bag = INVENTORY_SLOT_BAG_START; bag < INVENTORY_SLOT_BAG_END; ++bag)
        {
            Bag* container = bot->GetBagByPos(bag);
            if (!container)
                continue;

            for (uint32 slot = 0; slot < container->GetBagSize(); ++slot)
            {
                Item* item = container->GetItemByPos(uint8(slot));
                if (IsSellGreyCandidate(bot, item))
                    candidates.push_back(item->GetGUID());
            }
        }

        if (candidates.empty())
            return Ok(0, 0);

        uint32 const moneyBefore = bot->GetMoney();
        int32 sold = 0;
        for (ObjectGuid const& guid : candidates)
        {
            Item* item = bot->GetItemByGuid(guid);
            if (!IsSellGreyCandidate(bot, item))
                continue;

            WorldPacket packet(CMSG_SELL_ITEM, 8 + 8 + 4);
            packet << vendor->GetGUID() << guid << uint32(0);
            WorldPackets::Item::SellItem sell(std::move(packet));
            sell.Read();
            bot->GetSession()->HandleSellItemOpcode(sell);

            if (!bot->GetItemByGuid(guid))
                ++sold;
        }

        if (!sold)
            return Fail("failed");

        return Ok(sold, int32(int64(bot->GetMoney()) - int64(moneyBefore)));
    }

    // ------------------------------------------------------------------ 2.5 stats
    void Stats(Player* bot, std::map<std::string, double>& out)
    {
        static char const* const statNames[MAX_STATS] = { "str", "agi", "sta", "int", "spi" };
        for (uint8 i = 0; i < MAX_STATS; ++i)
        {
            ::Stats const stat = ::Stats(STAT_STRENGTH + i);
            std::string const name = statNames[i];
            out[name] = bot->GetStat(stat);
            out[name + "_pos"] = bot->GetPosStat(stat);
            out[name + "_neg"] = bot->GetNegStat(stat);
        }

        out["armor"] = bot->GetArmor();
        for (uint8 i = SPELL_SCHOOL_HOLY; i < MAX_SPELL_SCHOOL; ++i)
            out["res" + std::to_string(i)] = bot->GetResistance(SpellSchools(i));

        out["ap"] = bot->GetTotalAttackPowerValue(BASE_ATTACK);
        out["rap"] = bot->GetTotalAttackPowerValue(RANGED_ATTACK);
        out["dmg_min"] = bot->GetFloatValue(UNIT_FIELD_MINDAMAGE);
        out["dmg_max"] = bot->GetFloatValue(UNIT_FIELD_MAXDAMAGE);
        out["oh_min"] = bot->GetFloatValue(UNIT_FIELD_MINOFFHANDDAMAGE);
        out["oh_max"] = bot->GetFloatValue(UNIT_FIELD_MAXOFFHANDDAMAGE);
        out["speed"] = bot->GetAttackTime(BASE_ATTACK) / 1000.0;
        out["oh_speed"] = bot->GetAttackTime(OFF_ATTACK) / 1000.0;
        out["r_min"] = bot->GetFloatValue(UNIT_FIELD_MINRANGEDDAMAGE);
        out["r_max"] = bot->GetFloatValue(UNIT_FIELD_MAXRANGEDDAMAGE);
        out["r_speed"] = bot->GetAttackTime(RANGED_ATTACK) / 1000.0;
        out["crit"] = bot->GetFloatValue(PLAYER_CRIT_PERCENTAGE);
        out["r_crit"] = bot->GetFloatValue(PLAYER_RANGED_CRIT_PERCENTAGE);

        double spellCrit = 0.0;
        int32 spellPower = 0;
        for (uint8 i = SPELL_SCHOOL_HOLY; i < MAX_SPELL_SCHOOL; ++i)
        {
            double const crit = bot->GetFloatValue(PLAYER_SPELL_CRIT_PERCENTAGE1 + i);
            spellCrit = i == SPELL_SCHOOL_HOLY ? crit : std::min(spellCrit, crit);
            spellPower = std::max(spellPower, bot->SpellBaseDamageBonusDone(SpellSchoolMask(1 << i)));
        }

        out["s_crit"] = spellCrit;
        out["sp"] = spellPower;
        out["heal"] = bot->SpellBaseHealingBonusDone(SPELL_SCHOOL_MASK_ALL);
        out["mp5"] = bot->GetFloatValue(UNIT_FIELD_POWER_REGEN_FLAT_MODIFIER + POWER_MANA) * 5.0;
        out["mp5_cast"] = bot->GetFloatValue(UNIT_FIELD_POWER_REGEN_INTERRUPTED_FLAT_MODIFIER + POWER_MANA) * 5.0;
        out["defense"] = bot->GetSkillValue(SKILL_DEFENSE);
        out["dodge"] = bot->GetFloatValue(PLAYER_DODGE_PERCENTAGE);
        out["parry"] = bot->GetFloatValue(PLAYER_PARRY_PERCENTAGE);
        out["block"] = bot->GetFloatValue(PLAYER_BLOCK_PERCENTAGE);
        out["block_value"] = bot->GetShieldBlockValue();
        out["expertise"] = bot->GetUInt32Value(PLAYER_EXPERTISE);
        out["ilvl"] = bot->GetAverageItemLevel();

        PlayerbotAI* ai = GET_PLAYERBOT_AI(bot);
        out["gs"] = ai ? ai->GetEquipGearScore(bot) : 0;
        out["level"] = bot->GetLevel();
        out["money"] = bot->GetMoney();

        static std::pair<CombatRating, char const*> const ratings[] = {
            { CR_DEFENSE_SKILL, "defense" }, { CR_DODGE, "dodge" }, { CR_PARRY, "parry" }, { CR_BLOCK, "block" },
            { CR_HIT_MELEE, "hit_melee" }, { CR_HIT_RANGED, "hit_ranged" }, { CR_HIT_SPELL, "hit_spell" },
            { CR_CRIT_MELEE, "crit_melee" }, { CR_CRIT_RANGED, "crit_ranged" }, { CR_CRIT_SPELL, "crit_spell" },
            { CR_CRIT_TAKEN_MELEE, "resilience" }, { CR_HASTE_MELEE, "haste_melee" },
            { CR_HASTE_RANGED, "haste_ranged" }, { CR_HASTE_SPELL, "haste_spell" }, { CR_EXPERTISE, "expertise" },
            { CR_ARMOR_PENETRATION, "arpen" } };

        for (auto const& [cr, name] : ratings)
        {
            out[std::string("cr_") + name] = bot->GetUInt32Value(PLAYER_FIELD_COMBAT_RATING_1 + cr);
            out[std::string("crb_") + name] = bot->GetRatingBonusValue(cr);
        }
    }

    // ------------------------------------------------------------------ 2.6 trainer
    InvResult TrainerSpells(Player* bot, std::vector<TrainerSpellRow>& out, std::string* npcName)
    {
        if (char const* reason = CheckOwned(bot))
            return Fail(reason);

        Creature* npc = FindTrainer(bot);
        Trainer::Trainer* trainer = npc ? sObjectMgr->GetTrainer(npc->GetEntry()) : nullptr;
        if (!trainer)
            return Fail("no_trainer");

        if (npcName)
            *npcName = npc->GetNameForLocaleIdx(CallerLocale());

        CollectTrainerSpells(bot, npc, trainer, out);
        return Ok(int32(out.size()));
    }

    InvResult TrainerLearnAll(Player* bot)
    {
        if (char const* reason = CheckOwned(bot))
            return Fail(reason);

        if (!bot->IsAlive())
            return Fail("dead");

        if (bot->IsInCombat())
            return Fail("combat");

        Creature* npc = FindTrainer(bot);
        Trainer::Trainer* trainer = npc ? sObjectMgr->GetTrainer(npc->GetEntry()) : nullptr;
        if (!trainer)
            return Fail("no_trainer");

        uint32 const moneyBefore = bot->GetMoney();
        int32 learned = 0;
        bool unaffordable = false;
        bool anyRows = false;

        // Replaces MB L4658 (which edited money directly): the real CMSG_TRAINER_BUY_SPELL per spell, so the
        // trainer checks, money and learning all stay in Trainer::TeachSpell. Repeated passes pick up ranks
        // that become teachable once the previous rank is known.
        for (uint32 pass = 0; pass < MAX_LEARN_PASSES; ++pass)
        {
            std::vector<TrainerSpellRow> rows;
            CollectTrainerSpells(bot, npc, trainer, rows);
            anyRows = anyRows || !rows.empty();
            std::stable_sort(rows.begin(), rows.end(),
                [](TrainerSpellRow const& l, TrainerSpellRow const& r) { return l.cost < r.cost; });

            int32 learnedThisPass = 0;
            unaffordable = false;
            for (TrainerSpellRow const& row : rows)
            {
                Trainer::Spell const* spell = trainer->GetSpell(row.spell);
                if (!spell || !trainer->CanTeachSpell(bot, spell))
                    continue;

                if (row.cost > bot->GetMoney())
                {
                    unaffordable = true;
                    continue;
                }

                uint32 const money = bot->GetMoney();
                WorldPacket packet(CMSG_TRAINER_BUY_SPELL, 8 + 4);
                packet << npc->GetGUID() << uint32(row.spell);
                WorldPackets::NPC::TrainerBuySpell buy(std::move(packet));
                buy.Read();
                bot->GetSession()->HandleTrainerBuySpellOpcode(buy);

                // Learned = no longer offered as available (known), or paid for it.
                if (!trainer->CanTeachSpell(bot, spell) || bot->GetMoney() < money)
                    ++learnedThisPass;
            }

            learned += learnedThisPass;
            if (!learnedThisPass)
                break;
        }

        int32 const spent = int32(int64(moneyBefore) - int64(bot->GetMoney()));
        if (learned)
            return Ok(learned, spent);

        if (!anyRows)
            return Ok(0, 0);

        return Fail(unaffordable ? "no_money" : "failed");
    }

    // ------------------------------------------------------------------ 2.6 quests
    void Quests(Player* bot, std::vector<QuestRow>& out)
    {
        for (uint8 slot = 0; slot < MAX_QUEST_LOG_SIZE; ++slot)
        {
            uint32 const questId = bot->GetQuestSlotQuestId(slot);
            Quest const* quest = questId ? sObjectMgr->GetQuestTemplate(questId) : nullptr;
            if (!quest)
                continue;

            QuestRow row;
            row.id = questId;
            // Level -1 = scales with the player (the client shows the player's level).
            row.level = quest->GetQuestLevel() > 0 ? quest->GetQuestLevel() : int32(bot->GetLevel());
            row.complete = bot->GetQuestStatus(questId) == QUEST_STATUS_COMPLETE;
            row.title = QuestTitle(questId);

            out.push_back(std::move(row));
        }
    }

    InvResult DropQuest(Player* bot, uint32 questId)
    {
        if (char const* reason = CheckOwned(bot))
            return Fail(reason);

        uint8 questSlot = MAX_QUEST_LOG_SIZE;
        for (uint8 slot = 0; questId && slot < MAX_QUEST_LOG_SIZE; ++slot)
        {
            if (bot->GetQuestSlotQuestId(slot) == questId)
            {
                questSlot = slot;
                break;
            }
        }

        if (questSlot >= MAX_QUEST_LOG_SIZE)
            return Fail("bad_quest");

        // MB L6829
        WorldPacket packet(CMSG_QUESTLOG_REMOVE_QUEST, 1);
        packet << questSlot;
        WorldPackets::Quest::QuestLogRemoveQuest remove(std::move(packet));
        remove.Read();
        bot->GetSession()->HandleQuestLogRemoveQuest(remove);

        return bot->GetQuestSlotQuestId(questSlot) != questId ? Ok() : Fail("failed");
    }

    // ------------------------------------------------------------------ extras exports (party-extras-spec 2.0)
    Creature* FindVendor(Player* bot)
    {
        return FindInteractableNpc(bot, UNIT_NPC_FLAG_VENDOR);
    }

    void SendUseItem(Player* bot, uint8 bag, uint8 slot, Item* item, uint32 spellId, uint32 glyphIndex)
    {
        SpellInfo const* spellInfo = sSpellMgr->GetSpellInfo(spellId);
        uint32 const targetMask = (spellInfo && (spellInfo->Targets & TARGET_FLAG_UNIT)) ? TARGET_FLAG_UNIT : TARGET_FLAG_NONE;

        // MB L7821. Field order of WorldSession::HandleUseItemOpcode: bag, slot, castCount, spellId, item guid,
        // glyphIndex, castFlags, then the SpellCastTargets.
        WorldPacket packet(CMSG_USE_ITEM);
        packet << bag << slot << uint8(1) << spellId << item->GetGUID() << glyphIndex << uint8(0);
        packet << targetMask;
        if (targetMask & TARGET_FLAG_UNIT)
            packet << bot->GetPackGUID();
        bot->GetSession()->HandleUseItemOpcode(packet);
    }

    std::string QuestTitle(uint32 questId)
    {
        Quest const* quest = sObjectMgr->GetQuestTemplate(questId);
        if (!quest)
            return std::string();

        std::string title = quest->GetTitle();
        LocaleConstant const locale = CallerLocale();
        if (locale != LOCALE_enUS)
            if (QuestLocale const* questLocale = sObjectMgr->GetQuestLocale(questId))
                ObjectMgr::GetLocaleString(questLocale->Title, int(locale), title);

        return title;
    }
}
