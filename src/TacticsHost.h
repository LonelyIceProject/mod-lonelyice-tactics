/*
 * Bot tactics (FF12-style gambits for party playerbots) - shared C++ contract.
 *
 *
 * two C++ halves that are written in parallel:
 *   - implementer B (engine glue + Lua host): TacticsEngine*.cpp, TacticsLua*.cpp
 *   - implementer C (persistence + addon transport + raw game data): TacticsStore.cpp,
 *     TacticsTransport.cpp, TacticsGameData.cpp, TacticsDataScripts.cpp
 * B calls Store / Transport / GameData (implemented by C). C calls Host (implemented by B).
 *
 * Rule: nothing here knows about targets, conditions, actions, presets, progression or protocol
 * messages. Those are string data owned by the Lua scripts (lua_scripts/tactics). C++ only moves
 * opaque strings and raw game facts.
 *
 * No sol2 / Lua headers here on purpose: only B's .cpp files include <sol/sol.hpp>.
 */

#ifndef MOD_LONELYICE_TACTICS_HOST_H
#define MOD_LONELYICE_TACTICS_HOST_H

#include "Common.h"
#include "Define.h"
#include "ObjectGuid.h"

#include <map>
#include <optional>
#include <string>
#include <vector>

class Player;

namespace Tactics
{
    // ------------------------------------------------------------------ addon wire constants (C, E)
    // Client <-> server addon messages: whisper-to-self with LANG_ADDON, text "BTAC\t<frame>".
    constexpr char const* ADDON_PREFIX = "BTAC";
    constexpr size_t MAX_WIRE_BYTES = 250;          // strlen(prefix) + 1 + frame; the core drops > 255
    constexpr size_t MAX_FRAME_DATA = 240;          // payload bytes per frame (after flag + 2-char id)
    constexpr size_t MAX_SERVER_PAYLOAD = 32768;    // largest payload Lua may send in one wow.send()
    constexpr size_t MAX_CLIENT_PAYLOAD = 16384;    // largest reassembled payload accepted from a client
    constexpr uint32 REASSEMBLY_TIMEOUT_MS = 30000; // incomplete multi-frame messages are dropped after this

    // ------------------------------------------------------------------ store limits (C)
    constexpr size_t MAX_STORE_NAME = 32;           // name must match [a-z0-9_]{1,32}
    constexpr size_t MAX_STORE_DATA = 60000;        // bytes per value (MEDIUMTEXT column)

    // ================================================================== Store (implemented by C)
    // Opaque per-character key/value text, table characters.character_tactics (guid, name, data).
    // Semantics of names and data belong to Lua. All functions are thread-safe (internal mutex) and may
    // be called from map-update threads and the world thread.
    namespace Store
    {
        // 0 when the character has no stored rows, otherwise a value > 0 that changes on every write to
        // that guid (taken from one global monotonic counter). First call per guid loads the rows with a
        // synchronous CharacterDatabase query and caches them; later calls never touch the DB.
        uint32 Revision(uint32 guidLow);

        std::optional<std::string> Get(uint32 guidLow, std::string const& name);
        std::map<std::string, std::string> GetAll(uint32 guidLow);

        // Update the cache immediately (bumps the revision), then REPLACE INTO asynchronously.
        // Returns false (and changes nothing) when guidLow == 0, the name is not [a-z0-9_]{1,32} or the
        // data is longer than MAX_STORE_DATA.
        bool Set(uint32 guidLow, std::string const& name, std::string const& data);

        // Remove one row (cache + async DELETE). Returns true if it existed.
        bool Erase(uint32 guidLow, std::string const& name);

        // Drop the cached rows of a guid (next access reloads). Called by C on logout.
        void Forget(uint32 guidLow);
    }

    // ================================================================== Transport (implemented by C)
    namespace Transport
    {
        // Queue a Lua payload for a player's BotTactics addon. Thread-safe; frames are built immediately
        // (split at UTF-8 character boundaries into <= MAX_FRAME_DATA byte slices) and sent from the
        // world thread on its next update, in order. Returns false (nothing queued) when the payload is
        // empty, longer than MAX_SERVER_PAYLOAD or contains a forbidden byte ('\0', '\n', '\r', '|').
        // A player that is offline at flush time silently loses the message.
        bool Send(ObjectGuid player, std::string const& payload);
    }

    // ================================================================== raw game data (implemented by C)
    // Plain facts from DBC/DB/the character, no filtering, no policy. B converts them into Lua tables
    // (field names in the spec, section 3.4).

    struct SpellRaw
    {
        uint32 id = 0;
        std::string name;                 // localized, falls back to the first non-empty locale
        std::string rank;                 // "Rank 3" / "Уровень 3" style subtext, may be empty
        uint32 attributes[8] = { };       // Attributes, AttributesEx .. AttributesEx7
        uint32 effects[3] = { };          // SpellEffects (SPELL_EFFECT_*)
        uint32 auras[3] = { };            // Effects[i].ApplyAuraName (SPELL_AURA_*)
        uint32 implicitTargetA[3] = { };  // Effects[i].TargetA target type
        int32 effectMisc[3] = { };        // Effects[i].MiscValue (DispelType for SPELL_EFFECT_DISPEL, ...)
        uint32 baseLevel = 0;
        uint32 spellLevel = 0;
        uint32 maxLevel = 0;
        uint32 powerType = 0;
        uint32 manaCost = 0;
        uint32 manaCostPct = 0;
        float minRange = 0.0f;            // hostile range entry
        float maxRange = 0.0f;
        float maxRangeFriend = 0.0f;
        uint32 castTimeMs = 0;            // base cast time (0 = instant)
        uint32 recoveryMs = 0;            // RecoveryTime
        uint32 categoryRecoveryMs = 0;    // CategoryRecoveryTime
        int32 durationMs = 0;             // -1 = infinite
        uint32 dispel = 0;                // DispelType of the spell itself
        uint32 mechanic = 0;
        uint32 schoolMask = 0;
        uint32 iconId = 0;                // SpellIconID
        uint32 family = 0;                // SpellFamilyName
        bool passive = false;             // SpellInfo::IsPassive()
        bool positive = false;            // SpellInfo::IsPositive()
        bool talent = false;              // first rank of this chain is a talent (GetTalentSpellPos)
        bool channeled = false;
        bool autoRepeat = false;          // IsAutoRepeatRangedSpell()
        uint32 firstRank = 0;             // spell chain; all equal to id for rankless spells
        uint32 lastRank = 0;
        uint32 prevRank = 0;
        uint32 nextRank = 0;
        uint8 rankIndex = 0;              // 1-based rank in chain, 0 when not in a chain
        std::vector<uint32> skillLines;   // SkillLineAbility.SkillLine of every entry for this spell id
    };

    struct SkillLineRaw
    {
        uint32 id = 0;
        uint32 category = 0;              // SkillLine.categoryId (7 = class, 9 = secondary, 10 = language, 11 = profession ...)
        std::string name;                 // localized, falls back to the first non-empty locale
        uint32 spellIcon = 0;
    };

    struct SkillAbilityRaw                // one SkillLineAbility.dbc row
    {
        uint32 spell = 0;
        uint32 skillLine = 0;
        uint32 raceMask = 0;              // 0 = all races
        uint32 classMask = 0;             // 0 = all classes
        uint32 minSkillRank = 0;
        uint32 supercededBySpell = 0;
        uint32 acquireMethod = 0;         // 1 = learned on getting the skill
    };

    struct ItemRaw
    {
        uint32 entry = 0;
        std::string name;                 // localized (item_template_locale), falls back to item_template.name
        uint32 itemClass = 0;
        uint32 itemSubClass = 0;
        uint32 quality = 0;
        uint32 itemLevel = 0;
        uint32 requiredLevel = 0;
        uint32 maxStack = 0;
        std::vector<uint32> useSpells;    // spells with trigger ITEM_SPELLTRIGGER_ON_USE, in slot order
    };

    struct BagItemRaw
    {
        uint32 entry = 0;
        uint32 count = 0;                 // summed over all stacks in backpack + equipped bags
    };

    namespace GameData
    {
        bool GetSpell(uint32 spellId, LocaleConstant locale, SpellRaw& out);
        bool GetSkillLine(uint32 skillLineId, LocaleConstant locale, SkillLineRaw& out);
        std::vector<SkillAbilityRaw> GetSkillAbilities(uint32 skillLineId);   // all rows of that skill line
        bool GetItem(uint32 entry, LocaleConstant locale, ItemRaw& out);

        // Must be called on the thread that owns the player (its map thread, or the world thread while
        // maps are not updating, e.g. inside chat handling).
        std::vector<uint32> GetKnownSpells(Player* player);      // active, not disabled, not removed; includes passives
        std::vector<BagItemRaw> GetBagItems(Player* player);     // backpack + bags, no bank/equipped/keyring
    }

    // ================================================================== Host (implemented by B)
    namespace Host
    {
        // A complete (reassembled) addon payload from a real player. Called by C on the world thread
        // (chat handling). Runs Lua tactics.on_message(player, payload) in the calling thread's state.
        void OnClientMessage(Player* player, std::string const& payload);

        // Lifecycle of REAL players only (C filters bots): "login" after login, "logout" before logout.
        // Runs Lua tactics.on_event(event, player) if the scripts define it.
        void OnPlayerEvent(char const* event, Player* player);

        // Bump the script version; every Lua state rebuilds itself before its next call.
        void RequestReload();
        uint32 ScriptVersion();
    }
}

#endif
