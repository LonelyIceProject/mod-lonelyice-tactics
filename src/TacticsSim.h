/*
 * Bot tactics - headless bot simulation.
 *
 * Lua bindings of the sim primitives (`wow.sim.*`, TacticsSim.cpp) and of the metrics counters
 * (`wow.metrics.*`, TacticsMetrics.cpp). Called by RegisterApi (TacticsLuaApi.cpp) after the core
 * bindings. The scenario state machine, end-of-fight criteria and the report are Lua (sim/*.lua).
 * wow.sim.asLeader runs a Lua function as a message call of a selfbot sim leader (party window self-test,
 * sim/selftest.lua); see the header comment of TacticsSim.cpp for its limits.
 */

#ifndef MOD_LONELYICE_TACTICS_SIM_H
#define MOD_LONELYICE_TACTICS_SIM_H

#include "TacticsLua.h"

#include <sol/sol.hpp>

namespace Tactics::Lua
{
    void RegisterSimApi(sol::state_view& lua, sol::table& wow);       // wow.sim
    void RegisterMetricsApi(sol::state_view& lua, sol::table& wow);   // wow.metrics
}

#endif
