/*
 * Bot tactics - Lua bindings (implementer B): the `Unit` usertype (bot methods included) and the
 * global `wow` table of spec section 3.4, plus Tactics::Host (TacticsHost.h).
 *
 * All bindings are read-only facts or thin pass-throughs to Store / Transport / GameData. Handles
 * carry only a GUID and are resolved on every method call (Lua::Resolve), never cached as pointers
 * across calls.
 *
 * Unresolvable handle (or a bot method on a non-bot): string/handle/multi-value methods return nil,
 * bool methods false, number methods 0, array methods an empty table (manaPct/distance: nil).
 */

#include "TacticsEngine.h"
#include "TacticsHost.h"
#include "TacticsLua.h"
#include "TacticsPartyApi.h"
#include "TacticsSim.h"

#include "CellImpl.h"
#include "Creature.h"
#include "GridNotifiers.h"
#include "GridNotifiersImpl.h"
#include "Group.h"
#include "Log.h"
#include "Map.h"
#include "ObjectAccessor.h"
#include "Pet.h"
#include "Player.h"
#include "Playerbots.h"
#include "Spell.h"
#include "SpellAuras.h"
#include "SpellInfo.h"
#include "SpellMgr.h"
#include "Timer.h"
#include "World.h"
#include "WorldSession.h"

#include <sol/sol.hpp>

#include <algorithm>
#include <ctime>

namespace Tactics::Lua
{
    namespace
    {
        constexpr uint32 API_VERSION = 1;
        constexpr size_t MAX_VAR_STRING = 1024;
        constexpr float MAX_SEARCH_RADIUS = 100.0f;

        using sol::lua_nil;

        // ------------------------------------------------------------------ resolution helpers
        Unit* U(UnitHandle const& h) { return Resolve(h.guid); }

        Player* P(UnitHandle const& h)
        {
            Unit* unit = U(h);
            return unit ? unit->ToPlayer() : nullptr;
        }

        Creature* C(UnitHandle const& h)
        {
            Unit* unit = U(h);
            return unit ? unit->ToCreature() : nullptr;
        }

        // Resolves a playerbot handle.
        Player* B(UnitHandle const& h, PlayerbotAI*& ai)
        {
            ai = nullptr;
            Player* bot = P(h);
            if (!bot)
                return nullptr;

            ai = GET_PLAYERBOT_AI(bot);
            return ai ? bot : nullptr;
        }

        // Another unit passed as an argument: a handle, or nil (-> fallback).
        bool UnitArg(sol::object const& arg, Unit* fallback, Unit*& out)
        {
            if (arg.get_type() == sol::type::lua_nil || arg.get_type() == sol::type::none)
            {
                out = fallback;
                return out != nullptr;
            }

            if (!arg.is<UnitHandle>())
                return false;

            out = Resolve(arg.as<UnitHandle>().guid);
            return out != nullptr;
        }

        sol::object Handle(lua_State* L, ObjectGuid guid)
        {
            if (!guid)
                return sol::make_object(L, lua_nil);

            return sol::make_object(L, UnitHandle{ guid });
        }

        LocaleConstant ParseLocale(sol::optional<std::string> const& name)
        {
            if (name && !name->empty())
                return GetLocaleByName(*name);

            return sWorld->GetDefaultDbcLocale();
        }

        template <typename T, size_t N>
        sol::table ArrayOf(sol::state_view& lua, T const (&values)[N])
        {
            sol::table t = lua.create_table(int(N), 0);
            for (size_t i = 0; i < N; ++i)
                t[i + 1] = values[i];
            return t;
        }

        template <typename T>
        sol::table ArrayOf(sol::state_view& lua, std::vector<T> const& values)
        {
            sol::table t = lua.create_table(int(values.size()), 0);
            for (size_t i = 0; i < values.size(); ++i)
                t[i + 1] = values[i];
            return t;
        }

        sol::table HandleArray(sol::state_view& lua, std::vector<ObjectGuid> const& guids)
        {
            sol::table t = lua.create_table(int(guids.size()), 0);
            int n = 0;
            for (ObjectGuid const& guid : guids)
                if (guid)
                    t[++n] = UnitHandle{ guid };
            return t;
        }

        // ------------------------------------------------------------------ logging (raw C functions)
        std::string JoinArgs(lua_State* L)
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
            return message;
        }

        int LuaLog(lua_State* L)
        {
            std::string const message = JoinArgs(L);
            LOG_INFO("module", "[tactics] {}", message);
            return 0;
        }

        int LuaWarn(lua_State* L)
        {
            std::string const message = JoinArgs(L);
            LOG_WARN("module", "[tactics] {}", message);
            return 0;
        }

        int LuaError(lua_State* L)
        {
            std::string const message = JoinArgs(L);
            LOG_ERROR("module", "[tactics] {}", message);
            return 0;
        }

        // ------------------------------------------------------------------ Unit methods
        // Returns the usertype so the party window bindings (TacticsPartyApi.h) can extend it.
        sol::usertype<UnitHandle> RegisterUnit(sol::state_view& lua)
        {
            sol::usertype<UnitHandle> unit = lua.new_usertype<UnitHandle>("Unit", sol::no_constructor);

            unit[sol::meta_function::to_string] = [](UnitHandle const& h) { return GuidToHex(h.guid); };
            unit[sol::meta_function::equal_to] = [](UnitHandle const& a, UnitHandle const& b) { return a.guid == b.guid; };

            unit["guid"] = [](UnitHandle const& h) { return GuidToHex(h.guid); };
            unit["lowGuid"] = [](UnitHandle const& h) { return uint32(h.guid.GetCounter()); };
            unit["valid"] = [](UnitHandle const& h) { return U(h) != nullptr; };

            unit["name"] = [](UnitHandle const& h) -> sol::optional<std::string>
            {
                if (Unit* u = U(h))
                    return u->GetName();
                return sol::nullopt;
            };
            unit["entry"] = [](UnitHandle const& h) -> uint32
            {
                Unit* u = U(h);
                return (u && !u->IsPlayer()) ? u->GetEntry() : 0;
            };
            unit["level"] = [](UnitHandle const& h) -> uint32
            {
                Unit* u = U(h);
                return u ? u->GetLevel() : 0;
            };
            unit["class"] = [](UnitHandle const& h) -> uint32
            {
                Unit* u = U(h);
                return u ? u->getClass() : 0;
            };
            unit["race"] = [](UnitHandle const& h) -> uint32
            {
                Unit* u = U(h);
                return u ? u->getRace() : 0;
            };

            unit["isPlayer"] = [](UnitHandle const& h) { return P(h) != nullptr; };
            unit["isBot"] = [](UnitHandle const& h)
            {
                Player* p = P(h);
                return p && GET_PLAYERBOT_AI(p) != nullptr;
            };
            unit["isRealPlayer"] = [](UnitHandle const& h)
            {
                Player* p = P(h);
                return p && IsRealPlayer(p);
            };
            unit["isPet"] = [](UnitHandle const& h)
            {
                Unit* u = U(h);
                return u && u->IsPet();
            };
            unit["locale"] = [](UnitHandle const& h) -> sol::optional<std::string>
            {
                Player* p = P(h);
                if (!p || !p->GetSession())
                    return sol::nullopt;

                LocaleConstant const locale = p->GetSession()->GetSessionDbcLocale();
                return std::string(localeNames[locale < TOTAL_LOCALES ? locale : LOCALE_enUS]);
            };

            unit["isAlive"] = [](UnitHandle const& h)
            {
                Unit* u = U(h);
                return u && u->IsAlive();
            };
            unit["isDead"] = [](UnitHandle const& h)
            {
                Unit* u = U(h);
                return u && !u->IsAlive();
            };
            unit["inCombat"] = [](UnitHandle const& h)
            {
                Unit* u = U(h);
                return u && u->IsInCombat();
            };
            unit["isMoving"] = [](UnitHandle const& h)
            {
                Unit* u = U(h);
                return u && u->isMoving();
            };

            unit["hp"] = [](UnitHandle const& h) -> double
            {
                Unit* u = U(h);
                return u ? double(u->GetHealth()) : 0.0;
            };
            unit["maxHp"] = [](UnitHandle const& h) -> double
            {
                Unit* u = U(h);
                return u ? double(u->GetMaxHealth()) : 0.0;
            };
            unit["hpPct"] = [](UnitHandle const& h) -> double
            {
                Unit* u = U(h);
                return u ? double(u->GetHealthPct()) : 0.0;
            };

            auto powerOf = [](Unit* u, sol::optional<uint32> const& type) -> Powers
            {
                uint32 const t = type ? *type : uint32(u->getPowerType());
                return t < MAX_POWERS ? Powers(t) : u->getPowerType();
            };
            unit["power"] = [powerOf](UnitHandle const& h, sol::optional<uint32> type) -> double
            {
                Unit* u = U(h);
                return u ? double(u->GetPower(powerOf(u, type))) : 0.0;
            };
            unit["maxPower"] = [powerOf](UnitHandle const& h, sol::optional<uint32> type) -> double
            {
                Unit* u = U(h);
                return u ? double(u->GetMaxPower(powerOf(u, type))) : 0.0;
            };
            unit["powerPct"] = [powerOf](UnitHandle const& h, sol::optional<uint32> type) -> double
            {
                Unit* u = U(h);
                if (!u)
                    return 0.0;

                Powers const power = powerOf(u, type);
                uint32 const max = u->GetMaxPower(power);
                return max ? 100.0 * u->GetPower(power) / max : 0.0;
            };
            unit["powerType"] = [](UnitHandle const& h) -> uint32
            {
                Unit* u = U(h);
                return u ? uint32(u->getPowerType()) : 0;
            };
            unit["manaPct"] = [](UnitHandle const& h) -> sol::optional<double>
            {
                Unit* u = U(h);
                if (!u || !u->GetMaxPower(POWER_MANA))
                    return sol::nullopt;

                return 100.0 * u->GetPower(POWER_MANA) / u->GetMaxPower(POWER_MANA);
            };

            unit["isTank"] = [](UnitHandle const& h)
            {
                Player* p = P(h);
                return p && PlayerbotAI::IsTank(p);
            };
            unit["isHealer"] = [](UnitHandle const& h)
            {
                Player* p = P(h);
                return p && PlayerbotAI::IsHeal(p);
            };
            unit["isMainTank"] = [](UnitHandle const& h)
            {
                Player* p = P(h);
                return p && PlayerbotAI::IsMainTank(p);
            };
            unit["isRanged"] = [](UnitHandle const& h)
            {
                Player* p = P(h);
                return p && PlayerbotAI::IsRanged(p);
            };
            unit["isMelee"] = [](UnitHandle const& h)
            {
                Player* p = P(h);
                return p && PlayerbotAI::IsMelee(p);
            };

            unit["isElite"] = [](UnitHandle const& h)
            {
                Creature* c = C(h);
                return c && c->isElite();
            };
            unit["isBoss"] = [](UnitHandle const& h)
            {
                Creature* c = C(h);
                return c && !c->IsPet() &&
                       (c->GetCreatureTemplate()->rank == CREATURE_ELITE_WORLDBOSS || c->IsDungeonBoss());
            };
            unit["rank"] = [](UnitHandle const& h) -> uint32
            {
                Creature* c = C(h);
                return c ? c->GetCreatureTemplate()->rank : 0;
            };
            // CreatureType (1 beast, 2 dragonkin, 3 demon, 4 elemental, 5 giant, 6 undead, 7 humanoid,
            // 8 critter, 9 mechanical, 10 not specified); players are humanoid. Same as the client's UnitCreatureType.
            unit["creatureType"] = [](UnitHandle const& h) -> uint32
            {
                Unit* u = U(h);
                return u ? u->GetCreatureType() : 0;
            };

            unit["isFriendlyTo"] = [](UnitHandle const& h, sol::object other)
            {
                Unit* u = U(h);
                Unit* o = nullptr;
                return u && UnitArg(other, nullptr, o) && u->IsFriendlyTo(o);
            };
            unit["isHostileTo"] = [](UnitHandle const& h, sol::object other)
            {
                Unit* u = U(h);
                Unit* o = nullptr;
                return u && UnitArg(other, nullptr, o) && u->IsHostileTo(o);
            };

            unit["victim"] = [](UnitHandle const& h, sol::this_state s) -> sol::object
            {
                Unit* u = U(h);
                Unit* victim = u ? u->GetVictim() : nullptr;
                return Handle(s, victim ? victim->GetGUID() : ObjectGuid::Empty);
            };
            unit["selection"] = [](UnitHandle const& h, sol::this_state s) -> sol::object
            {
                Unit* u = U(h);
                return Handle(s, u ? u->GetTarget() : ObjectGuid::Empty);
            };

            unit["position"] = [](UnitHandle const& h, sol::this_state s)
            {
                sol::variadic_results results;
                Unit* u = U(h);
                if (!u)
                {
                    results.push_back(sol::make_object(s, lua_nil));
                    return results;
                }

                results.push_back(sol::make_object(s, u->GetPositionX()));
                results.push_back(sol::make_object(s, u->GetPositionY()));
                results.push_back(sol::make_object(s, u->GetPositionZ()));
                results.push_back(sol::make_object(s, u->GetOrientation()));
                return results;
            };
            unit["mapId"] = [](UnitHandle const& h) -> uint32
            {
                Unit* u = U(h);
                return u ? u->GetMapId() : 0;
            };
            // Player in a near/far teleport. A far teleport takes the player out of the world (the handle
            // stops resolving); world-thread calls still see it as teleporting then.
            unit["teleporting"] = [](UnitHandle const& h)
            {
                if (Player* p = P(h))
                    return p->IsBeingTeleported();

                CallContext* call = CurrentCall();
                if (!call || call->map || !h.guid.IsPlayer())
                    return false;

                Player* p = ObjectAccessor::FindConnectedPlayer(h.guid);
                return p && (p->IsBeingTeleported() || !p->IsInWorld());
            };
            unit["distance"] = [](UnitHandle const& h, sol::object other) -> sol::optional<double>
            {
                Unit* u = U(h);
                Unit* o = nullptr;
                if (!u || !UnitArg(other, nullptr, o) || u->GetMap() != o->GetMap())
                    return sol::nullopt;

                return double(u->GetDistance(o));
            };
            unit["inLos"] = [](UnitHandle const& h, sol::object other)
            {
                Unit* u = U(h);
                Unit* o = nullptr;
                return u && UnitArg(other, nullptr, o) && u->GetMap() == o->GetMap() && u->IsWithinLOSInMap(o);
            };

            unit["hasAura"] = [](UnitHandle const& h, uint32 spellId, sol::optional<bool> anyRank,
                                 sol::optional<std::string> casterHex)
            {
                Unit* u = U(h);
                if (!u || !spellId)
                    return false;

                ObjectGuid caster;
                if (casterHex && !HexToGuid(*casterHex, caster))
                    return false;

                if (anyRank && !*anyRank)
                    return u->HasAura(spellId, caster);

                uint32 const first = sSpellMgr->GetFirstSpellInChain(spellId);
                for (auto const& [auraId, app] : u->GetAppliedAuras())
                {
                    if (sSpellMgr->GetFirstSpellInChain(auraId) != first)
                        continue;

                    if (caster && app->GetBase()->GetCasterGUID() != caster)
                        continue;

                    return true;
                }

                return false;
            };
            unit["auras"] = [](UnitHandle const& h, sol::this_state s)
            {
                sol::state_view lua(s);
                sol::table list = lua.create_table();
                Unit* u = U(h);
                if (!u)
                    return list;

                int n = 0;
                for (auto const& [auraId, app] : u->GetAppliedAuras())
                {
                    Aura const* aura = app->GetBase();
                    sol::table entry = lua.create_table(0, 6);
                    entry["spell"] = auraId;
                    entry["stacks"] = uint32(aura->GetStackAmount());
                    entry["remaining"] = aura->GetDuration();
                    entry["positive"] = app->IsPositive();
                    entry["dispel"] = aura->GetSpellInfo()->Dispel;
                    entry["caster"] = GuidToHex(aura->GetCasterGUID());
                    list[++n] = entry;
                }

                return list;
            };
            // id, interruptible, remaining ms, unit target of the cast as GUID hex ("" when none; ai-layer-spec 10)
            unit["casting"] = [](UnitHandle const& h) -> std::tuple<uint32, bool, int32, std::string>
            {
                Unit* u = U(h);
                if (!u)
                    return { 0, false, 0, std::string() };

                bool channeled = false;
                Spell* spell = u->GetCurrentSpell(CURRENT_GENERIC_SPELL);
                if (!spell)
                {
                    spell = u->GetCurrentSpell(CURRENT_CHANNELED_SPELL);
                    channeled = true;
                }

                if (!spell || !spell->GetSpellInfo())
                    return { 0, false, 0, std::string() };

                SpellInfo const* info = spell->GetSpellInfo();
                bool interruptible = channeled ? info->ChannelInterruptFlags != 0
                                               : (info->InterruptFlags & SPELL_INTERRUPT_FLAG_INTERRUPT) != 0;
                if (u->HasAuraTypeWithMiscvalue(SPELL_AURA_MECHANIC_IMMUNITY, MECHANIC_INTERRUPT))
                    interruptible = false;

                if (Creature* c = u->ToCreature())
                    if (c->HasMechanicTemplateImmunity(1ULL << MECHANIC_INTERRUPT))
                        interruptible = false;

                ObjectGuid target = spell->m_targets.GetUnitTargetGUID();
                return { info->Id, interruptible, std::max<int32>(0, spell->GetCastTimeRemaining()),
                         target.IsEmpty() ? std::string() : GuidToHex(target) };
            };

            unit["group"] = [](UnitHandle const& h, sol::this_state s)
            {
                sol::state_view lua(s);
                sol::table list = lua.create_table();
                Player* p = P(h);
                if (!p)
                    return list;

                Group* group = p->GetGroup();
                if (!group)
                {
                    list[1] = UnitHandle{ p->GetGUID() };
                    return list;
                }

                int n = 0;
                for (GroupReference* ref = group->GetFirstMember(); ref; ref = ref->next())
                {
                    Player* member = ref->GetSource();
                    if (member && Resolve(member->GetGUID()))
                        list[++n] = UnitHandle{ member->GetGUID() };
                }

                return list;
            };

            // ------------------------------------------------------------------ Bot methods
            unit["owner"] = [](UnitHandle const& h, sol::this_state s) -> sol::object
            {
                PlayerbotAI* ai = nullptr;
                Player* bot = B(h, ai);
                Player* owner = bot ? GetOwner(bot) : nullptr;
                return Handle(s, owner ? owner->GetGUID() : ObjectGuid::Empty);
            };
            unit["ownerLow"] = [](UnitHandle const& h) -> uint32
            {
                PlayerbotAI* ai = nullptr;
                Player* bot = B(h, ai);
                Player* owner = bot ? GetOwner(bot) : nullptr;
                return owner ? uint32(owner->GetGUID().GetCounter()) : 0;
            };
            unit["leader"] = [](UnitHandle const& h, sol::this_state s) -> sol::object
            {
                Player* p = P(h);
                Group* group = p ? p->GetGroup() : nullptr;
                return Handle(s, group ? group->GetLeaderGUID() : ObjectGuid::Empty);
            };
            unit["state"] = [](UnitHandle const& h) -> sol::optional<std::string>
            {
                PlayerbotAI* ai = nullptr;
                if (!B(h, ai))
                    return sol::nullopt;

                switch (ai->GetState())
                {
                    case BOT_STATE_COMBAT:
                        return std::string("combat");
                    case BOT_STATE_NON_COMBAT:
                        return std::string("noncombat");
                    default:
                        return std::string("dead");
                }
            };
            unit["currentTarget"] = [](UnitHandle const& h, sol::this_state s) -> sol::object
            {
                PlayerbotAI* ai = nullptr;
                if (!B(h, ai))
                    return sol::make_object(s, lua_nil);

                Unit* target = ai->GetAiObjectContext()->GetValue<Unit*>("current target")->Get();
                return Handle(s, target ? target->GetGUID() : ObjectGuid::Empty);
            };
            unit["attackers"] = [](UnitHandle const& h, sol::this_state s)
            {
                sol::state_view lua(s);
                PlayerbotAI* ai = nullptr;
                if (!B(h, ai))
                    return lua.create_table();

                GuidVector const attackers = ai->GetAiObjectContext()->GetValue<GuidVector>("attackers")->Get();
                return HandleArray(lua, attackers);
            };
            unit["hostilesNear"] = [](UnitHandle const& h, float radius, sol::this_state s)
            {
                sol::state_view lua(s);
                PlayerbotAI* ai = nullptr;
                Player* bot = B(h, ai);
                if (!bot || !(radius > 0.0f))
                    return lua.create_table();

                radius = std::min(radius, MAX_SEARCH_RADIUS);
                std::list<Unit*> found;
                Acore::AnyUnfriendlyUnitInObjectRangeCheck check(bot, bot, radius);
                Acore::UnitListSearcher<Acore::AnyUnfriendlyUnitInObjectRangeCheck> searcher(bot, found, check);
                Cell::VisitObjects(bot, searcher, radius);

                std::vector<ObjectGuid> guids;
                for (Unit* unit : found)
                    if (unit->IsAlive() && bot->IsValidAttackTarget(unit))
                        guids.push_back(unit->GetGUID());

                return HandleArray(lua, guids);
            };
            unit["mark"] = [](UnitHandle const& h, uint32 index, sol::this_state s) -> sol::object
            {
                Player* p = P(h);
                Group* group = p ? p->GetGroup() : nullptr;
                if (!group || index >= TARGETICONCOUNT)
                    return sol::make_object(s, lua_nil);

                return Handle(s, group->GetTargetIcon(uint8(index)));
            };
            unit["knows"] = [](UnitHandle const& h, uint32 spellId)
            {
                PlayerbotAI* ai = nullptr;
                Player* bot = B(h, ai);
                return bot && spellId && bot->HasSpell(spellId);
            };
            unit["highestRank"] = [](UnitHandle const& h, uint32 spellId) -> uint32
            {
                PlayerbotAI* ai = nullptr;
                Player* bot = B(h, ai);
                if (!bot || !spellId || !sSpellMgr->GetSpellInfo(spellId))
                    return 0;

                uint32 best = 0;
                uint32 rank = sSpellMgr->GetFirstSpellInChain(spellId);
                for (uint32 guard = 0; rank && guard < 64; ++guard)
                {
                    if (bot->HasSpell(rank))
                        best = rank;
                    rank = sSpellMgr->GetNextSpellInChain(rank);
                }

                return best;
            };
            unit["canCast"] = [](UnitHandle const& h, uint32 spellId, sol::object target) -> std::tuple<bool, std::string>
            {
                PlayerbotAI* ai = nullptr;
                Player* bot = B(h, ai);
                if (!bot)
                    return { false, "invalid_bot" };

                Unit* unit = nullptr;
                if (!UnitArg(target, bot, unit))
                    return { false, "invalid_target" };

                CastCheck const check = CheckSpellCast(bot, ai, sSpellMgr->GetSpellInfo(spellId), unit, true);
                std::string const reason = check.reason;
                return { reason == "ok" || reason == "range" || reason == "moving", reason };
            };
            unit["spellRange"] = [](UnitHandle const& h, uint32 spellId, sol::this_state s)
            {
                sol::variadic_results results;
                PlayerbotAI* ai = nullptr;
                Player* bot = B(h, ai);
                SpellInfo const* info = sSpellMgr->GetSpellInfo(spellId);
                if (!bot || !info)
                {
                    results.push_back(sol::make_object(s, lua_nil));
                    return results;
                }

                results.push_back(sol::make_object(s, info->GetMinRange(false)));
                results.push_back(sol::make_object(s, info->GetMaxRange(false, bot)));
                results.push_back(sol::make_object(s, info->GetMaxRange(true, bot)));
                return results;
            };
            unit["cooldown"] = [](UnitHandle const& h, uint32 spellId) -> uint32
            {
                PlayerbotAI* ai = nullptr;
                Player* bot = B(h, ai);
                return bot ? bot->GetSpellCooldownDelay(spellId) : 0;
            };
            unit["spells"] = [](UnitHandle const& h, sol::this_state s)
            {
                sol::state_view lua(s);
                PlayerbotAI* ai = nullptr;
                Player* bot = B(h, ai);
                if (!bot)
                    return lua.create_table();

                return ArrayOf(lua, GameData::GetKnownSpells(bot));
            };
            unit["items"] = [](UnitHandle const& h, sol::this_state s)
            {
                sol::state_view lua(s);
                sol::table list = lua.create_table();
                PlayerbotAI* ai = nullptr;
                Player* bot = B(h, ai);
                if (!bot)
                    return list;

                int n = 0;
                for (BagItemRaw const& item : GameData::GetBagItems(bot))
                {
                    sol::table entry = lua.create_table(0, 2);
                    entry["entry"] = item.entry;
                    entry["count"] = item.count;
                    list[++n] = entry;
                }

                return list;
            };
            unit["itemCount"] = [](UnitHandle const& h, uint32 entry) -> uint32
            {
                PlayerbotAI* ai = nullptr;
                Player* bot = B(h, ai);
                return bot ? bot->GetItemCount(entry, false) : 0;
            };
            unit["canUse"] = [](UnitHandle const& h, uint32 entry, sol::object target) -> std::tuple<bool, std::string>
            {
                PlayerbotAI* ai = nullptr;
                Player* bot = B(h, ai);
                if (!bot)
                    return { false, "invalid_bot" };

                Unit* unit = nullptr;
                if (!UnitArg(target, bot, unit))
                    return { false, "invalid_target" };

                std::string const reason = CheckItemUse(bot, ai, entry, unit);
                return { reason == "ok" || reason == "range", reason };
            };
            unit["inInstance"] = [](UnitHandle const& h)
            {
                PlayerbotAI* ai = nullptr;
                Player* bot = B(h, ai);
                return bot && bot->GetMap() && bot->GetMap()->IsDungeon();
            };

            // ------------------------------------------------------------------ abilities-mirroring-spec 2.2
            // bool: u is the victim of this unit's melee auto-attack
            unit["isAttacking"] = [](UnitHandle const& h, sol::object other)
            {
                Unit* u = U(h);
                Unit* o = nullptr;
                return u && UnitArg(other, nullptr, o) && u->GetVictim() == o && u->HasUnitState(UNIT_STATE_MELEE_ATTACKING);
            };
            // bool: u is within this unit's melee reach (Unit::IsWithinMeleeRange)
            unit["inMeleeRange"] = [](UnitHandle const& h, sol::object other)
            {
                Unit* u = U(h);
                Unit* o = nullptr;
                return u && UnitArg(other, nullptr, o) && u->GetMap() == o->GetMap() && u->IsWithinMeleeRange(o);
            };
            // spell id of the running auto-repeat spell (Auto Shot / Shoot / Throw; 0 = none), target GUID text or nil
            unit["autoRepeat"] = [](UnitHandle const& h, sol::this_state s)
            {
                sol::variadic_results results;
                Unit* u = U(h);
                Spell* spell = u ? u->GetCurrentSpell(CURRENT_AUTOREPEAT_SPELL) : nullptr;
                if (!spell || !spell->GetSpellInfo())
                {
                    results.push_back(sol::make_object(s, uint32(0)));
                    results.push_back(sol::make_object(s, lua_nil));
                    return results;
                }

                ObjectGuid const target = spell->m_targets.GetUnitTargetGUID();
                results.push_back(sol::make_object(s, spell->GetSpellInfo()->Id));
                results.push_back(target ? sol::make_object(s, GuidToHex(target)) : sol::make_object(s, lua_nil));
                return results;
            };
            // handle of the bot's pet (Player::GetPet: hunter / warlock / DK ghoul / ...) or nil
            unit["pet"] = [](UnitHandle const& h, sol::this_state s) -> sol::object
            {
                PlayerbotAI* ai = nullptr;
                Player* bot = B(h, ai);
                Pet* pet = bot ? bot->GetPet() : nullptr;
                return Handle(s, pet && pet->IsInWorld() ? pet->GetGUID() : ObjectGuid::Empty);
            };
            // array of { id, active, autocast } of the pet's castable spells (Pet::m_spells without passives and
            // PETSPELL_REMOVED), ascending id; active = castable action bar state, autocast = ACT_ENABLED. {} without a pet.
            unit["petSpells"] = [](UnitHandle const& h, sol::this_state s)
            {
                sol::state_view lua(s);
                sol::table list = lua.create_table();
                PlayerbotAI* ai = nullptr;
                Player* bot = B(h, ai);
                Pet* pet = bot ? bot->GetPet() : nullptr;
                if (!pet || !pet->IsInWorld())
                    return list;

                std::vector<std::pair<uint32, PetSpell>> spells;
                for (auto const& [id, spell] : pet->m_spells)
                {
                    if (spell.state == PETSPELL_REMOVED || spell.active == ACT_PASSIVE)
                        continue;

                    SpellInfo const* info = sSpellMgr->GetSpellInfo(id);
                    if (!info || info->IsPassive())
                        continue;

                    spells.emplace_back(id, spell);
                }

                std::sort(spells.begin(), spells.end(), [](auto const& a, auto const& b) { return a.first < b.first; });

                int n = 0;
                for (auto const& [id, spell] : spells)
                {
                    sol::table entry = lua.create_table(0, 3);
                    entry["id"] = id;
                    entry["active"] = spell.active == ACT_ENABLED || spell.active == ACT_DISABLED;
                    entry["autocast"] = spell.active == ACT_ENABLED;
                    list[++n] = entry;
                }

                return list;
            };

            return unit;
        }

        // ------------------------------------------------------------------ wow table
        void RegisterWow(sol::state_view& lua)
        {
            sol::table wow = lua.create_named_table("wow");

            wow["log"] = &LuaLog;
            wow["warn"] = &LuaWarn;
            wow["error"] = &LuaError;

            wow["now"] = []() { return getMSTime(); };
            wow["time"] = []() { return double(std::time(nullptr)); };
            wow["version"] = []() { return Version(); };
            wow["api"] = []() { return API_VERSION; };

            wow["bot"] = [](uint32 low, sol::this_state s) -> sol::object
            {
                ObjectGuid const guid = ObjectGuid::Create<HighGuid::Player>(low);
                Unit* unit = Resolve(guid);
                Player* player = unit ? unit->ToPlayer() : nullptr;
                if (!player || !GET_PLAYERBOT_AI(player))
                    return sol::make_object(s, lua_nil);

                return Handle(s, guid);
            };
            wow["player"] = [](uint32 low, sol::this_state s) -> sol::object
            {
                ObjectGuid const guid = ObjectGuid::Create<HighGuid::Player>(low);
                Unit* unit = Resolve(guid);
                if (!unit || !unit->IsPlayer())
                    return sol::make_object(s, lua_nil);

                return Handle(s, guid);
            };
            wow["unit"] = [](std::string const& hex, sol::this_state s) -> sol::object
            {
                ObjectGuid guid;
                if (!HexToGuid(hex, guid))
                    return sol::make_object(s, lua_nil);

                return Handle(s, guid);
            };

            wow["spell"] = [](uint32 id, sol::optional<std::string> locale, sol::this_state s) -> sol::object
            {
                SpellRaw raw;
                if (!GameData::GetSpell(id, ParseLocale(locale), raw))
                    return sol::make_object(s, lua_nil);

                sol::state_view lua(s);
                sol::table t = lua.create_table(0, 40);
                t["id"] = raw.id;
                t["name"] = raw.name;
                t["rank"] = raw.rank;
                t["attr"] = ArrayOf(lua, raw.attributes);
                t["effects"] = ArrayOf(lua, raw.effects);
                t["auras"] = ArrayOf(lua, raw.auras);
                t["targetA"] = ArrayOf(lua, raw.implicitTargetA);
                t["misc"] = ArrayOf(lua, raw.effectMisc);
                t["baseLevel"] = raw.baseLevel;
                t["spellLevel"] = raw.spellLevel;
                t["maxLevel"] = raw.maxLevel;
                t["powerType"] = raw.powerType;
                t["cost"] = raw.manaCost;
                t["costPct"] = raw.manaCostPct;
                t["minRange"] = raw.minRange;
                t["maxRange"] = raw.maxRange;
                t["maxRangeFriend"] = raw.maxRangeFriend;
                t["castTime"] = raw.castTimeMs;
                t["recovery"] = raw.recoveryMs;
                t["categoryRecovery"] = raw.categoryRecoveryMs;
                t["duration"] = raw.durationMs;
                t["dispel"] = raw.dispel;
                t["mechanic"] = raw.mechanic;
                t["school"] = raw.schoolMask;
                t["icon"] = raw.iconId;
                t["family"] = raw.family;
                t["passive"] = raw.passive;
                t["positive"] = raw.positive;
                t["talent"] = raw.talent;
                t["channeled"] = raw.channeled;
                t["autoRepeat"] = raw.autoRepeat;
                t["first"] = raw.firstRank;
                t["last"] = raw.lastRank;
                t["prev"] = raw.prevRank;
                t["next"] = raw.nextRank;
                t["rankIndex"] = uint32(raw.rankIndex);
                t["skills"] = ArrayOf(lua, raw.skillLines);
                return t;
            };

            wow["skillLine"] = [](uint32 id, sol::optional<std::string> locale, sol::this_state s) -> sol::object
            {
                SkillLineRaw raw;
                if (!GameData::GetSkillLine(id, ParseLocale(locale), raw))
                    return sol::make_object(s, lua_nil);

                sol::state_view lua(s);
                sol::table t = lua.create_table(0, 4);
                t["id"] = raw.id;
                t["category"] = raw.category;
                t["name"] = raw.name;
                t["icon"] = raw.spellIcon;
                return t;
            };

            wow["skillAbilities"] = [](uint32 skillId, sol::this_state s)
            {
                sol::state_view lua(s);
                std::vector<SkillAbilityRaw> const rows = GameData::GetSkillAbilities(skillId);
                sol::table list = lua.create_table(int(rows.size()), 0);
                int n = 0;
                for (SkillAbilityRaw const& row : rows)
                {
                    sol::table t = lua.create_table(0, 7);
                    t["spell"] = row.spell;
                    t["skill"] = row.skillLine;
                    t["raceMask"] = row.raceMask;
                    t["classMask"] = row.classMask;
                    t["minSkill"] = row.minSkillRank;
                    t["supercededBy"] = row.supercededBySpell;
                    t["acquireMethod"] = row.acquireMethod;
                    list[++n] = t;
                }

                return list;
            };

            wow["item"] = [](uint32 entry, sol::optional<std::string> locale, sol::this_state s) -> sol::object
            {
                ItemRaw raw;
                if (!GameData::GetItem(entry, ParseLocale(locale), raw))
                    return sol::make_object(s, lua_nil);

                sol::state_view lua(s);
                sol::table t = lua.create_table(0, 9);
                t["entry"] = raw.entry;
                t["name"] = raw.name;
                t["class"] = raw.itemClass;
                t["subclass"] = raw.itemSubClass;
                t["quality"] = raw.quality;
                t["itemLevel"] = raw.itemLevel;
                t["reqLevel"] = raw.requiredLevel;
                t["maxStack"] = raw.maxStack;
                t["useSpells"] = ArrayOf(lua, raw.useSpells);
                return t;
            };

            wow["storeRev"] = [](uint32 low) { return Store::Revision(low); };
            wow["storeGet"] = [](uint32 low, std::string const& name) -> sol::optional<std::string>
            {
                std::optional<std::string> value = Store::Get(low, name);
                if (!value)
                    return sol::nullopt;
                return *value;
            };
            wow["storeAll"] = [](uint32 low, sol::this_state s)
            {
                sol::state_view lua(s);
                sol::table t = lua.create_table();
                for (auto const& [name, data] : Store::GetAll(low))
                    t[name] = data;
                return t;
            };
            wow["storeSet"] = [](uint32 low, std::string const& name, std::string const& data)
            {
                return Store::Set(low, name, data);
            };
            wow["storeErase"] = [](uint32 low, std::string const& name) { return Store::Erase(low, name); };

            wow["send"] = [](uint32 playerLow, std::string const& payload)
            {
                return playerLow && Transport::Send(ObjectGuid::Create<HighGuid::Player>(playerLow), payload);
            };

            wow["getVar"] = [](uint32 low, std::string const& key, sol::this_state s) -> sol::object
            {
                std::optional<Vars::Value> value = Vars::Get(low, key);
                if (!value)
                    return sol::make_object(s, lua_nil);

                switch (value->kind)
                {
                    case Vars::Value::Kind::Bool:
                        return sol::make_object(s, value->b);
                    case Vars::Value::Kind::Number:
                        return sol::make_object(s, value->n);
                    default:
                        return sol::make_object(s, value->s);
                }
            };
            wow["setVar"] = [](uint32 low, std::string const& key, sol::object value)
            {
                Vars::Value var;
                switch (value.get_type())
                {
                    case sol::type::lua_nil:
                    case sol::type::none:
                        Vars::Set(low, key, std::nullopt);
                        return;
                    case sol::type::boolean:
                        var.kind = Vars::Value::Kind::Bool;
                        var.b = value.as<bool>();
                        break;
                    case sol::type::number:
                        var.kind = Vars::Value::Kind::Number;
                        var.n = value.as<double>();
                        break;
                    case sol::type::string:
                        var.kind = Vars::Value::Kind::String;
                        var.s = value.as<std::string>();
                        if (var.s.size() > MAX_VAR_STRING)
                            throw std::runtime_error("wow.setVar: string value longer than 1024 bytes");
                        break;
                    default:
                        throw std::runtime_error("wow.setVar: value must be nil, boolean, number or string");
                }

                Vars::Set(low, key, std::move(var));
            };
        }
    }

    sol::object MakeHandle(lua_State* L, ObjectGuid guid)
    {
        return Handle(L, guid);
    }

    Player* ResolvePlayerbot(UnitHandle const& h, PlayerbotAI*& ai)
    {
        return B(h, ai);
    }

    Player* MessagePlayer()
    {
        CallContext* call = CurrentCall();
        return call && !call->map ? call->anchor : nullptr;
    }

    void RegisterApi(lua_State* L)
    {
        sol::state_view lua(L);
        sol::usertype<UnitHandle> unit = RegisterUnit(lua);
        RegisterWow(lua);

        // Party window bindings: P1 inventory, P2 bots / talents / AI.
        sol::table wow = lua["wow"];
        RegisterPartyApi(lua, unit, wow);
        RegisterAiApi(lua, unit, wow);
        RegisterExtrasApi(lua, unit, wow);
        RegisterMirrorApi(lua, unit, wow);     // TacticsMirrorApi.cpp (abilities-mirroring-spec 5.3)

        // Headless bot simulation: wow.sim, wow.metrics.
        RegisterSimApi(lua, wow);
        RegisterMetricsApi(lua, wow);
    }
}

namespace Tactics::Host
{
    void OnClientMessage(Player* player, std::string const& payload)
    {
        Lua::OnMessage(player, payload);
    }

    void OnPlayerEvent(char const* event, Player* player)
    {
        Lua::OnEvent(event, player);
    }

    void RequestReload()
    {
        Lua::BumpVersion();
    }

    uint32 ScriptVersion()
    {
        return Lua::Version();
    }
}
