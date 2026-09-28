/*
 * Bot tactics - party window extras, C++ primitives: premade talent builds (config listing), reputations,
 * skills, glyphs, vendor buy / buyback and completed quests. Private header (TacticsExtras.cpp implements it,
 * TacticsExtrasApi.cpp binds it to Lua). No Lua/sol2 includes.
 *
 * Primitives only: mutations go through the bot's own session handlers (the packets a real client would
 * send) and are verified by re-reading state. Every primitive re-checks ownership (Party::CheckOwned).
 * Reason strings are part of the Lua contract (spec sections 2 and 7).
 *
 *
 */

#ifndef MOD_LONELYICE_TACTICS_EXTRAS_H
#define MOD_LONELYICE_TACTICS_EXTRAS_H

#include "TacticsInventory.h"

#include <string>
#include <vector>

class Player;

namespace Tactics::Party
{
    // ------------------------------------------------------------------ 2.1 premade specs (config only)
    struct PremadeEntry { uint8 tab = 0; uint8 row = 0; uint8 col = 0; uint8 rank = 0; };   // parsedSpecLinkOrder p[0..3]
    struct PremadeSpec
    {
        uint32 no = 0;                                  // 1-based (specNo + 1)
        std::string name;
        std::vector<uint32> glyphItems;
        std::vector<PremadeEntry> entries;              // absolute ranks, the same talent may repeat
    };

    constexpr uint32 PREMADE_MAX_ENTRIES = 512;

    void PremadeSpecs(uint8 cls, uint8 level, std::vector<PremadeSpec>& out);

    // ------------------------------------------------------------------ 2.2 reputations
    struct ReputationRow
    {
        uint32 id = 0;
        std::string name;                               // caller locale, enUS fallback
        uint32 parent = 0;                              // FactionEntry::team (parent faction id)
        uint8 rank = 0;                                 // 0 hated .. 7 exalted
        int32 bar = 0;
        int32 max = 0;
        std::string flags;                              // w i s p
    };

    InvResult Reputations(Player* bot, std::vector<ReputationRow>& out);

    // ------------------------------------------------------------------ 2.3 skills
    struct SkillRow
    {
        uint32 id = 0;
        int32 cat = 0;
        uint16 value = 0;
        uint16 base = 0;
        uint16 max = 0;
        uint16 pureMax = 0;
        uint16 step = 0;
    };

    InvResult Skills(Player* bot, std::vector<SkillRow>& out);

    // ------------------------------------------------------------------ 2.4 glyphs
    constexpr uint8 GLYPH_SLOTS = 6;                                                    // MAX_GLYPH_SLOT_INDEX
    constexpr uint8 GLYPH_SLOT_LEVEL[GLYPH_SLOTS] = { 15, 15, 50, 30, 70, 80 };         // Spell::EffectApplyGlyph

    struct GlyphSlotRow { uint8 slot = 0; uint32 kind = 0; uint8 level = 0; uint32 glyph = 0; uint32 spell = 0; };
    struct GlyphBagRow  { uint8 bag = 0; uint8 slot = 0; uint32 guidLow = 0; uint32 entry = 0; uint32 glyph = 0; uint32 kind = 0; uint32 spell = 0; };
    struct GlyphsOut    { uint32 enabled = 0; std::vector<GlyphSlotRow> slots; std::vector<GlyphBagRow> bag; };

    InvResult Glyphs(Player* bot, GlyphsOut& out);
    InvResult GlyphApply(Player* bot, uint8 glyphSlot, uint8 bag, uint8 slot, uint32 guidLow);   // a = 1 verified, 0 pending
    InvResult GlyphRemove(Player* bot, uint8 glyphSlot);

    // ------------------------------------------------------------------ 2.5 vendor and buyback
    struct VendorRow  { uint32 slot = 0; uint32 entry = 0; uint32 price = 0; uint32 count = 0; uint32 ext = 0; };   // count 0 = unlimited
    struct BuybackRow { uint32 slot = 0; uint32 entry = 0; uint32 count = 0; uint32 price = 0; };                  // slot 74..85

    constexpr uint32 BUY_MAX_COUNT = 20;

    InvResult VendorItems(Player* bot, std::vector<VendorRow>& out, std::string* npcName);
    InvResult VendorBuy(Player* bot, uint32 slot, uint32 entry, uint32 count);                  // a = items gained, b = money spent
    InvResult Buyback(Player* bot, std::vector<BuybackRow>& out);
    InvResult BuybackBuy(Player* bot, uint32 slot, uint32 entry);                               // a = money spent

    // ------------------------------------------------------------------ 2.6 completed quests
    struct DoneQuestRow { uint32 id = 0; int32 level = 0; std::string title; };

    InvResult RewardedQuests(Player* bot, uint32 offset, uint32 limit, std::vector<DoneQuestRow>& out, uint32& total);
}

#endif
