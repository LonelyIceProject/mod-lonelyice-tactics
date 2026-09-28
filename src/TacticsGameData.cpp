/*
 * Bot tactics - raw game data for the Lua scripts (TacticsHost.h, Tactics::GameData).
 * Plain DBC/DB/character facts. NO filtering here: deciding which spells or items are "tactical" is
 * policy and lives in lua_scripts/tactics/spellbook.lua.
 */

#include "TacticsHost.h"

#include "Bag.h"
#include "DBCStores.h"
#include "Item.h"
#include "ItemTemplate.h"
#include "ObjectMgr.h"
#include "Player.h"
#include "SpellInfo.h"
#include "SpellMgr.h"

#include <algorithm>
#include <unordered_map>

namespace
{
    LocaleConstant SafeLocale(LocaleConstant locale)
    {
        return locale < TOTAL_LOCALES ? locale : LOCALE_enUS;
    }

    // Localized DBC string, falling back to the first non-empty locale
    template <class Strings>
    std::string DbcString(Strings const& strings, LocaleConstant locale)
    {
        char const* text = strings[SafeLocale(locale)];
        if (text && *text)
            return text;

        for (uint8 i = 0; i < TOTAL_LOCALES; ++i)
            if (strings[i] && *strings[i])
                return strings[i];

        return { };
    }

    using AbilityIndex = std::unordered_map<uint32, std::vector<Tactics::SkillAbilityRaw>>;

    AbilityIndex BuildAbilityIndex()
    {
        AbilityIndex index;
        for (uint32 i = 0; i < sSkillLineAbilityStore.GetNumRows(); ++i)
        {
            SkillLineAbilityEntry const* entry = sSkillLineAbilityStore.LookupEntry(i);
            if (!entry)
                continue;

            Tactics::SkillAbilityRaw row;
            row.spell = entry->Spell;
            row.skillLine = entry->SkillLine;
            row.raceMask = entry->RaceMask;
            row.classMask = entry->ClassMask;
            row.minSkillRank = entry->MinSkillLineRank;
            row.supercededBySpell = entry->SupercededBySpell;
            row.acquireMethod = entry->AcquireMethod;
            index[entry->SkillLine].push_back(row);
        }
        return index;
    }

    // DBC stores are immutable after startup; the index is built once (thread-safe static init).
    AbilityIndex const& Abilities()
    {
        static AbilityIndex const index = BuildAbilityIndex();
        return index;
    }
}

namespace Tactics::GameData
{
    bool GetSpell(uint32 spellId, LocaleConstant locale, SpellRaw& out)
    {
        SpellInfo const* info = sSpellMgr->GetSpellInfo(spellId);
        if (!info)
            return false;

        out = SpellRaw();
        out.id = info->Id;
        out.name = DbcString(info->SpellName, locale);
        out.rank = DbcString(info->Rank, locale);

        out.attributes[0] = info->Attributes;
        out.attributes[1] = info->AttributesEx;
        out.attributes[2] = info->AttributesEx2;
        out.attributes[3] = info->AttributesEx3;
        out.attributes[4] = info->AttributesEx4;
        out.attributes[5] = info->AttributesEx5;
        out.attributes[6] = info->AttributesEx6;
        out.attributes[7] = info->AttributesEx7;

        for (uint8 i = 0; i < MAX_SPELL_EFFECTS && i < 3; ++i)
        {
            out.effects[i] = info->Effects[i].Effect;
            out.auras[i] = uint32(info->Effects[i].ApplyAuraName);
            out.implicitTargetA[i] = uint32(info->Effects[i].TargetA.GetTarget());
            out.effectMisc[i] = info->Effects[i].MiscValue;
        }

        out.baseLevel = info->BaseLevel;
        out.spellLevel = info->SpellLevel;
        out.maxLevel = info->MaxLevel;
        out.powerType = info->PowerType;
        out.manaCost = info->ManaCost;
        out.manaCostPct = info->ManaCostPercentage;

        if (SpellRangeEntry const* range = info->RangeEntry)
        {
            out.minRange = range->RangeMin[0];
            out.maxRange = range->RangeMax[0];
            out.maxRangeFriend = range->RangeMax[1];
        }

        if (SpellCastTimesEntry const* castTime = info->CastTimeEntry)
            out.castTimeMs = castTime->CastTime > 0 ? uint32(castTime->CastTime) : 0;

        out.recoveryMs = info->RecoveryTime;
        out.categoryRecoveryMs = info->CategoryRecoveryTime;
        out.durationMs = info->GetDuration();
        out.dispel = info->Dispel;
        out.mechanic = info->Mechanic;
        out.schoolMask = info->SchoolMask;
        out.iconId = info->SpellIconID;
        out.family = info->SpellFamilyName;
        out.passive = info->IsPassive();
        out.positive = info->IsPositive();
        out.channeled = info->IsChanneled();
        out.autoRepeat = info->IsAutoRepeatRangedSpell();

        SpellInfo const* first = info->GetFirstRankSpell();
        SpellInfo const* last = info->GetLastRankSpell();
        SpellInfo const* prev = info->GetPrevRankSpell();
        SpellInfo const* next = info->GetNextRankSpell();
        out.firstRank = first ? first->Id : info->Id;
        out.lastRank = last ? last->Id : info->Id;
        out.prevRank = prev ? prev->Id : 0;
        out.nextRank = next ? next->Id : 0;
        out.rankIndex = info->ChainEntry ? info->GetRank() : 0;
        out.talent = GetTalentSpellPos(out.firstRank) != nullptr;

        SkillLineAbilityMapBounds bounds = sSpellMgr->GetSkillLineAbilityMapBounds(info->Id);
        for (auto itr = bounds.first; itr != bounds.second; ++itr)
            if (std::find(out.skillLines.begin(), out.skillLines.end(), itr->second->SkillLine) == out.skillLines.end())
                out.skillLines.push_back(itr->second->SkillLine);

        return true;
    }

    bool GetSkillLine(uint32 skillLineId, LocaleConstant locale, SkillLineRaw& out)
    {
        SkillLineEntry const* entry = sSkillLineStore.LookupEntry(skillLineId);
        if (!entry)
            return false;

        out = SkillLineRaw();
        out.id = entry->id;
        out.category = entry->categoryId > 0 ? uint32(entry->categoryId) : 0;
        out.name = DbcString(entry->name, locale);
        out.spellIcon = entry->spellIcon;
        return true;
    }

    std::vector<SkillAbilityRaw> GetSkillAbilities(uint32 skillLineId)
    {
        AbilityIndex const& index = Abilities();
        auto itr = index.find(skillLineId);
        return itr != index.end() ? itr->second : std::vector<SkillAbilityRaw>();
    }

    bool GetItem(uint32 entry, LocaleConstant locale, ItemRaw& out)
    {
        ItemTemplate const* proto = sObjectMgr->GetItemTemplate(entry);
        if (!proto)
            return false;

        out = ItemRaw();
        out.entry = proto->ItemId;
        out.name = proto->Name1;
        if (ItemLocale const* loc = sObjectMgr->GetItemLocale(entry))
            ObjectMgr::GetLocaleString(loc->Name, SafeLocale(locale), out.name);

        out.itemClass = proto->Class;
        out.itemSubClass = proto->SubClass;
        out.quality = proto->Quality;
        out.itemLevel = proto->ItemLevel;
        out.requiredLevel = proto->RequiredLevel;
        out.maxStack = proto->GetMaxStackSize();

        for (uint8 i = 0; i < MAX_ITEM_PROTO_SPELLS; ++i)
            if (proto->Spells[i].SpellId > 0 && proto->Spells[i].SpellTrigger == ITEM_SPELLTRIGGER_ON_USE)
                out.useSpells.push_back(uint32(proto->Spells[i].SpellId));

        return true;
    }

    std::vector<uint32> GetKnownSpells(Player* player)
    {
        std::vector<uint32> spells;
        if (!player)
            return spells;

        uint8 const spec = player->GetActiveSpec();
        for (auto const& [spellId, spell] : player->GetSpellMap())
            if (spell && spell->State != PLAYERSPELL_REMOVED && spell->Active && spell->IsInSpec(spec))
                spells.push_back(spellId);

        std::sort(spells.begin(), spells.end());
        return spells;
    }

    std::vector<BagItemRaw> GetBagItems(Player* player)
    {
        std::vector<BagItemRaw> items;
        if (!player)
            return items;

        std::unordered_map<uint32, size_t> position;    // entry -> index in items (first-seen order)
        auto add = [&](Item const* item)
        {
            if (!item)
                return;

            uint32 const entry = item->GetEntry();
            auto itr = position.find(entry);
            if (itr == position.end())
            {
                position.emplace(entry, items.size());
                items.push_back({ entry, item->GetCount() });
            }
            else
                items[itr->second].count += item->GetCount();
        };

        for (uint8 slot = INVENTORY_SLOT_ITEM_START; slot < INVENTORY_SLOT_ITEM_END; ++slot)
            add(player->GetItemByPos(INVENTORY_SLOT_BAG_0, slot));

        for (uint8 bagSlot = INVENTORY_SLOT_BAG_START; bagSlot < INVENTORY_SLOT_BAG_END; ++bagSlot)
            if (Bag const* bag = player->GetBagByPos(bagSlot))
                for (uint32 slot = 0; slot < bag->GetBagSize(); ++slot)
                    add(bag->GetItemByPos(uint8(slot)));

        return items;
    }
}
