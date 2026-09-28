/*
 * Bot tactics - party window primitives of package P2.
 *
 * Plumbing only: account bot listing, bot login/logout through the player's PlayerbotMgr, chat command
 * queueing, strategy listing and talent operations. Every mutation is verified by re-reading state.
 * Who may call what (ownership) is checked by the bindings (TacticsAiApi.cpp); rate limits, command
 * whitelist and build validation are Lua policy.
 */

#include "TacticsBots.h"

#include "CharacterCache.h"
#include "DatabaseEnv.h"
#include "DBCStores.h"
#include "Guild.h"
#include "GuildMgr.h"
#include "ObjectAccessor.h"
#include "Player.h"
#include "PlayerbotFactory.h"
#include "Playerbots.h"
#include "Timer.h"
#include "World.h"
#include "WorldSession.h"

#include <algorithm>
#include <mutex>
#include <unordered_map>

namespace Tactics::Party
{
    namespace
    {
        constexpr uint32 SPELL_DUAL_SPEC_LEARN = 63680;       // "Learn Dual Talent Specialization" (as MB L6641)
        constexpr uint32 SPELL_DUAL_SPEC_ACTIVATE = 63624;
        constexpr uint32 LOGIN_PENDING_MS = 15000;            // a login query holder normally finishes in < 1 s

        struct PendingLogin
        {
            uint32 masterAccount = 0;
            uint32 startMs = 0;
        };

        // World thread only. Logins started by BotLogin whose bot is not in the world yet: our view of
        // PlayerbotHolder::botLoading (protected), which AddPlayerBot counts toward maxAddedBots.
        std::unordered_map<uint32, PendingLogin> sPendingLogins;

        // Drops finished / stale entries; returns the logins still pending for this master account.
        uint32 PendingLoginsOf(uint32 masterAccount)
        {
            uint32 count = 0;
            for (auto itr = sPendingLogins.begin(); itr != sPendingLogins.end();)
            {
                Player* bot = ObjectAccessor::FindConnectedPlayer(ObjectGuid::Create<HighGuid::Player>(itr->first));
                if ((bot && bot->IsInWorld()) || GetMSTimeDiffToNow(itr->second.startMs) > LOGIN_PENDING_MS)
                {
                    itr = sPendingLogins.erase(itr);
                    continue;
                }

                if (itr->second.masterAccount == masterAccount)
                    ++count;
                ++itr;
            }

            return count;
        }

        AiResult Fail(char const* reason, int32 a = 0)
        {
            AiResult result;
            result.reason = reason;
            result.a = a;
            return result;
        }

        AiResult Ok(char const* reason = "ok")
        {
            AiResult result;
            result.ok = true;
            result.reason = reason;
            return result;
        }

        void ResetBotStrategies(Player* bot)
        {
            if (PlayerbotAI* botAI = GET_PLAYERBOT_AI(bot))
                botAI->ResetStrategies();
        }
    }

    // ================================================================== bots (2.7)
    void AccountBots(Player* requester, std::vector<BotRow>& out)
    {
        out.clear();
        if (!requester || !requester->GetSession())
            return;

        uint32 const accountId = requester->GetSession()->GetAccountId();
        uint32 const self = requester->GetGUID().GetCounter();
        PlayerbotMgr* mgr = GET_PLAYERBOT_MGR(requester);

        // same query as the MultiBot bridge (MB L11254)
        QueryResult result = CharacterDatabase.Query(
            "SELECT guid, name, class, level FROM characters WHERE account = {} AND deleteInfos_Name IS NULL ORDER BY guid",
            accountId);
        if (!result)
            return;

        do
        {
            Field* fields = result->Fetch();
            uint32 const low = fields[0].Get<uint32>();
            if (low == self)
                continue;

            if (out.size() >= MAX_ACCOUNT_BOTS)
                break;

            BotRow row;
            row.guidLow = low;
            row.name = fields[1].Get<std::string>();
            row.cls = fields[2].Get<uint8>();
            row.level = fields[3].Get<uint8>();

            ObjectGuid const guid = ObjectGuid::Create<HighGuid::Player>(low);
            if (mgr && mgr->GetPlayerBot(guid))
                row.state = 1;
            else if (ObjectAccessor::FindConnectedPlayer(guid))
                row.state = 2;

            out.push_back(std::move(row));
        } while (result->NextRow());
    }

    AiResult BotLogin(Player* requester, uint32 botLow)
    {
        if (!requester || !requester->GetSession() || !botLow)
            return Fail("bad_bot");

        ObjectGuid const guid = ObjectGuid::Create<HighGuid::Player>(botLow);
        if (guid == requester->GetGUID())
            return Fail("bad_bot");

        CharacterCacheEntry const* cache = sCharacterCache->GetCharacterCacheByGuid(guid);
        if (!cache)
            return Fail("bad_bot");

        PlayerbotMgr* mgr = GET_PLAYERBOT_MGR(requester);
        if (!mgr)
            return Fail("not_allowed");

        // Exactly the relations PlayerbotHolder::AddPlayerBot (PlayerbotMgr.cpp:103-113) accepts: it only
        // tells the player in chat otherwise, so the ACK would say "pending" for a login that never comes.
        uint32 const accountId = requester->GetSession()->GetAccountId();
        bool const sameAccount = sPlayerbotAIConfig.allowAccountBots && cache->AccountId == accountId;
        Guild* guild = sGuildMgr->GetGuildById(requester->GetGuildId());
        bool const sameGuild = sPlayerbotAIConfig.allowGuildBots && guild && guild->GetMember(guid);
        bool const addClassBot = sRandomPlayerbotMgr.IsAddclassBot(botLow);
        bool const linkedAccount = sPlayerbotAIConfig.allowTrustedAccountBots &&
                                   mgr->IsAccountLinked(cache->AccountId, accountId);   // DB query, last
        if (!sameAccount && !sameGuild && !addClassBot && !linkedAccount)
            return Fail("not_allowed");

        // checked before in_use: a bot of this player is also a connected player
        if (mgr->GetPlayerBot(guid))
            return Fail("already");

        if (ObjectAccessor::FindConnectedPlayer(guid))
            return Fail("in_use");

        // AddPlayerBot counts the logins still loading toward the limit; a repeated LOGIN of a pending bot
        // is ignored by it (botLoading), so answer "pending" again without calling it.
        uint32 const pending = PendingLoginsOf(accountId);
        if (sPendingLogins.count(botLow))
            return Ok("pending");

        if (mgr->GetPlayerbotsCount() + pending >= uint32(std::max<int32>(0, sPlayerbotAIConfig.maxAddedBots)))
            return Fail("max_bots");

        mgr->AddPlayerBot(guid, accountId);   // asynchronous: login query holder, finished by the world update
        if (mgr->GetPlayerBot(guid))
            return Ok();

        PendingLogin& entry = sPendingLogins[botLow];
        entry.masterAccount = accountId;
        entry.startMs = getMSTime();
        return Ok("pending");
    }

    AiResult BotLogout(Player* requester, uint32 botLow)
    {
        PlayerbotMgr* mgr = requester ? GET_PLAYERBOT_MGR(requester) : nullptr;
        ObjectGuid const guid = ObjectGuid::Create<HighGuid::Player>(botLow);
        if (!mgr || !botLow || !mgr->GetPlayerBot(guid))
            return Fail("bad_bot");

        mgr->LogoutPlayerBot(guid);   // deletes the bot's Player object (caller drops cached pointers)
        return mgr->GetPlayerBot(guid) ? Fail("failed") : Ok();
    }

    uint32 Master(Player* bot)
    {
        PlayerbotAI* botAI = bot ? GET_PLAYERBOT_AI(bot) : nullptr;
        Player* master = botAI ? botAI->GetMaster() : nullptr;
        return master ? uint32(master->GetGUID().GetCounter()) : 0;
    }

    AiResult Command(Player* bot, Player* requester, std::string const& text)
    {
        PlayerbotAI* botAI = bot ? GET_PLAYERBOT_AI(bot) : nullptr;
        if (!botAI || !requester)
            return Fail("bad_bot");

        if (text.empty() || text.size() > MAX_COMMAND)
            return Fail("bad_cmd");

        for (char c : text)
            if (uint8(c) < 0x20 || uint8(c) == 0x7F)
                return Fail("bad_cmd");

        // Defence in depth under the Lua whitelist: PlayerbotAI::HandleCommand splits on the command
        // separator and runs "debug ..." / "d ..." / "do ..." immediately instead of queueing them.
        std::string const& separator = sPlayerbotAIConfig.commandSeparator;
        if (!separator.empty() && text.find(separator) != std::string::npos)
            return Fail("bad_cmd");

        if (text.rfind("debug ", 0) == 0 || text.rfind("d ", 0) == 0 || text.rfind("do ", 0) == 0)
            return Fail("bad_cmd");

        botAI->HandleCommand(CHAT_MSG_WHISPER, text, requester);
        return Ok();
    }

    void Strategies(Player* bot, BotState state, std::vector<std::string>& out)
    {
        out.clear();
        PlayerbotAI* botAI = bot ? GET_PLAYERBOT_AI(bot) : nullptr;
        if (botAI && state < BOT_STATE_MAX)
            out = botAI->GetStrategies(state);
    }

    // ================================================================== talents (2.8)
    std::vector<TalentRow> const& TalentRows(uint8 cls)
    {
        static std::vector<TalentRow> const empty;
        static std::mutex lock;
        static std::map<uint8, std::vector<TalentRow>> cache;   // nodes are never erased: references stay valid

        if (cls == 0 || cls >= MAX_CLASSES)
            return empty;

        std::lock_guard<std::mutex> guard(lock);
        auto itr = cache.find(cls);
        if (itr != cache.end())
            return itr->second;

        std::vector<TalentRow> rows;
        uint32 const classMask = 1u << (cls - 1);
        for (uint32 i = 0; i < sTalentStore.GetNumRows(); ++i)
        {
            TalentEntry const* talent = sTalentStore.LookupEntry(i);
            if (!talent)
                continue;

            TalentTabEntry const* tab = sTalentTabStore.LookupEntry(talent->TalentTab);
            if (!tab || !(tab->ClassMask & classMask) || tab->tabpage >= 3)
                continue;

            TalentRow row;
            row.id = talent->TalentID;
            row.tab = uint8(tab->tabpage);
            row.row = uint8(talent->Row);
            row.col = uint8(talent->Col);
            row.dependsOn = talent->DependsOn;
            row.dependsOnRank = talent->DependsOnRank;
            for (uint8 r = 0; r < MAX_TALENT_RANK; ++r)
            {
                row.ranks[r] = talent->RankID[r];
                if (talent->RankID[r])
                    ++row.maxRank;
            }

            if (row.maxRank)
                rows.push_back(row);
        }

        std::sort(rows.begin(), rows.end(), [](TalentRow const& a, TalentRow const& b)
        {
            if (a.tab != b.tab)
                return a.tab < b.tab;
            if (a.row != b.row)
                return a.row < b.row;
            return a.col < b.col;
        });

        return cache.emplace(cls, std::move(rows)).first->second;
    }

    TalentInfoOut TalentInfo(Player* bot)
    {
        TalentInfoOut out;
        out.active = uint32(bot->GetActiveSpec()) + 1;
        out.count = bot->GetSpecsCount();
        out.free = bot->GetFreeTalentPoints();
        out.total = bot->CalculateTalentsPoints();
        out.minDualLevel = sWorld->getIntConfig(CONFIG_MIN_DUALSPEC_LEVEL);
        return out;
    }

    void TalentRanks(Player* bot, uint8 spec, std::map<uint32, uint8>& out)
    {
        out.clear();
        uint8 const index = spec ? uint8(spec - 1) : bot->GetActiveSpec();
        if (index >= bot->GetSpecsCount())
            return;

        for (TalentRow const& row : TalentRows(bot->getClass()))
        {
            for (int r = int(row.maxRank) - 1; r >= 0; --r)
            {
                if (row.ranks[r] && bot->HasTalent(row.ranks[r], index))
                {
                    out[row.id] = uint8(r + 1);
                    break;
                }
            }
        }
    }

    std::array<uint32, 3> TalentTabPoints(Player* bot)
    {
        std::array<uint32, 3> tabs = { 0, 0, 0 };
        std::map<uint32, uint8> ranks;
        TalentRanks(bot, 0, ranks);
        for (TalentRow const& row : TalentRows(bot->getClass()))
        {
            auto itr = ranks.find(row.id);
            if (itr != ranks.end())
                tabs[row.tab] += itr->second;
        }

        return tabs;
    }

    AiResult ApplyTalents(Player* bot, std::vector<std::array<uint32, 4>> const& build, std::array<uint32, 3>& tabs)
    {
        tabs = TalentTabPoints(bot);
        if (bot->IsInCombat())
            return Fail("combat");

        // Syntax only (the tree rules are Lua's): every entry names a talent of this class at a rank it has.
        std::vector<TalentRow> const& rows = TalentRows(bot->getClass());
        std::array<uint32, 3> expected = { 0, 0, 0 };
        uint32 total = 0;
        std::vector<std::vector<uint32>> parsed;
        parsed.reserve(build.size());
        for (std::array<uint32, 4> const& entry : build)
        {
            uint32 const tab = entry[0], row = entry[1], col = entry[2], rank = entry[3];
            auto talent = std::find_if(rows.begin(), rows.end(), [&](TalentRow const& r)
            {
                return r.tab == tab && r.row == row && r.col == col;
            });

            if (talent == rows.end() || rank == 0 || rank > talent->maxRank)
                return Fail("bad_build");

            expected[tab] += rank;
            total += rank;
            parsed.push_back({ tab, row, col, rank });
        }

        if (total > bot->CalculateTalentsPoints())
            return Fail("bad_build");

        // The current build, in tree order (tab, row, col: every tier's prerequisites come first), for the rollback.
        std::map<uint32, uint8> before;
        TalentRanks(bot, 0, before);
        std::vector<std::vector<uint32>> previous;
        for (TalentRow const& row : rows)
        {
            auto itr = before.find(row.id);
            if (itr != before.end())
                previous.push_back({ row.tab, row.row, row.col, itr->second });
        }

        if (bot->IsNonMeleeSpellCast(false))
            bot->InterruptNonMeleeSpells(false);

        // free respec of the active spec, then learn in the given order (PlayerbotFactory.cpp:1833)
        PlayerbotFactory::InitTalentsByParsedSpecLink(bot, parsed, true);
        tabs = TalentTabPoints(bot);
        bool const applied = tabs == expected;
        if (!applied)
        {
            // InitTalentsByParsedSpecLink stops silently (empty row, no free points: a level change or a stale
            // total), which would leave the bot half-specced: put the previous build back. "verify" then means
            // "the build was not applied, reload the talents".
            PlayerbotFactory::InitTalentsByParsedSpecLink(bot, previous, true);
            tabs = TalentTabPoints(bot);
        }

        ResetBotStrategies(bot);
        return applied ? Ok() : Fail("verify");
    }

    AiResult ActivateSpec(Player* bot, uint8 spec)
    {
        if (spec < 1 || spec > bot->GetSpecsCount())
            return Fail("no_dualspec");

        uint8 const index = uint8(spec - 1);
        if (bot->GetActiveSpec() == index)
            return Fail("already");

        if (bot->IsInCombat())
            return Fail("combat");

        if (bot->IsNonMeleeSpellCast(false))
            bot->InterruptNonMeleeSpells(false);

        bot->ActivateSpec(index);   // MB L6653
        if (bot->GetActiveSpec() != index)
            return Fail("failed");

        ResetBotStrategies(bot);
        return Ok();
    }

    AiResult LearnDualSpec(Player* bot)
    {
        if (bot->GetSpecsCount() >= 2)
            return Fail("already");

        uint32 const minLevel = sWorld->getIntConfig(CONFIG_MIN_DUALSPEC_LEVEL);
        if (bot->GetLevel() < minLevel)
            return Fail("level", int32(minLevel));

        // free, as the bridge did (MB L6641; open question Q2)
        bot->CastSpell(bot, SPELL_DUAL_SPEC_LEARN, true, nullptr, nullptr, bot->GetGUID());
        bot->CastSpell(bot, SPELL_DUAL_SPEC_ACTIVATE, true, nullptr, nullptr, bot->GetGUID());
        return bot->GetSpecsCount() >= 2 ? Ok() : Fail("failed");
    }
}
