/*
 * Bot tactics - headless simulation metrics. No Lua/sol2 includes.
 *
 * Thread-safe per-GUID counters, filled by core hooks (damage, heal, deaths, casts, power, combat) and by
 * the tactics engine (guard_g1 / guard_g2 / casts_tactics), only for GUIDs put "on watch" by the sim
 * driver. Every hook starts with one relaxed atomic load, so the cost is nil while no simulation runs.
 * Key names are the Lua contract of sim/report.lua; C++ attaches no meaning to them.
 */

#ifndef MOD_LONELYICE_TACTICS_METRICS_H
#define MOD_LONELYICE_TACTICS_METRICS_H

#include "Define.h"
#include "ObjectGuid.h"

#include <map>
#include <string>

class WorldObject;

namespace Tactics::Metrics
{
    // True while at least one GUID is watched (cheap, lock-free).
    bool Active();

    // Counter key of an object: players by GUID; creatures by GUID with the instance id in place of the entry,
    // because creature low GUIDs repeat across instances of one map (parallel sim groups).
    ObjectGuid KeyOf(ObjectGuid guid, uint32 instanceId);
    ObjectGuid KeyOf(WorldObject const* object);

    bool Watched(ObjectGuid guid);
    void Watch(ObjectGuid guid, bool on);

    // counter[key] += value, only when guid is watched.
    void Add(ObjectGuid guid, std::string const& key, double value);

    // All counters of a guid (watched or not). "combat_ms" includes a combat still in progress.
    std::map<std::string, double> Get(ObjectGuid guid);

    // Drop the counters (and the combat timer) of one guid; the watch flag stays.
    void Reset(ObjectGuid guid);

    // Unwatch everything and drop all counters.
    void Clear();

    // Marks spells prepared on this thread while alive as cast by a tactics decision ("casts_tactics").
    // Spell::prepare runs synchronously inside PlayerbotAI::CastSpell / HandleUseItemOpcode.
    class TacticsCastScope
    {
    public:
        TacticsCastScope();
        ~TacticsCastScope();

        TacticsCastScope(TacticsCastScope const&) = delete;
        TacticsCastScope& operator=(TacticsCastScope const&) = delete;
    };
}

#endif
