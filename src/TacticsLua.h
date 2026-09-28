/*
 * Bot tactics - Lua host (implementer B). B-private header, no Lua/sol2 includes.
 *
 * One LuaJIT state per OS thread (thread_local), rebuilt when the script version changes.
 * Every entry call runs under pcall with an instruction limit; units are passed to Lua as GUID
 * handles that are resolved again on every access (see the call context below).
 *
 *
 */

#ifndef MOD_LONELYICE_TACTICS_LUA_H
#define MOD_LONELYICE_TACTICS_LUA_H

#include "Define.h"
#include "ObjectGuid.h"

#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

class Map;
class Player;
class PlayerbotAI;
class Unit;
struct lua_State;

namespace Tactics::Lua
{
    // Lua-side unit handle (usertype "Unit"): only a GUID, resolved again on every method call.
    // Shared by TacticsLuaApi.cpp and the party window bindings (TacticsPartyApi.h).
    struct UnitHandle
    {
        ObjectGuid guid;
    };

    // One entry of the array returned by tactics.evaluate (spec 3.3). Only syntax is checked here;
    // the verb is dispatched (and unknown verbs skipped) by the engine.
    struct Decision
    {
        uint32 slot = 0;
        std::string list;                 // "co" / "nc"
        std::string verb;
        ObjectGuid target;                // empty = none given
        bool hasTarget = false;
        uint32 spell = 0;
        uint32 item = 0;
        float x = 0.0f, y = 0.0f, z = 0.0f;
        bool hasPos = false;
        float dist = 0.0f;
        bool hasDist = false;
        bool reach = true;
        std::string tag;
        std::string cmd;                  // verb "pet": attack|follow|stay|passive|defensive|aggressive (<= 16 bytes)
        std::string text;                 // verb "command": chat command text (<= Party::MAX_COMMAND bytes)
    };

    // Outcome of the previous tactics action execution, handed to Lua once as ctx.last.
    struct LastResult
    {
        uint32 slot = 0;
        std::string list;
        std::string verb;
        bool ok = false;
        std::string reason;
        uint32 at = 0;
    };

    struct EvalInput
    {
        char const* state = "combat";     // "combat" / "noncombat"
        uint32 now = 0;
        uint32 combatMs = 0;
        std::optional<LastResult> last;
    };

    // tactics.evaluate(bot, ctx). Returns false (and no decisions) on any error or "no decision".
    bool Evaluate(Player* bot, EvalInput const& input, uint32 maxCandidates, std::vector<Decision>& out);

    // tactics.on_message(player, payload) / tactics.on_event(event, player) on the calling thread.
    void OnMessage(Player* player, std::string const& payload);
    void OnEvent(char const* event, Player* player);

    // tactics.on_mirror(event, player, payload) (abilities-mirroring-spec 5.3): world thread, maps not updating,
    // same call context as on_message (anchor = the real player, no map). No-op when the scripts define none.
    void OnMirror(Player* player, std::string const& event, std::string const& payload);

    // Headless simulation, world thread only, no anchor (CallContext::sim).
    // tactics.on_sim_command(args) -> string | {strings} (lines for the command output; errors are added too).
    void OnSimCommand(std::string const& args, std::vector<std::string>& out);
    // tactics.on_tick(dtMs); false when the scripts define no on_tick or the call failed.
    bool OnTick(uint32 dtMs);

    // Bump the version and rebuild the calling thread's state now. Returns the load error or "".
    std::string ReloadNow();
    void BumpVersion();
    uint32 Version();

    struct Stats
    {
        uint32 liveStates = 0;
        uint64 evaluateCalls = 0;
        uint64 errors = 0;
        uint64 limitHits = 0;
        std::string lastLoadError;
    };
    Stats GetStats();

    // ------------------------------------------------------------------ call context (for bindings)
    struct CallContext
    {
        Player* anchor = nullptr;         // evaluating bot, or message/event player
        Map* map = nullptr;               // anchor's map for map-thread calls, nullptr for world-thread calls
        bool sim = false;                 // sim entry call (world thread, anchor nullptr): players resolve anywhere.
                                          // wow.sim.asLeader (TacticsSim.cpp) sets anchor to a selfbot sim leader
                                          // for the scope of one Lua function (party window self-test).
        std::unordered_map<ObjectGuid, Unit*> cache;
    };

    // nullptr outside an entry call (and while init.lua / includes run).
    CallContext* CurrentCall();

    // Resolve a handle GUID with the rules of spec 3.4 (per-call cache). nullptr when not resolvable.
    Unit* Resolve(ObjectGuid guid);

    std::string GuidToHex(ObjectGuid guid);
    bool HexToGuid(std::string const& text, ObjectGuid& out);

    // Implemented in TacticsLuaApi.cpp: creates the Unit usertype and fills the global table `wow`.
    void RegisterApi(lua_State* L);
}

#endif
