/*
 * Bot tactics - party window bindings shared between TacticsLuaApi.cpp (core), TacticsInventoryApi.cpp (P1)
 * and TacticsAiApi.cpp (P2).
 */
#ifndef MOD_LONELYICE_TACTICS_PARTY_API_H
#define MOD_LONELYICE_TACTICS_PARTY_API_H

#include "TacticsLua.h"

#include <sol/sol.hpp>

namespace Tactics::Lua
{
    // Both add methods to the existing usertype "Unit" (bot methods) and functions to the "wow" table.
    // Called by RegisterApi (TacticsLuaApi.cpp) after the core methods are registered.
    void RegisterPartyApi(sol::state_view& lua, sol::usertype<UnitHandle>& unit, sol::table& wow);   // P1
    void RegisterAiApi(sol::state_view& lua, sol::usertype<UnitHandle>& unit, sol::table& wow);      // P2
    void RegisterExtrasApi(sol::state_view& lua, sol::usertype<UnitHandle>& unit, sol::table& wow);   // CPP extras
    void RegisterMirrorApi(sol::state_view& lua, sol::usertype<UnitHandle>& unit, sol::table& wow);   // abilities-mirroring-spec 5.3

    // Helpers exported by TacticsLuaApi.cpp for the two files above.
    Player* ResolvePlayerbot(UnitHandle const& h, PlayerbotAI*& ai);   // nullptr when not an online playerbot
    Player* MessagePlayer();                                           // CurrentCall()->anchor on a world-thread call, else nullptr
}

#endif
