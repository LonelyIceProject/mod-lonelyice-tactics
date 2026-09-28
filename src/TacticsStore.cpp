/*
 * Bot tactics - opaque per-character key/value store (characters.character_tactics).
 *
 * this file only caches and persists strings.
 */

#include "TacticsHost.h"

#include "DatabaseEnv.h"
#include "Field.h"
#include "Log.h"
#include "QueryResult.h"
#include "Timer.h"

#include <atomic>
#include <mutex>
#include <unordered_map>

namespace
{
    struct Entry
    {
        std::map<std::string, std::string> values;
        uint32 revision = 0;
        uint32 lastWriteMs = 0;
        bool written = false;           // at least one Set/Erase since the rows were loaded
    };

    // A guid forgotten shortly after a write keeps its cache here for a while: the async REPLACE/DELETE
    // may not be committed yet, and a synchronous reload (other connection) could read stale rows.
    struct Held
    {
        Entry entry;
        uint32 heldAtMs = 0;
    };

    constexpr uint32 WRITE_SETTLE_MS = 60000;

    std::mutex sLock;
    std::unordered_map<uint32, Entry> sCache;
    std::unordered_map<uint32, Held> sHeld;
    std::atomic<uint32> sCounter{ 0 };

    uint32 NextRevision()
    {
        uint32 rev = ++sCounter;
        if (rev == 0)                   // wrapped; 0 means "no rows"
            rev = ++sCounter;
        return rev;
    }

    bool ValidName(std::string const& name)
    {
        if (name.empty() || name.size() > Tactics::MAX_STORE_NAME)
            return false;
        for (char c : name)
            if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'))
                return false;
        return true;
    }

    void PruneHeld(uint32 now)
    {
        for (auto itr = sHeld.begin(); itr != sHeld.end();)
        {
            if (getMSTimeDiff(itr->second.heldAtMs, now) > WRITE_SETTLE_MS)
                itr = sHeld.erase(itr);
            else
                ++itr;
        }
    }

    // Returns the cached entry of a guid, loading it on first use. `lock` must hold sLock; it is released
    // while the synchronous query runs so other threads are not blocked by the database.
    Entry& Load(std::unique_lock<std::mutex>& lock, uint32 guidLow)
    {
        auto itr = sCache.find(guidLow);
        if (itr != sCache.end())
            return itr->second;

        if (!sHeld.empty())
        {
            PruneHeld(getMSTime());
            auto held = sHeld.find(guidLow);
            if (held != sHeld.end())
            {
                Entry entry = std::move(held->second.entry);
                sHeld.erase(held);
                return sCache.emplace(guidLow, std::move(entry)).first->second;
            }
        }

        lock.unlock();
        std::map<std::string, std::string> values;
        if (QueryResult result = CharacterDatabase.Query("SELECT `name`, `data` FROM `character_tactics` WHERE `guid` = {}", guidLow))
        {
            do
            {
                Field* fields = result->Fetch();
                values[fields[0].Get<std::string>()] = fields[1].Get<std::string>();
            } while (result->NextRow());
        }
        lock.lock();

        // another thread may have loaded (and even written) it meanwhile; its state wins
        itr = sCache.find(guidLow);
        if (itr != sCache.end())
            return itr->second;

        Entry entry;
        entry.revision = values.empty() ? 0 : NextRevision();
        entry.values = std::move(values);
        return sCache.emplace(guidLow, std::move(entry)).first->second;
    }

    void MarkWritten(Entry& entry)
    {
        entry.revision = NextRevision();
        entry.lastWriteMs = getMSTime();
        entry.written = true;
    }

    std::string Escaped(std::string text)
    {
        CharacterDatabase.EscapeString(text);
        return text;
    }
}

namespace Tactics::Store
{
    uint32 Revision(uint32 guidLow)
    {
        if (!guidLow)
            return 0;

        std::unique_lock<std::mutex> lock(sLock);
        Entry const& entry = Load(lock, guidLow);
        return entry.values.empty() ? 0 : entry.revision;
    }

    std::optional<std::string> Get(uint32 guidLow, std::string const& name)
    {
        if (!guidLow)
            return std::nullopt;

        std::unique_lock<std::mutex> lock(sLock);
        Entry const& entry = Load(lock, guidLow);
        auto itr = entry.values.find(name);
        if (itr == entry.values.end())
            return std::nullopt;
        return itr->second;
    }

    std::map<std::string, std::string> GetAll(uint32 guidLow)
    {
        if (!guidLow)
            return { };

        std::unique_lock<std::mutex> lock(sLock);
        return Load(lock, guidLow).values;
    }

    bool Set(uint32 guidLow, std::string const& name, std::string const& data)
    {
        if (!guidLow || !ValidName(name) || data.size() > MAX_STORE_DATA)
            return false;

        {
            std::unique_lock<std::mutex> lock(sLock);
            Entry& entry = Load(lock, guidLow);
            entry.values[name] = data;
            MarkWritten(entry);
        }

        CharacterDatabase.Execute("REPLACE INTO `character_tactics` (`guid`, `name`, `data`, `updated`) VALUES ({}, '{}', '{}', UNIX_TIMESTAMP())",
            guidLow, Escaped(name), Escaped(data));
        return true;
    }

    bool Erase(uint32 guidLow, std::string const& name)
    {
        if (!guidLow || !ValidName(name))
            return false;

        {
            std::unique_lock<std::mutex> lock(sLock);
            Entry& entry = Load(lock, guidLow);
            if (!entry.values.erase(name))
                return false;
            MarkWritten(entry);
        }

        CharacterDatabase.Execute("DELETE FROM `character_tactics` WHERE `guid` = {} AND `name` = '{}'", guidLow, Escaped(name));
        return true;
    }

    void Forget(uint32 guidLow)
    {
        std::lock_guard<std::mutex> guard(sLock);
        auto itr = sCache.find(guidLow);
        if (itr == sCache.end())
            return;

        uint32 const now = getMSTime();
        if (itr->second.written && getMSTimeDiff(itr->second.lastWriteMs, now) <= WRITE_SETTLE_MS)
            sHeld[guidLow] = Held{ std::move(itr->second), now };
        sCache.erase(itr);
        PruneHeld(now);
    }
}

// Character deleted: rows and every cached copy go (called by TacticsDataScripts.cpp).
namespace Tactics::StoreDetail
{
    void DeleteCharacter(uint32 guidLow)
    {
        if (!guidLow)
            return;

        {
            std::lock_guard<std::mutex> guard(sLock);
            sCache.erase(guidLow);
            sHeld.erase(guidLow);
        }
        CharacterDatabase.Execute("DELETE FROM `character_tactics` WHERE `guid` = {}", guidLow);
    }
}
