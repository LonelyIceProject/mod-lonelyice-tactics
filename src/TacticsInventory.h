/*
 * Bot tactics - party window C++ primitives, package P1: inventory snapshot, item actions, sell grey,
 * character stats, trainer and quest log. P1-private header (TacticsInventory.cpp implements it,
 * TacticsInventoryApi.cpp binds it to Lua). No Lua/sol2 includes.
 *
 * Primitives only: every mutating call goes through the bot's own session handlers (the packets a real
 * client would send) and verifies the outcome by re-reading state. Semantics, messages and confirmations
 * belong to the Lua scripts. Reason strings are part of the Lua contract (spec section 8).
 *
 *
 */

#ifndef MOD_LONELYICE_TACTICS_INVENTORY_H
#define MOD_LONELYICE_TACTICS_INVENTORY_H

#include "Define.h"

#include <map>
#include <string>
#include <vector>

class Creature;
class Item;
class Player;

namespace Tactics::Party
{
    // Spec 2.1 "Result" (named InvResult here so it cannot collide with P2's private type of the same shape).
    struct InvResult
    {
        bool ok = false;
        char const* reason = "failed";
        int32 a = 0;
        int32 b = 0;
    };

    // ------------------------------------------------------------------ 2.2 inventory snapshot
    struct ItemRow
    {
        uint8 bag = 0;
        uint8 slot = 0;
        uint32 guidLow = 0;
        uint32 entry = 0;
        uint32 count = 0;
        uint32 enchant = 0;
        uint32 gem[3] = { };
        int32 randomProperty = 0;
        uint32 suffixFactor = 0;
        uint32 durability = 0;
        uint32 maxDurability = 0;
        std::string flags;                // s q k h x n p b e u (spec 2.2)
        std::string fits;                 // "0:11" equipment slots this item can be equipped into now
    };

    struct ContainerRow
    {
        char kind = 'B';                  // E B G K N H
        uint8 bag = 0;
        uint8 start = 0;
        uint8 size = 0;
        uint32 entry = 0;
    };

    struct SnapshotOut
    {
        uint32 money = 0;
        std::string flags;                // b v r t c d x m
        std::vector<ContainerRow> containers;
        std::vector<ItemRow> items;
    };

    struct TrainerSpellRow
    {
        uint32 spell = 0;
        uint32 cost = 0;                  // after the reputation discount
        bool canLearn = false;            // affordable now
    };

    struct QuestRow
    {
        uint32 id = 0;
        int32 level = 0;
        bool complete = false;
        std::string title;                // localized for the calling player's client locale
    };

    // Ownership re-check of every P1 primitive (spec rules): nullptr when the call-context message player
    // owns this online bot, else "wrong_thread" (not a world-thread message call) or "bad_bot".
    char const* CheckOwned(Player* bot);

    InvResult Snapshot(Player* bot, SnapshotOut& out);

    // op: equip unequip use sell destroy move give deposit withdraw (spec 2.3)
    InvResult ItemAction(Player* bot, std::string const& op, uint8 bag, uint8 slot, uint32 guidLow, uint32 a, uint32 b);

    InvResult SellGrey(Player* bot);                                  // a = sold stacks, b = money gained

    // Raw numbers (spec 2.5); every key present. Read-only, any thread that owns the bot.
    void Stats(Player* bot, std::map<std::string, double>& out);

    // npcName (optional) receives the trainer's name in the calling player's locale.
    InvResult TrainerSpells(Player* bot, std::vector<TrainerSpellRow>& out, std::string* npcName = nullptr);
    InvResult TrainerLearnAll(Player* bot);                           // a = learned, b = money spent

    void Quests(Player* bot, std::vector<QuestRow>& out);             // read-only
    InvResult DropQuest(Player* bot, uint32 questId);

    // Extras. Implemented by the existing file-local code of TacticsInventory.cpp.
    Creature* FindVendor(Player* bot);                                            // FindInteractableNpc(bot, UNIT_NPC_FLAG_VENDOR)
    // CMSG_USE_ITEM exactly as DoUse builds it with a glyph index; sends it through HandleUseItemOpcode.
    // targetMask = TARGET_FLAG_UNIT + the bot's PackGUID when the spell's Targets has it. No checks here.
    void SendUseItem(Player* bot, uint8 bag, uint8 slot, Item* item, uint32 spellId, uint32 glyphIndex);
    // Quest title in the caller's locale (the code of Quests()); "" for a missing template.
    std::string QuestTitle(uint32 questId);
}

#endif
