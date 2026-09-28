/*
 * Bot tactics - data-side scripts (spec section 1, implementer C):
 *   - addon chat intercept ("BTAC\t<frame>" whispers to self with LANG_ADDON) -> transport reassembly
 *   - login/logout events of real players -> Host::OnPlayerEvent (Lua tactics.on_event)
 *   - Store::Forget on logout of any character, row cleanup on character delete
 *   - outbox flush on the world thread
 */

#include "TacticsHost.h"

#include "Player.h"
#include "ScriptMgr.h"
#include "WorldSession.h"

// Internal entry points of TacticsTransport.cpp / TacticsStore.cpp (C-private, no header).
namespace Tactics::TransportDetail
{
    void Flush();
    void ReceiveFrame(Player* player, std::string const& frame);
    void ForgetSender(uint32 senderLow);
}

namespace Tactics::StoreDetail
{
    void DeleteCharacter(uint32 guidLow);
}

namespace
{
    bool IsRealPlayer(Player const* player)
    {
        return player && player->GetSession() && !player->GetSession()->IsBot();
    }
}

class TacticsDataWorldScript : public WorldScript
{
public:
    TacticsDataWorldScript() : WorldScript("TacticsDataWorldScript", { WORLDHOOK_ON_UPDATE }) { }

    void OnUpdate(uint32 /*diff*/) override
    {
        Tactics::TransportDetail::Flush();
    }
};

class TacticsDataPlayerScript : public PlayerScript
{
public:
    TacticsDataPlayerScript() : PlayerScript("TacticsDataPlayerScript",
        { PLAYERHOOK_ON_LOGIN, PLAYERHOOK_ON_BEFORE_LOGOUT, PLAYERHOOK_ON_LOGOUT, PLAYERHOOK_ON_DELETE,
          PLAYERHOOK_CAN_PLAYER_USE_PRIVATE_CHAT }) { }

    void OnPlayerLogin(Player* player) override
    {
        if (IsRealPlayer(player))
            Tactics::Host::OnPlayerEvent("login", player);
    }

    // Still in world here, so Lua can resolve the player.
    void OnPlayerBeforeLogout(Player* player) override
    {
        if (IsRealPlayer(player))
            Tactics::Host::OnPlayerEvent("logout", player);
    }

    void OnPlayerLogout(Player* player) override
    {
        uint32 const guidLow = player->GetGUID().GetCounter();
        Tactics::Store::Forget(guidLow);
        Tactics::TransportDetail::ForgetSender(guidLow);
    }

    void OnPlayerDelete(ObjectGuid guid, uint32 /*accountId*/) override
    {
        Tactics::StoreDetail::DeleteCharacter(guid.GetCounter());
    }

    // Addon frames arrive as whispers to self: "BTAC\t<flag><id><data>". Always swallowed.
    bool OnPlayerCanUseChat(Player* player, uint32 /*type*/, uint32 lang, std::string& msg, Player* receiver) override
    {
        if (lang != LANG_ADDON || msg.size() < 5 || msg.compare(0, 4, Tactics::ADDON_PREFIX) != 0 || msg[4] != '\t')
            return true;

        if (IsRealPlayer(player) && receiver == player)
            Tactics::TransportDetail::ReceiveFrame(player, msg.substr(5));

        return false;
    }
};

void AddTacticsDataScripts()
{
    new TacticsDataWorldScript();
    new TacticsDataPlayerScript();
}
