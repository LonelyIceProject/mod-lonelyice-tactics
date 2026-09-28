/*
 * Bot tactics - headless simulation metrics.
 *
 * Plumbing only: core hooks -> per-GUID counters for watched GUIDs, and the `wow.metrics` bindings.
 * Aggregation, derived values (overheal = heal_raw - heal_eff) and the CSV are Lua (sim/report.lua).
 *
 * Counter keys written here:
 *   dmg_done, dmg_done_pet, dmg_taken      Unit::DealDamage (after absorb); pet/totem damage also counts for the owner
 *   heal_raw, heal_eff, heal_taken         heal before absorb/overheal (per healer), effective heal (healer / receiver)
 *   deaths, kills                          player deaths (Player::KillPlayer), creature deaths / kills (Unit::Kill)
 *   combat_enter_at, combat_ms             getMSTime() of the first combat entry since reset, time in combat
 *   casts, cast.<spellId>, casts_tactics   non-triggered Spell::prepare of the caster; tactics = inside TacticsCastScope
 *   casts_done                             non-triggered Spell::cast (casts - casts_done = interrupted / failed)
 *   mana_spent, power_spent.<type>         Spell::cast power cost (after TakePower)
 * The engine adds guard_g1 / guard_g2 (TacticsEngine.cpp), Lua adds rule.* / oom_ms.
 */

#include "TacticsMetrics.h"
#include "TacticsSim.h"

#include "Player.h"
#include "ScriptMgr.h"
#include "Spell.h"
#include "SpellInfo.h"
#include "Timer.h"
#include "Unit.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <mutex>
#include <unordered_map>

namespace Tactics::Metrics
{
    namespace
    {
        struct Entry
        {
            bool watched = false;
            uint32 combatSince = 0;       // getMSTime() of the current combat entry, 0 = not in combat
            std::map<std::string, double> values;
        };

        std::atomic<uint32> sWatchedCount{ 0 };
        std::mutex sLock;
        std::unordered_map<ObjectGuid, Entry> sData;

        thread_local uint32 tTacticsCast = 0;

        // ModifyHealReceived is called with (caster, target) on the HealBySpell path and (target, caster) for
        // periodic heals; the raw amount is kept here and credited by the following OnHeal (DealHeal),
        // whose argument order is always (healer, receiver).
        struct PendingHeal
        {
            Unit const* a = nullptr;
            Unit const* b = nullptr;
            uint32 amount = 0;
        };

        thread_local PendingHeal tPendingHeal;

        // Caller holds sLock.
        Entry* WatchedEntry(ObjectGuid guid)
        {
            if (!guid)
                return nullptr;

            auto itr = sData.find(guid);
            return (itr != sData.end() && itr->second.watched) ? &itr->second : nullptr;
        }

        Entry* WatchedEntry(Unit const* unit)
        {
            return unit ? WatchedEntry(KeyOf(unit)) : nullptr;
        }

        // Caller holds sLock. The unit itself, or else its controlling player (pets, totems, guardians).
        Entry* WatchedSource(Unit* unit, bool* viaOwner = nullptr)
        {
            if (viaOwner)
                *viaOwner = false;

            if (!unit)
                return nullptr;

            if (Entry* entry = WatchedEntry(unit))
                return entry;

            if (unit->IsPlayer())
                return nullptr;

            Player* owner = unit->GetCharmerOrOwnerPlayerOrPlayerItself();
            Entry* entry = owner ? WatchedEntry(owner) : nullptr;
            if (entry && viaOwner)
                *viaOwner = true;

            return entry;
        }
    }

    bool Active()
    {
        return sWatchedCount.load(std::memory_order_relaxed) != 0;
    }

    ObjectGuid KeyOf(ObjectGuid guid, uint32 instanceId)
    {
        if (!guid || guid.IsPlayer())
            return guid;

        // entry bits 24..47 replaced by the instance id: low guids repeat across instances of one map
        uint64 const raw = guid.GetRawValue();
        return ObjectGuid((raw & ~(uint64(0xFFFFFF) << 24)) | (uint64(instanceId & 0xFFFFFF) << 24));
    }

    ObjectGuid KeyOf(WorldObject const* object)
    {
        return object ? KeyOf(object->GetGUID(), object->GetInstanceId()) : ObjectGuid::Empty;
    }

    bool Watched(ObjectGuid guid)
    {
        if (!Active())
            return false;

        std::lock_guard<std::mutex> guard(sLock);
        return WatchedEntry(guid) != nullptr;
    }

    void Watch(ObjectGuid guid, bool on)
    {
        if (!guid)
            return;

        std::lock_guard<std::mutex> guard(sLock);
        if (on)
        {
            Entry& entry = sData[guid];
            if (!entry.watched)
            {
                entry.watched = true;
                ++sWatchedCount;
            }

            return;
        }

        auto itr = sData.find(guid);
        if (itr == sData.end() || !itr->second.watched)
            return;

        itr->second.watched = false;
        itr->second.combatSince = 0;
        --sWatchedCount;
    }

    void Add(ObjectGuid guid, std::string const& key, double value)
    {
        if (!Active())
            return;

        std::lock_guard<std::mutex> guard(sLock);
        if (Entry* entry = WatchedEntry(guid))
            entry->values[key] += value;
    }

    std::map<std::string, double> Get(ObjectGuid guid)
    {
        std::lock_guard<std::mutex> guard(sLock);
        auto itr = sData.find(guid);
        if (itr == sData.end())
            return {};

        std::map<std::string, double> values = itr->second.values;
        if (itr->second.combatSince)
            values["combat_ms"] += double(getMSTimeDiff(itr->second.combatSince, getMSTime()));

        return values;
    }

    void Reset(ObjectGuid guid)
    {
        std::lock_guard<std::mutex> guard(sLock);
        auto itr = sData.find(guid);
        if (itr == sData.end())
            return;

        itr->second.values.clear();
        itr->second.combatSince = 0;
        if (!itr->second.watched)
            sData.erase(itr);
    }

    void Clear()
    {
        std::lock_guard<std::mutex> guard(sLock);
        sData.clear();
        sWatchedCount = 0;
    }

    TacticsCastScope::TacticsCastScope()
    {
        ++tTacticsCast;
    }

    TacticsCastScope::~TacticsCastScope()
    {
        --tTacticsCast;
    }

    // ================================================================== core hooks
    namespace
    {
        class TacticsMetricsUnitScript : public UnitScript
        {
        public:
            TacticsMetricsUnitScript() : UnitScript("TacticsMetricsUnitScript", true,
                { UNITHOOK_ON_DAMAGE, UNITHOOK_ON_HEAL, UNITHOOK_MODIFY_HEAL_RECEIVED, UNITHOOK_ON_UNIT_DEATH }) { }

            void OnDamage(Unit* attacker, Unit* victim, uint32& damage) override
            {
                if (!Active() || !damage)
                    return;

                std::lock_guard<std::mutex> guard(sLock);
                bool viaOwner = false;
                if (Entry* entry = WatchedSource(attacker, &viaOwner))
                {
                    entry->values["dmg_done"] += damage;
                    if (viaOwner)
                        entry->values["dmg_done_pet"] += damage;
                }

                if (Entry* entry = victim ? WatchedEntry(victim) : nullptr)
                    entry->values["dmg_taken"] += damage;
            }

            void ModifyHealReceived(Unit* target, Unit* healer, uint32& heal, SpellInfo const* /*spellInfo*/) override
            {
                if (!Active())
                    return;

                tPendingHeal.a = target;
                tPendingHeal.b = healer;
                tPendingHeal.amount = heal;
            }

            void OnHeal(Unit* healer, Unit* receiver, uint32& gain) override
            {
                if (!Active())
                {
                    if (tPendingHeal.a)
                        tPendingHeal = PendingHeal();
                    return;
                }

                uint32 raw = gain;
                PendingHeal const pending = tPendingHeal;
                tPendingHeal = PendingHeal();
                if ((pending.a == healer && pending.b == receiver) || (pending.a == receiver && pending.b == healer))
                    raw = std::max(raw, pending.amount);

                std::lock_guard<std::mutex> guard(sLock);
                if (Entry* entry = WatchedSource(healer))
                {
                    entry->values["heal_raw"] += raw;
                    entry->values["heal_eff"] += gain;
                }

                if (Entry* entry = receiver ? WatchedEntry(receiver) : nullptr)
                    entry->values["heal_taken"] += gain;
            }

            // Players are counted by OnPlayerJustDied; this adds creature deaths and kills.
            void OnUnitDeath(Unit* unit, Unit* killer) override
            {
                if (!Active() || !unit)
                    return;

                std::lock_guard<std::mutex> guard(sLock);
                if (!unit->IsPlayer())
                    if (Entry* entry = WatchedEntry(unit))
                        entry->values["deaths"] += 1.0;

                if (Entry* entry = WatchedSource(killer))
                    entry->values["kills"] += 1.0;
            }
        };

        class TacticsMetricsPlayerScript : public PlayerScript
        {
        public:
            TacticsMetricsPlayerScript() : PlayerScript("TacticsMetricsPlayerScript",
                { PLAYERHOOK_ON_PLAYER_JUST_DIED, PLAYERHOOK_ON_PLAYER_ENTER_COMBAT, PLAYERHOOK_ON_PLAYER_LEAVE_COMBAT }) { }

            void OnPlayerJustDied(Player* player) override
            {
                if (!Active() || !player)
                    return;

                std::lock_guard<std::mutex> guard(sLock);
                if (Entry* entry = WatchedEntry(player))
                    entry->values["deaths"] += 1.0;
            }

            // May fire more than once per transition (CombatManager and Unit::ClearInCombat): dedup by state.
            void OnPlayerEnterCombat(Player* player, Unit* /*enemy*/) override
            {
                if (!Active() || !player)
                    return;

                std::lock_guard<std::mutex> guard(sLock);
                Entry* entry = WatchedEntry(player);
                if (!entry || entry->combatSince)
                    return;

                uint32 const now = getMSTime();
                entry->combatSince = now ? now : 1;
                if (!entry->values.count("combat_enter_at"))
                    entry->values["combat_enter_at"] = double(entry->combatSince);
            }

            void OnPlayerLeaveCombat(Player* player) override
            {
                if (!Active() || !player)
                    return;

                std::lock_guard<std::mutex> guard(sLock);
                Entry* entry = WatchedEntry(player);
                if (!entry || !entry->combatSince)
                    return;

                entry->values["combat_ms"] += double(getMSTimeDiff(entry->combatSince, getMSTime()));
                entry->combatSince = 0;
            }
        };

        class TacticsMetricsSpellScript : public AllSpellScript
        {
        public:
            TacticsMetricsSpellScript() : AllSpellScript("TacticsMetricsSpellScript",
                { ALLSPELLHOOK_ON_PREPARE, ALLSPELLHOOK_ON_CAST }) { }

            void OnSpellPrepare(Spell* spell, Unit* caster, SpellInfo const* spellInfo) override
            {
                if (!Active() || !caster || !spell || !spellInfo || spell->IsTriggered())
                    return;

                std::lock_guard<std::mutex> guard(sLock);
                Entry* entry = WatchedEntry(caster);
                if (!entry)
                    return;

                entry->values["casts"] += 1.0;
                entry->values["cast." + std::to_string(spellInfo->Id)] += 1.0;
                if (tTacticsCast)
                    entry->values["casts_tactics"] += 1.0;
            }

            // Called after TakePower, so GetPowerCost() is what the caster actually paid.
            void OnSpellCast(Spell* spell, Unit* caster, SpellInfo const* spellInfo, bool /*skipCheck*/) override
            {
                if (!Active() || !caster || !spell || !spellInfo)
                    return;

                int32 const cost = spell->GetPowerCost();
                bool const counted = !spell->IsTriggered();
                if (cost <= 0 && !counted)
                    return;

                std::lock_guard<std::mutex> guard(sLock);
                Entry* entry = WatchedEntry(caster);
                if (!entry)
                    return;

                // casts - casts_done = casts that were interrupted or failed after prepare
                if (counted)
                    entry->values["casts_done"] += 1.0;

                if (cost <= 0)
                    return;

                entry->values["power_spent." + std::to_string(spellInfo->PowerType)] += cost;
                if (spellInfo->PowerType == uint32(POWER_MANA))
                    entry->values["mana_spent"] += cost;
            }
        };
    }
}

// ================================================================== wow.metrics (any thread)
namespace Tactics::Lua
{
    namespace
    {
        // A metrics id: a number (player low guid) or a 16-digit guid hex string (creatures).
        bool MetricsId(sol::object const& id, ObjectGuid& out)
        {
            if (id.get_type() == sol::type::number)
            {
                double const n = id.as<double>();
                if (!(n >= 1.0 && n <= 4294967295.0))
                    return false;

                out = ObjectGuid::Create<HighGuid::Player>(uint32(n));
                return true;
            }

            if (id.get_type() == sol::type::string)
                return HexToGuid(id.as<std::string>(), out) && !out.IsEmpty();

            if (id.is<UnitHandle>())
            {
                out = id.as<UnitHandle>().guid;
                return !out.IsEmpty();
            }

            return false;
        }
    }

    void RegisterMetricsApi(sol::state_view& lua, sol::table& wow)
    {
        sol::table metrics = lua.create_table();

        metrics["active"] = []() { return Metrics::Active(); };
        metrics["watch"] = [](sol::object id, sol::optional<bool> on)
        {
            ObjectGuid guid;
            if (!MetricsId(id, guid))
                return false;

            Metrics::Watch(guid, on.value_or(true));
            return true;
        };
        metrics["watched"] = [](sol::object id)
        {
            ObjectGuid guid;
            return MetricsId(id, guid) && Metrics::Watched(guid);
        };
        metrics["add"] = [](sol::object id, std::string const& key, sol::optional<double> value)
        {
            ObjectGuid guid;
            if (key.empty() || key.size() > 64 || !MetricsId(id, guid))
                return false;

            double const v = value.value_or(1.0);
            if (!std::isfinite(v))
                return false;

            Metrics::Add(guid, key, v);
            return true;
        };
        metrics["get"] = [](sol::object id, sol::this_state s)
        {
            sol::state_view view(s);
            sol::table t = view.create_table();
            ObjectGuid guid;
            if (!MetricsId(id, guid))
                return t;

            for (auto const& [key, value] : Metrics::Get(guid))
                t[key] = value;

            return t;
        };
        metrics["reset"] = [](sol::object id)
        {
            ObjectGuid guid;
            if (!MetricsId(id, guid))
                return false;

            Metrics::Reset(guid);
            return true;
        };
        metrics["clear"] = []() { Metrics::Clear(); };

        wow["metrics"] = metrics;
    }
}

void AddTacticsMetricsScripts()
{
    new Tactics::Metrics::TacticsMetricsUnitScript();
    new Tactics::Metrics::TacticsMetricsPlayerScript();
    new Tactics::Metrics::TacticsMetricsSpellScript();
}
