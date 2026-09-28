/*
 * Bot tactics - Lua host (implementer B).
 *
 * thread_local LuaJIT states, sandbox, instruction/memory limits, hot reload and the entry calls
 * (tactics.evaluate / tactics.on_message / tactics.on_event; headless sim: tactics.on_sim_command /
 * tactics.on_tick, bot-sim-design). See spec section 3.1.
 */

#include "TacticsLua.h"

#include "Log.h"
#include "Map.h"
#include "ObjectAccessor.h"
#include "Player.h"
#include "StringFormat.h"
#include "TacticsEngine.h"
#include "Timer.h"

#include <sol/sol.hpp>
#include <luajit.h>

#include <atomic>
#include <cmath>
#include <fstream>
#include <memory>
#include <mutex>
#include <sstream>
#include <unordered_set>

namespace Tactics::Lua
{
    // Defined in TacticsLuaApi.cpp.
    sol::object MakeHandle(lua_State* L, ObjectGuid guid);

    namespace
    {
        std::atomic<uint32> sVersion{ 1 };
        std::atomic<uint32> sLiveStates{ 0 };
        std::atomic<uint64> sEvaluateCalls{ 0 };
        std::atomic<uint64> sErrors{ 0 };
        std::atomic<uint64> sLimitHits{ 0 };

        std::mutex sLoadErrorLock;
        std::string sLastLoadError;

        char const* const LIMIT_MESSAGE = "tactics: instruction limit";

        struct Holder
        {
            std::unique_ptr<sol::state> lua;
            uint32 version = 0;
            bool failed = false;
            bool busy = false;
            std::unordered_map<std::string, sol::reference> includes;
            std::unordered_set<std::string> including;

            ~Holder() { Destroy(); }

            void Destroy()
            {
                includes.clear();
                including.clear();
                if (lua)
                {
                    lua.reset();
                    --sLiveStates;
                }
            }
        };

        thread_local Holder tHolder;
        thread_local CallContext* tCall = nullptr;
        thread_local bool tLimitHit = false;

        void SetLoadError(std::string const& error)
        {
            std::lock_guard<std::mutex> guard(sLoadErrorLock);
            sLastLoadError = error;
        }

        // Same "instruction limit" substring, so scripts that re-raise limit errors also re-raise this one.
        char const* const MEMORY_MESSAGE = "tactics: instruction limit (memory)";

        // The count hook fires every HOOK_STEP instructions: it spends the call's instruction budget and
        // also enforces the memory cap during the call (not only after it returns).
        constexpr uint32 HOOK_STEP = 1000;
        constexpr size_t STRING_REP_CAP = 1024 * 1024;

        constexpr size_t MAX_DECISION_CMD = 16;       // decision field `cmd` (verb "pet")
        constexpr size_t MAX_DECISION_TEXT = 200;     // decision field `text` (verb "command"), = Party::MAX_COMMAND

        thread_local uint32 tBudget = 0;
        thread_local char const* tLimitMessage = LIMIT_MESSAGE;

        void InstructionHook(lua_State* L, lua_Debug* /*ar*/)
        {
            if (!tLimitHit)
            {
                char const* message = nullptr;
                if (tBudget <= HOOK_STEP)
                    message = LIMIT_MESSAGE;
                else
                {
                    tBudget -= HOOK_STEP;
                    if (uint64(lua_gc(L, LUA_GCCOUNT, 0)) > uint64(Config().memoryLimitMB) * 1024)
                        message = MEMORY_MESSAGE;
                }

                if (!message)
                    return;

                // Fire on every instruction from now on, so a script that swallows the error with pcall
                // is stopped at its next instruction outside that pcall.
                tLimitHit = true;
                tLimitMessage = message;
                lua_sethook(L, InstructionHook, LUA_MASKCOUNT, 1);
            }

            luaL_error(L, tLimitMessage);
        }

        void SetLimit(lua_State* L, uint32 limit)
        {
            tLimitHit = false;
            tLimitMessage = LIMIT_MESSAGE;
            tBudget = limit;
            lua_sethook(L, InstructionHook, LUA_MASKCOUNT, int(std::min<uint32>(limit, HOOK_STEP)));
        }

        // string.rep with a result size cap: one VM instruction must not allocate unbounded memory.
        int LuaStringRep(lua_State* L)
        {
            size_t len = 0;
            luaL_checklstring(L, 1, &len);
            lua_Number const count = luaL_checknumber(L, 2);
            size_t sepLen = 0;
            if (!lua_isnoneornil(L, 3))
                luaL_checklstring(L, 3, &sepLen);

            if (count > 0 && (double(len) + double(sepLen)) * count > double(STRING_REP_CAP))
                return luaL_error(L, "string.rep: result larger than %d bytes", int(STRING_REP_CAP));

            lua_pushvalue(L, lua_upvalueindex(1));
            lua_insert(L, 1);
            lua_call(L, lua_gettop(L) - 1, 1);
            return 1;
        }

        void ClearLimit(lua_State* L)
        {
            lua_sethook(L, nullptr, 0, 0);
        }

        bool ValidIncludePath(std::string const& path)
        {
            if (path.size() < 5 || path.size() > 200 || path.compare(path.size() - 4, 4, ".lua") != 0)
                return false;

            if (path.front() == '/' || path.find("..") != std::string::npos || path.find("//") != std::string::npos)
                return false;

            for (size_t i = 0; i + 4 < path.size(); ++i)
            {
                char const c = path[i];
                if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '-' || c == '/'))
                    return false;
            }

            return true;
        }

        bool ReadScript(std::string const& relPath, std::string& out)
        {
            std::ifstream file(Config().scriptDir + "/" + relPath, std::ios::in | std::ios::binary);
            if (!file)
                return false;

            std::ostringstream buffer;
            buffer << file.rdbuf();
            out = buffer.str();
            return true;
        }

        // wow.include(path): load <ScriptDir>/<path> once per state and return its first result.
        int LuaInclude(lua_State* L)
        {
            size_t len = 0;
            char const* raw = luaL_checklstring(L, 1, &len);
            std::string const path(raw, len);
            if (!ValidIncludePath(path))
                return luaL_error(L, "wow.include: invalid path '%s'", raw);

            auto cached = tHolder.includes.find(path);
            if (cached != tHolder.includes.end())
            {
                cached->second.push(L);
                return 1;
            }

            if (tHolder.including.count(path))
                return luaL_error(L, "wow.include: include cycle at '%s'", raw);

            std::string source;
            if (!ReadScript(path, source))
                return luaL_error(L, "wow.include: cannot read '%s'", raw);

            std::string const chunkName = "@" + path;
            if (luaL_loadbuffer(L, source.data(), source.size(), chunkName.c_str()) != 0)
                return lua_error(L);

            tHolder.including.insert(path);
            int const status = lua_pcall(L, 0, 1, 0);
            tHolder.including.erase(path);
            if (status != 0)
                return lua_error(L);

            tHolder.includes[path] = sol::reference(L, -1);
            return 1;
        }

        int LuaPrint(lua_State* L)
        {
            int const n = lua_gettop(L);
            std::string message;
            lua_getglobal(L, "tostring");
            for (int i = 1; i <= n; ++i)
            {
                lua_pushvalue(L, -1);
                lua_pushvalue(L, i);
                lua_call(L, 1, 1);
                size_t len = 0;
                char const* text = lua_tolstring(L, -1, &len);
                if (i > 1)
                    message += ' ';
                if (text)
                    message.append(text, len);
                lua_pop(L, 1);
            }

            lua_pop(L, 1);
            LOG_INFO("module", "[tactics] {}", message);
            return 0;
        }

        // Runs a script file of the ScriptDir in the given state. Returns an error message or "".
        std::string RunFile(sol::state& lua, std::string const& relPath)
        {
            std::string source;
            if (!ReadScript(relPath, source))
                return "cannot read " + Config().scriptDir + "/" + relPath;

            sol::load_result chunk = lua.load_buffer(source.data(), source.size(), "@" + relPath);
            if (!chunk.valid())
            {
                sol::error err = chunk;
                return err.what();
            }

            sol::protected_function fn = chunk;
            SetLimit(lua.lua_state(), Config().messageInstructionLimit);
            sol::protected_function_result result = fn();
            ClearLimit(lua.lua_state());
            if (!result.valid())
            {
                sol::error err = result;
                return err.what();
            }

            return "";
        }

        void Sandbox(sol::state& lua)
        {
            for (char const* name : { "dofile", "loadfile", "load", "loadstring", "require", "module", "getfenv",
                                      "setfenv", "collectgarbage", "newproxy" })
                lua[name] = sol::lua_nil;

            sol::optional<sol::table> string = lua["string"];
            if (string)
                (*string)["dump"] = sol::lua_nil;

            // string.rep -> capped wrapper around the original
            lua_State* L = lua.lua_state();
            lua_getglobal(L, "string");
            if (lua_istable(L, -1))
            {
                lua_getfield(L, -1, "rep");
                if (lua_isfunction(L, -1))
                {
                    lua_pushcclosure(L, &LuaStringRep, 1);
                    lua_setfield(L, -2, "rep");
                }
                else
                    lua_pop(L, 1);
            }

            lua_pop(L, 1);
        }

        // (Re)creates the calling thread's state for the given version. Returns nullptr on failure.
        sol::state* Build(uint32 version)
        {
            tHolder.Destroy();
            tHolder.version = version;
            tHolder.failed = false;

            tHolder.lua = std::make_unique<sol::state>();
            ++sLiveStates;
            sol::state& lua = *tHolder.lua;

            lua.open_libraries(sol::lib::base, sol::lib::string, sol::lib::table, sol::lib::math, sol::lib::bit32);
            if (!Config().jit)
                luaJIT_setmode(lua.lua_state(), 0, LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF);

            Sandbox(lua);

            lua["tactics"] = lua.create_table();
            std::string error;
            try
            {
                RegisterApi(lua.lua_state());
                sol::table wow = lua["wow"];
                wow["include"] = &LuaInclude;
                lua["print"] = &LuaPrint;
                error = RunFile(lua, "init.lua");
            }
            catch (std::exception const& e)
            {
                ClearLimit(lua.lua_state());
                error = e.what();
            }

            if (error.empty())
            {
                sol::optional<sol::table> tactics = lua["tactics"];
                if (!tactics || (*tactics)["evaluate"].get_type() != sol::type::function ||
                    (*tactics)["on_message"].get_type() != sol::type::function)
                    error = "init.lua must define tactics.evaluate and tactics.on_message";
            }

            if (!error.empty())
            {
                LOG_ERROR("module", "[tactics] script load failed (version {}): {}", version, error);
                SetLoadError(error);
                tHolder.Destroy();
                tHolder.failed = true;
                return nullptr;
            }

            SetLoadError("");
            LOG_DEBUG("module", "[tactics] Lua state ready (version {})", version);
            return tHolder.lua.get();
        }

        sol::state* EnsureState()
        {
            uint32 const version = sVersion.load();
            if (tHolder.version == version)
            {
                if (tHolder.failed)
                    return nullptr;

                if (tHolder.lua)
                    return tHolder.lua.get();
            }

            return Build(version);
        }

        // Runs fn(state) as an entry call: re-entrancy guard, call context, instruction limit, memory check.
        // fn returns an error message ("" = fine).
        // Returns false when fn did not run to completion without error.
        template <typename Fn>
        bool RunEntry(char const* what, Player* anchor, Map* map, uint32 limit, Fn&& fn, bool sim = false)
        {
            if (tHolder.busy || !Config().enable)
                return false;

            sol::state* lua = EnsureState();
            if (!lua)
                return false;

            CallContext ctx;
            ctx.anchor = anchor;
            ctx.map = map;
            ctx.sim = sim;

            tHolder.busy = true;
            tCall = &ctx;
            lua_State* L = lua->lua_state();
            SetLimit(L, limit);

            std::string error;
            try
            {
                error = fn(*lua);
            }
            catch (std::exception const& e)
            {
                error = e.what();
            }

            ClearLimit(L);
            tCall = nullptr;
            tHolder.busy = false;

            bool drop = false;
            if (tLimitHit)
            {
                ++sLimitHits;
                drop = true;    // the state may be left inside an aborted hook; rebuild it
            }

            if (!error.empty())
            {
                ++sErrors;
                LogErrorLimited(std::string(what) + ": " + error);
            }

            int const kb = lua_gc(L, LUA_GCCOUNT, 0);
            if (uint64(kb) > uint64(Config().memoryLimitMB) * 1024)
            {
                LOG_ERROR("module", "[tactics] Lua state uses {} KB (limit {} MB), dropping it", kb, Config().memoryLimitMB);
                drop = true;
            }

            if (drop)
            {
                tHolder.Destroy();
                tHolder.version = 0;    // rebuilt on the next call
                tHolder.failed = false;
            }

            return error.empty() && !drop;
        }

        bool ReadNumber(sol::table const& t, char const* key, double& out)
        {
            sol::object value = t.get<sol::object>(key);
            if (value.get_type() != sol::type::number)
                return false;

            out = value.as<double>();
            return std::isfinite(out);
        }

        bool ReadString(sol::table const& t, char const* key, std::string& out)
        {
            sol::object value = t.get<sol::object>(key);
            if (value.get_type() != sol::type::string)
                return false;

            out = value.as<std::string>();
            return true;
        }

        bool ReadUInt(sol::table const& t, char const* key, uint32& out)
        {
            double value = 0.0;
            if (!ReadNumber(t, key, value) || value < 0.0 || value > 4294967295.0 || std::floor(value) != value)
                return false;

            out = uint32(value);
            return true;
        }

        // Syntax only; returns false (with a reason) for a malformed entry.
        bool ParseDecision(sol::table const& t, Decision& d, std::string& why)
        {
            if (!ReadUInt(t, "slot", d.slot) || d.slot < 1)
                return why = "bad slot", false;

            if (!ReadString(t, "list", d.list) || (d.list != "co" && d.list != "nc"))
                return why = "bad list", false;

            if (!ReadString(t, "verb", d.verb) || d.verb.empty())
                return why = "bad verb", false;

            sol::object target = t.get<sol::object>("target");
            if (target.get_type() == sol::type::string)
            {
                if (!HexToGuid(target.as<std::string>(), d.target))
                    return why = "bad target", false;

                d.hasTarget = true;
            }
            else if (target.get_type() != sol::type::lua_nil)
                return why = "bad target", false;

            if (t.get<sol::object>("spell").get_type() != sol::type::lua_nil && !ReadUInt(t, "spell", d.spell))
                return why = "bad spell", false;

            if (t.get<sol::object>("item").get_type() != sol::type::lua_nil && !ReadUInt(t, "item", d.item))
                return why = "bad item", false;

            double x = 0.0, y = 0.0, z = 0.0;
            if (ReadNumber(t, "x", x) && ReadNumber(t, "y", y) && ReadNumber(t, "z", z))
            {
                d.x = float(x);
                d.y = float(y);
                d.z = float(z);
                d.hasPos = true;
            }

            double dist = 0.0;
            if (ReadNumber(t, "dist", dist))
            {
                d.dist = float(dist);
                d.hasDist = true;
            }

            sol::object reach = t.get<sol::object>("reach");
            if (reach.get_type() == sol::type::boolean)
                d.reach = reach.as<bool>();

            if (ReadString(t, "tag", d.tag) && d.tag.size() > 32)
                d.tag.resize(32);

            // abilities-mirroring-spec 2.2: "pet" sub-command and "command" text
            sol::object cmd = t.get<sol::object>("cmd");
            if (cmd.get_type() != sol::type::lua_nil && (!ReadString(t, "cmd", d.cmd) || d.cmd.size() > MAX_DECISION_CMD))
                return why = "bad cmd", false;

            sol::object text = t.get<sol::object>("text");
            if (text.get_type() != sol::type::lua_nil &&
                (!ReadString(t, "text", d.text) || d.text.size() > MAX_DECISION_TEXT))
                return why = "bad text", false;

            return true;
        }
    }

    // ================================================================== entry calls
    bool Evaluate(Player* bot, EvalInput const& input, uint32 maxCandidates, std::vector<Decision>& out)
    {
        out.clear();
        if (!bot || !bot->IsInWorld())
            return false;

        ++sEvaluateCalls;
        RunEntry("evaluate", bot, bot->GetMap(), Config().instructionLimit, [&](sol::state& lua) -> std::string
        {
            sol::table tactics = lua["tactics"];
            sol::protected_function evaluate = tactics["evaluate"];

            sol::table ctx = lua.create_table();
            ctx["state"] = input.state;
            ctx["now"] = input.now;
            ctx["combatMs"] = input.combatMs;
            if (input.last)
            {
                sol::table last = lua.create_table();
                last["slot"] = input.last->slot;
                last["list"] = input.last->list;
                last["verb"] = input.last->verb;
                last["ok"] = input.last->ok;
                last["reason"] = input.last->reason;
                last["at"] = input.last->at;
                ctx["last"] = last;
            }

            sol::protected_function_result result = evaluate(MakeHandle(lua.lua_state(), bot->GetGUID()), ctx);
            if (!result.valid())
            {
                sol::error err = result;
                return err.what();
            }

            sol::object ret = result;
            if (ret.get_type() == sol::type::lua_nil)
                return "";

            if (ret.get_type() != sol::type::table)
            {
                LogWarnLimited("tactics.evaluate returned a non-table value");
                return "";
            }

            sol::table list = ret.as<sol::table>();
            for (uint32 i = 1; i <= maxCandidates; ++i)
            {
                sol::object entry = list[i];
                if (entry.get_type() == sol::type::lua_nil)
                    break;

                Decision d;
                std::string why = "not a table";
                if (entry.get_type() != sol::type::table || !ParseDecision(entry.as<sol::table>(), d, why))
                {
                    LogWarnLimited("tactics.evaluate: skipped decision " + std::to_string(i) + " (" + why + ")");
                    continue;
                }

                out.push_back(std::move(d));
            }

            return "";
        });

        return !out.empty();
    }

    void OnMessage(Player* player, std::string const& payload)
    {
        if (!player)
            return;

        RunEntry("on_message", player, nullptr, Config().messageInstructionLimit, [&](sol::state& lua) -> std::string
        {
            sol::table tactics = lua["tactics"];
            sol::protected_function fn = tactics["on_message"];
            sol::protected_function_result result = fn(MakeHandle(lua.lua_state(), player->GetGUID()), payload);
            if (!result.valid())
            {
                sol::error err = result;
                return err.what();
            }

            return "";
        });
    }

    void OnEvent(char const* event, Player* player)
    {
        if (!player || !event)
            return;

        RunEntry("on_event", player, nullptr, Config().messageInstructionLimit, [&](sol::state& lua) -> std::string
        {
            sol::table tactics = lua["tactics"];
            sol::object handler = tactics["on_event"];
            if (handler.get_type() != sol::type::function)
                return "";

            sol::protected_function fn = handler.as<sol::protected_function>();
            sol::protected_function_result result = fn(std::string(event), MakeHandle(lua.lua_state(), player->GetGUID()));
            if (!result.valid())
            {
                sol::error err = result;
                return err.what();
            }

            return "";
        });
    }

    void OnMirror(Player* player, std::string const& event, std::string const& payload)
    {
        if (!player || event.empty())
            return;

        RunEntry("on_mirror", player, nullptr, Config().messageInstructionLimit, [&](sol::state& lua) -> std::string
        {
            sol::table tactics = lua["tactics"];
            sol::object handler = tactics["on_mirror"];
            if (handler.get_type() != sol::type::function)
                return "";

            sol::protected_function fn = handler.as<sol::protected_function>();
            sol::protected_function_result result = fn(event, MakeHandle(lua.lua_state(), player->GetGUID()), payload);
            if (!result.valid())
            {
                sol::error err = result;
                return err.what();
            }

            return "";
        });
    }

    // ================================================================== sim entry calls (world thread)
    void OnSimCommand(std::string const& args, std::vector<std::string>& out)
    {
        constexpr size_t MAX_LINES = 60;
        out.clear();
        bool const done = RunEntry("on_sim_command", nullptr, nullptr, Config().messageInstructionLimit,
            [&](sol::state& lua) -> std::string
        {
            sol::table tactics = lua["tactics"];
            sol::object handler = tactics["on_sim_command"];
            if (handler.get_type() != sol::type::function)
            {
                out.push_back("tactics: the scripts define no tactics.on_sim_command (sim/driver.lua not loaded)");
                return "";
            }

            sol::protected_function fn = handler.as<sol::protected_function>();
            sol::protected_function_result result = fn(args);
            if (!result.valid())
            {
                sol::error err = result;
                out.push_back(std::string("tactics sim: error: ") + err.what());
                return err.what();
            }

            sol::object ret = result;
            if (ret.get_type() == sol::type::string)
                out.push_back(ret.as<std::string>());
            else if (ret.get_type() == sol::type::table)
            {
                sol::table lines = ret.as<sol::table>();
                for (size_t i = 1; i <= MAX_LINES; ++i)
                {
                    sol::object line = lines[i];
                    if (line.get_type() != sol::type::string)
                        break;

                    out.push_back(line.as<std::string>());
                }
            }

            return "";
        }, true);

        if (!done && out.empty())
        {
            std::lock_guard<std::mutex> guard(sLoadErrorLock);
            out.push_back("tactics sim: call failed (scripts disabled, not loaded or limit hit): " +
                          (sLastLoadError.empty() ? std::string("see the server log") : sLastLoadError));
        }
    }

    bool OnTick(uint32 dtMs)
    {
        bool defined = false;
        bool const done = RunEntry("on_tick", nullptr, nullptr, Config().messageInstructionLimit,
            [&](sol::state& lua) -> std::string
        {
            sol::table tactics = lua["tactics"];
            sol::object handler = tactics["on_tick"];
            if (handler.get_type() != sol::type::function)
                return "";

            defined = true;
            sol::protected_function fn = handler.as<sol::protected_function>();
            sol::protected_function_result result = fn(dtMs);
            if (!result.valid())
            {
                sol::error err = result;
                return err.what();
            }

            return "";
        }, true);

        return done && defined;
    }

    // ================================================================== reload / status
    void BumpVersion()
    {
        ++sVersion;
    }

    uint32 Version()
    {
        return sVersion.load();
    }

    std::string ReloadNow()
    {
        BumpVersion();
        if (tHolder.busy)
            return "";

        if (EnsureState())
            return "";

        std::lock_guard<std::mutex> guard(sLoadErrorLock);
        return sLastLoadError.empty() ? "unknown error" : sLastLoadError;
    }

    Stats GetStats()
    {
        Stats stats;
        stats.liveStates = sLiveStates.load();
        stats.evaluateCalls = sEvaluateCalls.load();
        stats.errors = sErrors.load();
        stats.limitHits = sLimitHits.load();
        std::lock_guard<std::mutex> guard(sLoadErrorLock);
        stats.lastLoadError = sLastLoadError;
        return stats;
    }

    // ================================================================== call context / handles
    CallContext* CurrentCall()
    {
        return tCall;
    }

    Unit* Resolve(ObjectGuid guid)
    {
        CallContext* call = tCall;
        if (!call || !guid || !guid.IsUnit())
            return nullptr;

        // sim entry calls have no anchor: only players (world-thread rule) resolve there
        if (!call->anchor && !(call->sim && !call->map && guid.IsPlayer()))
            return nullptr;

        auto itr = call->cache.find(guid);
        if (itr != call->cache.end())
            return itr->second;

        Unit* unit = nullptr;
        Player* anchor = call->anchor;
        if (call->map)
        {
            // map thread: only units in world on the anchor's map
            if (anchor->IsInWorld())
                unit = ObjectAccessor::GetUnit(*anchor, guid);

            if (unit && (!unit->IsInWorld() || unit->GetMap() != call->map))
                unit = nullptr;
        }
        else if (guid.IsPlayer())
        {
            // world thread: players anywhere
            Player* player = ObjectAccessor::FindConnectedPlayer(guid);
            if (player && player->IsInWorld())
                unit = player;
        }
        else if (anchor && anchor->IsInWorld())
        {
            // world thread: creatures / pets on the anchor's map
            unit = ObjectAccessor::GetUnit(*anchor, guid);
            if (unit && (!unit->IsInWorld() || unit->GetMap() != anchor->GetMap()))
                unit = nullptr;
        }

        call->cache[guid] = unit;
        return unit;
    }

    std::string GuidToHex(ObjectGuid guid)
    {
        return Acore::StringFormat("{:016X}", guid.GetRawValue());
    }

    bool HexToGuid(std::string const& text, ObjectGuid& out)
    {
        if (text.empty() || text.size() > 16)
            return false;

        uint64 value = 0;
        for (char c : text)
        {
            uint64 digit;
            if (c >= '0' && c <= '9')
                digit = uint64(c - '0');
            else if (c >= 'A' && c <= 'F')
                digit = uint64(c - 'A' + 10);
            else if (c >= 'a' && c <= 'f')
                digit = uint64(c - 'a' + 10);
            else
                return false;

            value = (value << 4) | digit;
        }

        out = ObjectGuid(value);
        return true;
    }
}
