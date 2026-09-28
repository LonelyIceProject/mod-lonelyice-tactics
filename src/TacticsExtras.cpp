/*
 * Bot tactics - party window extras, C++ primitives (TacticsExtras.h).
 *
 * Premade talent builds are a read-only view of the playerbots config. Reputations / skills / glyphs /
 * buyback / completed quests are read-only listings of the bot. Glyph apply / remove, vendor buy and
 * buyback go through the real client packets handed to the bot's own session handler and are verified
 * by re-reading state. Validation texts, paging and UI policy live in Lua.
 *
 *
 */

#include "TacticsExtras.h"
#include "TacticsEngine.h"
#include "TacticsPartyApi.h"

#include "Bag.h"
#include "ConditionMgr.h"
#include "Creature.h"
#include "DBCStores.h"
#include "Item.h"
#include "ItemPackets.h"
#include "Log.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "PlayerbotAIConfig.h"
#include "QuestDef.h"
#include "ReputationMgr.h"
#include "SpellInfo.h"
#include "SpellMgr.h"
#include "WorldPacket.h"
#include "WorldSession.h"

#include <algorithm>
#include <cmath>
#include <mutex>

namespace Tactics::Party
{
    namespace
    {
        constexpr uint32 PREMADE_MAX_LEVEL = 80;          // PlayerbotFactory::InitTalentsByTemplate walks up to 80
        constexpr uint32 PREMADE_SKIPPED_CLASS = 10;      // no class 10 in 3.3.5 (PlayerbotAIConfig::Load skips it)
        constexpr uint32 REWARDED_MAX_LIMIT = 100;

        InvResult Fail(char const* reason, int32 a = 0)
        {
            InvResult r;
            r.reason = reason;
            r.a = a;
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

        // Copy of TacticsInventory.cpp CallerLocale (file-local there): locale of the message player.
        LocaleConstant CallerLocale()
        {
            Lua::CallContext* call = Lua::CurrentCall();
            Player* anchor = call ? call->anchor : nullptr;
            if (!anchor || !anchor->GetSession())
                return LOCALE_enUS;

            LocaleConstant const locale = anchor->GetSession()->GetSessionDbcLocale();
            return locale < TOTAL_LOCALES ? locale : LOCALE_enUS;
        }

        // ------------------------------------------------------------------ glyph helpers
        // Glyph item -> on-use spell, glyph property id and entry (spec 2.4).
        bool ResolveGlyphItem(Item* item, uint32& spellId, uint32& glyph, GlyphPropertiesEntry const*& gp)
        {
            spellId = 0;
            glyph = 0;
            gp = nullptr;

            ItemTemplate const* proto = item ? item->GetTemplate() : nullptr;
            if (!proto || proto->Class != ITEM_CLASS_GLYPH)
                return false;

            spellId = ItemUseSpell(item);
            SpellInfo const* spellInfo = spellId ? sSpellMgr->GetSpellInfo(spellId) : nullptr;
            if (!spellInfo)
                return false;

            for (SpellEffectInfo const& effect : spellInfo->GetEffects())
            {
                if (effect.Effect != SPELL_EFFECT_APPLY_GLYPH || effect.MiscValue <= 0)
                    continue;

                glyph = uint32(effect.MiscValue);
                gp = sGlyphPropertiesStore.LookupEntry(glyph);
                return gp != nullptr;
            }

            return false;
        }

        uint32 GlyphSlotKind(Player* bot, uint8 glyphSlot, bool* found = nullptr)
        {
            GlyphSlotEntry const* entry = sGlyphSlotStore.LookupEntry(bot->GetGlyphSlot(glyphSlot));
            if (found)
                *found = entry != nullptr;
            return entry ? entry->TypeFlags : 0;
        }

        // Spec 2.4 assumption: slot 0 is major (TypeFlags 0), slot 1 minor (TypeFlags 1). Checked once.
        void CheckGlyphKindsOnce(Player* bot)
        {
            static std::once_flag once;
            std::call_once(once, [bot]()
            {
                bool found0 = false;
                bool found1 = false;
                uint32 const kind0 = GlyphSlotKind(bot, 0, &found0);
                uint32 const kind1 = GlyphSlotKind(bot, 1, &found1);
                if (found0 && found1 && kind0 == 0 && kind1 == 1)
                    LOG_DEBUG("module", "[tactics] glyph sockets: slot 0 major, slot 1 minor (as assumed)");
                else
                    LOG_WARN("module", "[tactics] glyph sockets: slot 0 TypeFlags {} (found {}), slot 1 TypeFlags {} (found {}); "
                             "expected 0 / 1 - the addon's major/minor columns may be wrong", kind0, found0, kind1, found1);
            });
        }

        // Backpack (255, 23..38) or an equipped bag (19..22, slot < size): the positions a glyph may be used from.
        bool IsCarriedPos(Player* bot, uint8 bag, uint8 slot)
        {
            if (bag == INVENTORY_SLOT_BAG_0)
                return slot >= INVENTORY_SLOT_ITEM_START && slot < INVENTORY_SLOT_ITEM_END;

            if (bag < INVENTORY_SLOT_BAG_START || bag >= INVENTORY_SLOT_BAG_END)
                return false;

            Bag* container = bot->GetBagByPos(bag);
            return container && uint32(slot) < container->GetBagSize();
        }

        bool HasQueuedItemCast(Player* bot, uint32 spellId)
        {
            return std::any_of(bot->SpellQueue.begin(), bot->SpellQueue.end(),
                               [spellId](PendingSpellCastRequest const& r) { return r.isItem && r.spellId == spellId; });
        }

        // ------------------------------------------------------------------ vendor helpers
        // The same list BuyItemFromVendorSlot / SendListInventory use (Player.cpp BuyItemFromVendorSlot).
        VendorItemData const* VendorList(Player* bot, Creature* vendor)
        {
            uint32 const current = bot->GetSession()->GetCurrentVendor();
            return current ? sObjectMgr->GetNpcVendorItemList(current) : vendor->GetVendorItems();
        }

        // Price of `count` purchases as BuyItemFromVendorSlot computes it (0 when no gold is required).
        uint64 GoldPrice(Player* bot, Creature* vendor, VendorItem const* vi, ItemTemplate const* proto, uint32 count)
        {
            if (!vi->IsGoldRequired(proto) || proto->BuyPrice <= 0)
                return 0;

            return uint64(std::floor(double(proto->BuyPrice) * count * bot->GetReputationPriceDiscount(vendor)));
        }
    }

    // ------------------------------------------------------------------ 2.1 premade specs
    void PremadeSpecs(uint8 cls, uint8 level, std::vector<PremadeSpec>& out)
    {
        out.clear();
        if (cls < 1 || cls >= MAX_CLASSES || cls == PREMADE_SKIPPED_CLASS || level < 1 || level > PREMADE_MAX_LEVEL)
            return;

        PlayerbotAIConfig const& config = sPlayerbotAIConfig;
        for (uint32 specNo = 0; specNo < MAX_SPECNO; ++specNo)
        {
            if (config.premadeSpecName[cls][specNo].empty())
                break;                                    // ChangeTalentsAction::SpecList rule

            PremadeSpec spec;
            spec.no = specNo + 1;
            spec.name = config.premadeSpecName[cls][specNo];
            spec.glyphItems = config.parsedSpecGlyph[cls][specNo];

            // PlayerbotFactory::InitTalentsByTemplate: start at the highest configured level <= the bot's.
            uint32 startLevel = level;
            while (startLevel > 1 && config.parsedSpecLinkOrder[cls][specNo][startLevel].empty())
                --startLevel;

            for (uint32 L = startLevel; L <= PREMADE_MAX_LEVEL && spec.entries.size() < PREMADE_MAX_ENTRIES; ++L)
            {
                for (std::vector<uint32> const& p : config.parsedSpecLinkOrder[cls][specNo][L])
                {
                    if (p.size() < 4 || p[0] > 2 || p[1] > 15 || p[2] > 15 || p[3] < 1 || p[3] > 5)
                        continue;

                    spec.entries.push_back({ uint8(p[0]), uint8(p[1]), uint8(p[2]), uint8(p[3]) });
                    if (spec.entries.size() >= PREMADE_MAX_ENTRIES)
                        break;
                }
            }

            out.push_back(std::move(spec));
        }
    }

    // ------------------------------------------------------------------ 2.2 reputations (MB L1103-1170)
    InvResult Reputations(Player* bot, std::vector<ReputationRow>& out)
    {
        if (char const* reason = CheckOwned(bot))
            return Fail(reason);

        LocaleConstant const locale = CallerLocale();
        ReputationMgr& mgr = bot->GetReputationMgr();
        for (auto const& [listId, state] : mgr.GetStateList())
        {
            if (!(state.Flags & FACTION_FLAG_VISIBLE))
                continue;

            if ((state.Flags & (FACTION_FLAG_HIDDEN | FACTION_FLAG_INVISIBLE_FORCED)) && !(state.Flags & FACTION_FLAG_SPECIAL))
                continue;

            FactionEntry const* e = sFactionStore.LookupEntry(state.ID);
            if (!e)
                continue;

            ReputationRank const rank = mgr.GetRank(e);
            int32 const rep = mgr.GetReputation(e);

            int32 base = ReputationMgr::Reputation_Cap + 1;
            for (int32 i = MAX_REPUTATION_RANK - 1; i >= int32(rank); --i)
                base -= ReputationMgr::PointsInRank[i];

            ReputationRow row;
            row.id = e->ID;
            row.parent = e->team;
            row.rank = uint8(rank);
            row.max = ReputationMgr::PointsInRank[rank];
            row.bar = std::clamp<int32>(rep - base, 0, row.max);

            char const* name = e->name[locale];
            if (!name || !*name)
                name = e->name[LOCALE_enUS];
            row.name = name ? name : "";

            if (mgr.IsAtWar(e))
                row.flags += 'w';
            if (state.Flags & FACTION_FLAG_INACTIVE)
                row.flags += 'i';
            if (state.Flags & FACTION_FLAG_SPECIAL)
                row.flags += 's';
            if (state.Flags & FACTION_FLAG_PEACE_FORCED)
                row.flags += 'p';

            out.push_back(std::move(row));
        }

        return Ok(int32(out.size()));
    }

    // ------------------------------------------------------------------ 2.3 skills
    InvResult Skills(Player* bot, std::vector<SkillRow>& out)
    {
        if (char const* reason = CheckOwned(bot))
            return Fail(reason);

        for (auto const& [id, status] : bot->GetSkillStatusMap())
        {
            if (status.uState == SKILL_DELETED || !bot->HasSkill(id))
                continue;

            SkillLineEntry const* sl = sSkillLineStore.LookupEntry(id);
            if (!sl)
                continue;

            SkillRow row;
            row.id = id;
            row.cat = sl->categoryId;
            row.value = bot->GetSkillValue(id);
            row.base = bot->GetBaseSkillValue(id);
            row.max = bot->GetMaxSkillValue(id);
            row.pureMax = bot->GetPureMaxSkillValue(id);
            row.step = bot->GetSkillStep(uint16(id));
            out.push_back(row);
        }

        return Ok(int32(out.size()));
    }

    // ------------------------------------------------------------------ 2.4 glyphs
    InvResult Glyphs(Player* bot, GlyphsOut& out)
    {
        if (char const* reason = CheckOwned(bot))
            return Fail(reason);

        CheckGlyphKindsOnce(bot);

        out = GlyphsOut();
        out.enabled = bot->GetUInt32Value(PLAYER_GLYPHS_ENABLED);
        for (uint8 i = 0; i < GLYPH_SLOTS; ++i)
        {
            GlyphSlotRow row;
            row.slot = i;
            row.kind = GlyphSlotKind(bot, i);
            row.level = GLYPH_SLOT_LEVEL[i];
            row.glyph = bot->GetGlyph(i);
            GlyphPropertiesEntry const* gp = row.glyph ? sGlyphPropertiesStore.LookupEntry(row.glyph) : nullptr;
            row.spell = gp ? gp->SpellId : 0;
            out.slots.push_back(row);
        }

        auto addItem = [&out](uint8 bag, uint8 slot, Item* item)
        {
            uint32 spellId = 0;
            uint32 glyph = 0;
            GlyphPropertiesEntry const* gp = nullptr;
            if (!ResolveGlyphItem(item, spellId, glyph, gp))
                return;

            GlyphBagRow row;
            row.bag = bag;
            row.slot = slot;
            row.guidLow = item->GetGUID().GetCounter();
            row.entry = item->GetEntry();
            row.glyph = glyph;
            row.kind = gp->TypeFlags;
            row.spell = gp->SpellId;
            out.bag.push_back(row);
        };

        for (uint8 slot = INVENTORY_SLOT_ITEM_START; slot < INVENTORY_SLOT_ITEM_END; ++slot)
            if (Item* item = bot->GetItemByPos(INVENTORY_SLOT_BAG_0, slot))
                addItem(INVENTORY_SLOT_BAG_0, slot, item);

        for (uint8 bag = INVENTORY_SLOT_BAG_START; bag < INVENTORY_SLOT_BAG_END; ++bag)
        {
            Bag* container = bot->GetBagByPos(bag);
            if (!container)
                continue;

            for (uint32 slot = 0; slot < container->GetBagSize(); ++slot)
                if (Item* item = container->GetItemByPos(uint8(slot)))
                    addItem(bag, uint8(slot), item);
        }

        return Ok();
    }

    InvResult GlyphApply(Player* bot, uint8 glyphSlot, uint8 bag, uint8 slot, uint32 guidLow)
    {
        if (char const* reason = CheckOwned(bot))
            return Fail(reason);

        if (!bot->IsAlive())
            return Fail("dead");

        if (bot->IsInCombat())
            return Fail("combat");

        if (bot->GetTradeData())
            return Fail("trading");

        if (glyphSlot >= GLYPH_SLOTS)
            return Fail("bad_pos");

        Item* item = IsCarriedPos(bot, bag, slot) ? bot->GetItemByPos(bag, slot) : nullptr;
        if (!item || !item->GetTemplate() || item->GetGUID().GetCounter() != guidLow)
            return Fail("stale");

        uint32 spellId = 0;
        uint32 glyph = 0;
        GlyphPropertiesEntry const* gp = nullptr;
        if (!ResolveGlyphItem(item, spellId, glyph, gp))
            return Fail("cannot");

        if (bot->CanUseItem(item) != EQUIP_ERR_OK)
            return Fail("cannot");

        uint32 const enabled = bot->GetUInt32Value(PLAYER_GLYPHS_ENABLED);
        if (!(enabled & (1u << glyphSlot)))
            return Fail("level", GLYPH_SLOT_LEVEL[glyphSlot]);

        bool slotFound = false;
        uint32 const slotKind = GlyphSlotKind(bot, glyphSlot, &slotFound);
        if (slotFound && slotKind != gp->TypeFlags)
            return Fail("glyph_type");

        if (bot->HasAura(gp->SpellId))
            return Fail("already");
        for (uint8 i = 0; i < GLYPH_SLOTS; ++i)
            if (bot->GetGlyph(i) == glyph)
                return Fail("already");

        // Out of combat here: the player's order wins over a buff cast (same rule as DoEquip).
        if (bot->IsNonMeleeSpellCast(false))
            bot->InterruptNonMeleeSpells(false);

        if (bot->isMoving())
        {
            bot->ClearUnitState(UNIT_STATE_CHASE);
            bot->ClearUnitState(UNIT_STATE_FOLLOW);
            bot->StopMoving();
            return Fail("moving");                        // the addon re-sends the apply once after 1 s
        }

        // The glyph item spells have a 5 s cast (SpellCastTimes 6). The AI itself waits while a
        // generic spell is preparing (PlayerbotAI::UpdateAI), but a follow/chase generator left in
        // the motion master would still walk the bot after a moving master and cut the cast.
        // Only these two are cleared: when one of them is on top no controlled generator exists.
        MovementGeneratorType const mmType = bot->GetMotionMaster()->GetCurrentMovementGeneratorType();
        if (mmType == FOLLOW_MOTION_TYPE || mmType == CHASE_MOTION_TYPE)
            bot->GetMotionMaster()->Clear();

        ObjectGuid const guid = item->GetGUID();
        uint32 const countBefore = item->GetCount();

        SendUseItem(bot, bag, slot, item, spellId, glyphSlot);

        if (bot->GetGlyph(glyphSlot) == glyph)
            return Ok(1);

        // Item casts may be queued until the GCD ends (SpellHandler.cpp SpellQueue) or still be casting.
        Item* after = bot->GetItemByGuid(guid);
        bool const consumed = !after || after->GetCount() < countBefore;
        if (consumed || bot->IsNonMeleeSpellCast(false) || HasQueuedItemCast(bot, spellId))
            return Ok(0);

        return Fail("failed");
    }

    InvResult GlyphRemove(Player* bot, uint8 glyphSlot)
    {
        if (char const* reason = CheckOwned(bot))
            return Fail(reason);

        if (bot->IsInCombat())
            return Fail("combat");

        if (glyphSlot >= GLYPH_SLOTS)
            return Fail("bad_pos");

        if (bot->GetGlyph(glyphSlot) == 0)
            return Fail("already");

        // CMSG_REMOVE_GLYPH (CharacterHandler.cpp HandleRemoveGlyph)
        WorldPacket packet(CMSG_REMOVE_GLYPH, 4);
        packet << uint32(glyphSlot);
        bot->GetSession()->HandleRemoveGlyph(packet);

        return bot->GetGlyph(glyphSlot) == 0 ? Ok() : Fail("failed");
    }

    // ------------------------------------------------------------------ 2.5 vendor
    InvResult VendorItems(Player* bot, std::vector<VendorRow>& out, std::string* npcName)
    {
        if (char const* reason = CheckOwned(bot))
            return Fail(reason);

        Creature* vendor = FindVendor(bot);
        if (!vendor)
            return Fail("no_vendor");

        if (npcName)
            *npcName = vendor->GetNameForLocaleIdx(CallerLocale());

        VendorItemData const* items = VendorList(bot, vendor);
        if (!items || items->Empty())
            return Ok(0);

        float const discount = bot->GetReputationPriceDiscount(vendor);
        uint32 const itemCount = items->GetItemCount();
        for (uint32 slot = 0; slot < itemCount && out.size() < MAX_VENDOR_ITEMS; ++slot)
        {
            VendorItem const* vi = items->GetItem(slot);
            ItemTemplate const* proto = vi ? sObjectMgr->GetItemTemplate(vi->item) : nullptr;
            if (!proto)
                continue;

            // Filters of WorldSession::SendListInventory (ItemHandler.cpp), GM exceptions dropped (a bot is no GM).
            if (!(proto->AllowableClass & bot->getClassMask()) && proto->Bonding == BIND_WHEN_PICKED_UP)
                continue;

            if ((proto->HasFlag2(ITEM_FLAG2_FACTION_HORDE) && bot->GetTeamId() == TEAM_ALLIANCE) ||
                (proto->HasFlag2(ITEM_FLAG2_FACTION_ALLIANCE) && bot->GetTeamId() == TEAM_HORDE))
                continue;

            uint32 const stock = vi->maxcount ? vendor->GetVendorItemCurrentCount(vi) : 0;
            if (vi->maxcount && !stock)
                continue;                                 // sold out: not listed by the real vendor window either

            ConditionList conditions = sConditionMgr->GetConditionsForNpcVendorEvent(vendor->GetEntry(), vi->item);
            if (!sConditionMgr->IsObjectMeetToConditions(bot, vendor, conditions))
                continue;

            VendorRow row;
            row.slot = slot;
            row.entry = vi->item;
            row.price = vi->IsGoldRequired(proto) ? uint32(std::floor(proto->BuyPrice * discount)) : 0;
            row.count = stock;
            row.ext = vi->ExtendedCost;
            out.push_back(row);
        }

        return Ok(int32(out.size()));
    }

    InvResult VendorBuy(Player* bot, uint32 slot, uint32 entry, uint32 count)
    {
        if (char const* reason = CheckOwned(bot))
            return Fail(reason);

        if (!bot->IsAlive())
            return Fail("dead");

        if (bot->IsInCombat())
            return Fail("combat");

        if (bot->GetTradeData())
            return Fail("trading");

        Creature* vendor = FindVendor(bot);
        if (!vendor)
            return Fail("no_vendor");

        if (count < 1 || count > BUY_MAX_COUNT)
            return Fail("bad_arg");

        VendorItemData const* items = VendorList(bot, vendor);
        VendorItem const* vi = items && slot < items->GetItemCount() ? items->GetItem(slot) : nullptr;
        ItemTemplate const* proto = vi && vi->item == entry ? sObjectMgr->GetItemTemplate(entry) : nullptr;
        if (!proto)
            return Fail("stale");

        if (vi->ExtendedCost && !vi->IsGoldRequired(proto))
            return Fail("cannot");                        // tokens / honor / arena points: not supported (spec Q2)

        if (proto->RequiredReputationFaction &&
            uint32(bot->GetReputationRank(proto->RequiredReputationFaction)) < proto->RequiredReputationRank)
            return Fail("cannot");

        if (vi->maxcount && vendor->GetVendorItemCurrentCount(vi) < proto->BuyCount * count)
            return Fail("sold_out");

        uint64 const price = GoldPrice(bot, vendor, vi, proto, count);
        if (price > bot->GetMoney())
            return Fail("no_money");

        ItemPosCountVec dest;
        if (bot->CanStoreNewItem(NULL_BAG, NULL_SLOT, dest, entry, proto->BuyCount * count) != EQUIP_ERR_OK)
            return Fail("full");

        uint32 const moneyBefore = bot->GetMoney();
        uint32 const itemsBefore = bot->GetItemCount(entry);

        // CMSG_BUY_ITEM (ItemPackets.cpp BuyItem::Read); the client counts vendor slots from 1.
        WorldPacket packet(CMSG_BUY_ITEM, 8 + 4 + 4 + 4 + 1);
        packet << vendor->GetGUID() << uint32(entry) << uint32(slot + 1) << uint32(count) << uint8(0);
        WorldPackets::Item::BuyItem buy(std::move(packet));
        buy.Read();
        bot->GetSession()->HandleBuyItemOpcode(buy);

        uint32 const itemsAfter = bot->GetItemCount(entry);
        if (itemsAfter <= itemsBefore)
            return Fail("failed");

        return Ok(int32(itemsAfter - itemsBefore), int32(int64(moneyBefore) - int64(bot->GetMoney())));
    }

    InvResult Buyback(Player* bot, std::vector<BuybackRow>& out)
    {
        if (char const* reason = CheckOwned(bot))
            return Fail(reason);

        for (uint32 slot = BUYBACK_SLOT_START; slot < BUYBACK_SLOT_END; ++slot)
        {
            Item* item = bot->GetItemFromBuyBackSlot(slot);
            if (!item)
                continue;

            BuybackRow row;
            row.slot = slot;
            row.entry = item->GetEntry();
            row.count = item->GetCount();
            row.price = bot->GetUInt32Value(PLAYER_FIELD_BUYBACK_PRICE_1 + slot - BUYBACK_SLOT_START);   // MB L8063
            out.push_back(row);
        }

        return Ok(int32(out.size()));
    }

    InvResult BuybackBuy(Player* bot, uint32 slot, uint32 entry)
    {
        if (char const* reason = CheckOwned(bot))
            return Fail(reason);

        if (!bot->IsAlive())
            return Fail("dead");

        if (bot->IsInCombat())
            return Fail("combat");

        if (bot->GetTradeData())
            return Fail("trading");

        if (slot < BUYBACK_SLOT_START || slot >= BUYBACK_SLOT_END)
            return Fail("bad_pos");

        Item* item = bot->GetItemFromBuyBackSlot(slot);
        if (!item || item->GetEntry() != entry)
            return Fail("stale");

        Creature* vendor = FindVendor(bot);
        if (!vendor)
            return Fail("no_vendor");

        uint32 const price = bot->GetUInt32Value(PLAYER_FIELD_BUYBACK_PRICE_1 + slot - BUYBACK_SLOT_START);
        if (!bot->HasEnoughMoney(price))
            return Fail("no_money");

        ItemPosCountVec dest;
        if (bot->CanStoreItem(NULL_BAG, NULL_SLOT, dest, item, false) != EQUIP_ERR_OK)
            return Fail("full");

        uint32 const moneyBefore = bot->GetMoney();

        // CMSG_BUYBACK_ITEM (ItemPackets.cpp BuybackItem::Read, MB L8161-8166)
        WorldPacket packet(CMSG_BUYBACK_ITEM, 8 + 4);
        packet << vendor->GetGUID() << uint32(slot);
        WorldPackets::Item::BuybackItem buyback(std::move(packet));
        buyback.Read();
        bot->GetSession()->HandleBuybackItem(buyback);

        if (bot->GetItemFromBuyBackSlot(slot))
            return Fail("failed");

        return Ok(int32(int64(moneyBefore) - int64(bot->GetMoney())));
    }

    // ------------------------------------------------------------------ 2.6 completed quests
    InvResult RewardedQuests(Player* bot, uint32 offset, uint32 limit, std::vector<DoneQuestRow>& out, uint32& total)
    {
        total = 0;
        if (char const* reason = CheckOwned(bot))
            return Fail(reason);

        // RewardedQuestSet is an unordered_set in this core: sort for stable ascending pages.
        RewardedQuestSet const& set = bot->getRewardedQuests();
        std::vector<uint32> ids(set.begin(), set.end());
        std::sort(ids.begin(), ids.end());

        total = uint32(ids.size());
        limit = std::clamp<uint32>(limit, 1, REWARDED_MAX_LIMIT);
        for (uint32 i = offset; i < total && out.size() < limit; ++i)
        {
            uint32 const id = ids[i];
            DoneQuestRow row;
            row.id = id;
            if (Quest const* quest = sObjectMgr->GetQuestTemplate(id))
            {
                // Level -1 = scales with the player (the same substitution as Quests()).
                row.level = quest->GetQuestLevel() > 0 ? quest->GetQuestLevel() : int32(bot->GetLevel());
                row.title = QuestTitle(id);
            }

            out.push_back(std::move(row));
        }

        return Ok(int32(out.size()));
    }
}
