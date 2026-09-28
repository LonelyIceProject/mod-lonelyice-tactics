/*
 * Bot tactics - party window primitives of package P2: account bots / lifecycle / chat commands /
 * strategies (TacticsBots.cpp) and talents. Bound to Lua by TacticsAiApi.cpp.
 *
 * Plumbing only: raw listings and single game operations, each verified by re-reading state. Which
 * command is allowed, rate limits, message formats and build validation belong to the Lua scripts.
 *
 *
 */

#ifndef MOD_LONELYICE_TACTICS_BOTS_H
#define MOD_LONELYICE_TACTICS_BOTS_H

#include "Define.h"
#include "PlayerbotAI.h"

#include <array>
#include <map>
#include <string>
#include <vector>

class Player;

namespace Tactics::Party
{
    // Same shape as the spec's `Result` (2.1); named differently because P1 defines its own private
    // Party::Result and may include this module's headers. `reason` strings are the Lua contract (spec 8).
    struct AiResult
    {
        bool ok = false;
        char const* reason = "failed";
        int32 a = 0;
        int32 b = 0;
    };

    // ------------------------------------------------------------------ bots (2.7)
    struct BotRow
    {
        uint32 guidLow = 0;
        std::string name;
        uint8 cls = 0;
        uint8 level = 0;
        uint8 state = 0;                  // 0 offline, 1 online under this player, 2 in use elsewhere
    };

    constexpr size_t MAX_ACCOUNT_BOTS = 128;

    // World thread only (synchronous characters query).
    void AccountBots(Player* requester, std::vector<BotRow>& out);

    // "pending" on success (login is asynchronous); bad_bot, not_allowed, in_use, already, max_bots.
    AiResult BotLogin(Player* requester, uint32 botLow);

    // bad_bot (not a bot of this player's manager), failed.
    AiResult BotLogout(Player* requester, uint32 botLow);

    // Low guid of the bot's playerbots master, 0 if none.
    uint32 Master(Player* bot);

    // Queues a whisper command from `requester` (the bot executes it on its own tick). Caller checks
    // who may command the bot. bad_cmd for empty / too long / control characters / debug commands.
    constexpr size_t MAX_COMMAND = 200;
    AiResult Command(Player* bot, Player* requester, std::string const& text);

    void Strategies(Player* bot, BotState state, std::vector<std::string>& out);

    // ------------------------------------------------------------------ talents (2.8)
    struct TalentRow
    {
        uint32 id = 0;
        uint8 tab = 0;                    // TalentTab.tabpage 0..2
        uint8 row = 0;
        uint8 col = 0;
        uint8 maxRank = 0;                // non-zero RankID count
        uint32 dependsOn = 0;
        uint32 dependsOnRank = 0;         // as in Talent.dbc (0-based rank index)
        std::array<uint32, 5> ranks = { };
    };

    // All talents of a class (1..11), sorted by (tab, row, col); cached per class, thread-safe.
    std::vector<TalentRow> const& TalentRows(uint8 cls);

    struct TalentInfoOut
    {
        uint32 active = 1;                // 1-based
        uint32 count = 1;
        uint32 free = 0;
        uint32 total = 0;
        uint32 minDualLevel = 0;
    };

    TalentInfoOut TalentInfo(Player* bot);

    // talentId -> rank (1..5) of the given spec (1 | 2; 0 = active); talents without a rank are omitted.
    void TalentRanks(Player* bot, uint8 spec, std::map<uint32, uint8>& out);

    // Points per tab of the active spec.
    std::array<uint32, 3> TalentTabPoints(Player* bot);

    // build = {tab, row, col, rank} in learning order (Lua sorts by row, then col). Free respec of the
    // ACTIVE spec. tabs = points per tab after the call. combat, bad_build, verify (not applied: the previous
    // build was learned back).
    AiResult ApplyTalents(Player* bot, std::vector<std::array<uint32, 4>> const& build, std::array<uint32, 3>& tabs);

    // spec 1 | 2: no_dualspec, already, combat, failed.
    AiResult ActivateSpec(Player* bot, uint8 spec);

    // already, level (a = required level), failed.
    AiResult LearnDualSpec(Player* bot);
}

#endif
