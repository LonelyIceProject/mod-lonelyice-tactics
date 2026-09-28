/*
 * Bot tactics - player action mirroring, C++ half.
 *
 * TacticsMirror.cpp: PlayerScript / ServerScript hooks that watch what a REAL player does (quests, flights,
 * teleports, vendor / trainer / repair / gossip) and hand each event to Lua tactics.on_mirror(event, player,
 * payload) from the world thread (WorldScript::OnUpdate, maps not updating). Policy (which bots follow, opt-outs,
 * reward choice, chat lines) is Lua (mirror.lua). This file only detects events and executes single game
 * operations on one bot; callers (TacticsMirrorApi.cpp) check ownership.
 *
 * No Lua/sol2 includes.
 */

#ifndef MOD_LONELYICE_TACTICS_MIRROR_H
#define MOD_LONELYICE_TACTICS_MIRROR_H

#include "Define.h"
#include "ObjectGuid.h"

#include <string>

class Player;
class PlayerbotAI;

namespace Tactics::Mirror
{
    // `reason` strings are part of the Lua contract (abilities-mirroring-spec 5.3).
    struct Result
    {
        bool ok = false;
        char const* reason = "failed";
    };

    // All primitives: world thread, maps not updating (on_message / on_mirror calls); the bot is an online
    // playerbot owned by the caller (checked by the binding).

    // bad_quest, already (in the quest log), cannot_take (CanTakeQuest / CanAddQuest), full_log, failed.
    // No quest giver is passed to the core: escort / script starts of the giver stay the real player's.
    Result QuestAccept(Player* bot, uint32 questId);

    // INCOMPLETE -> COMPLETE (Player::CompleteQuest). withItems: first create the missing required items (as
    // playerbots QuestAction::CompleteQuest does) so that a delivery quest can be turned in; items that do not
    // fit give ok with reason "bags". bad_quest, not_taken, already (already complete), failed.
    Result QuestComplete(Player* bot, uint32 questId, bool withItems);

    // Player::RewardQuest(quest, choice, giver). giver = the quest giver creature / game object on the bot's map
    // when the guid resolves there, else the bot itself (RewardQuest dereferences the giver).
    // Required items are not checked: the bot gives what it carries (none, fewer or all) and the quest closes.
    // bad_quest, already (rewarded), not_complete, bad_choice, full (bags), failed.
    Result QuestReward(Player* bot, uint32 questId, ObjectGuid giver, uint32 choice);

    // "none", "incomplete", "complete", "failed", "rewarded" (rewarded and no longer in the log).
    char const* QuestStatusName(Player* bot, uint32 questId);

    // Teleport onto a ring of 2.5 yd around the owner. ok, already (same map, <= 5 yd), dead, combat, flight
    // (bot in flight / teleporting), owner_busy (owner in flight / teleporting / not in world), instance (owner's
    // map is an instance the bot cannot enter: MapMgr::PlayerCannotEnter), failed.
    Result SummonToOwner(Player* bot, Player* owner);

    // playerbots "item usage" value (ItemUsageValue.h) as a lower-case name: none, equip, replace, bad_equip,
    // broken_equip, quest, skill, use, guild_task, disenchant, ah, keep, vendor, ammo. nullptr for a bad entry.
    char const* ItemUsageName(PlayerbotAI* ai, uint32 entry);

    // The bot can use the item (CanUseItem) and it has an equipment slot for it (FindEquipSlot).
    bool ItemFits(Player* bot, uint32 entry);
}

#endif
