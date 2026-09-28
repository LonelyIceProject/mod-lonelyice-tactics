/*
 * Bot tactics - addon message transport (spec section 5.1).
 *
 * Wire text: "BTAC\t<flag><id><data>", flag F (whole) / B (first) / C (middle) / E (last), id = 2 chars
 * [0-9A-Za-z], data <= 240 bytes cut at UTF-8 boundaries. This file only moves opaque payloads: it knows
 * nothing about message types (those belong to the Lua scripts and the BotTactics addon).
 *
 * Server -> client: Send() builds the frames on the calling thread (any thread) and queues them; the world
 * thread sends them from WorldScript::OnUpdate (Flush). Client -> server: ReceiveFrame() is called from the
 * chat hook (world thread) and hands complete payloads to Host::OnClientMessage.
 */

#include "TacticsHost.h"

#include "Chat.h"
#include "Log.h"
#include "ObjectAccessor.h"
#include "Player.h"
#include "Timer.h"
#include "WorldPacket.h"
#include "WorldSession.h"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <deque>
#include <mutex>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace
{
    constexpr char const* ID_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    constexpr uint32 ID_COUNT = 62 * 62;
    constexpr size_t MAX_OUTBOX_FRAMES = 20000;     // safety net; flushed every world tick
    constexpr size_t MAX_BUFFERS_PER_SENDER = 8;    // concurrent incomplete messages from one client

    static_assert(std::char_traits<char>::length("BTAC") + 1 + 3 + Tactics::MAX_FRAME_DATA <= Tactics::MAX_WIRE_BYTES,
        "addon frame exceeds the wire limit");

    struct OutFrame
    {
        ObjectGuid player;
        std::string wire;               // "BTAC\t<frame>"
    };

    std::mutex sOutLock;
    std::deque<OutFrame> sOutbox;
    std::atomic<uint32> sNextId{ 0 };
    uint32 sOverflowLogMs = 0;

    struct InBuffer
    {
        std::string data;
        uint32 startedMs = 0;
    };

    // key = (sender low guid << 16) | id index
    std::mutex sInLock;
    std::unordered_map<uint64, InBuffer> sInbox;

    bool IsIdChar(char c)
    {
        return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
    }

    uint32 IdIndex(char c)
    {
        return uint32(std::strchr(ID_CHARS, c) - ID_CHARS);
    }

    uint64 BufferKey(uint32 senderLow, char id0, char id1)
    {
        return (uint64(senderLow) << 16) | (IdIndex(id0) * 62 + IdIndex(id1));
    }

    uint32 SenderOf(uint64 key)
    {
        return uint32(key >> 16);
    }

    void PruneInbox(uint32 now)
    {
        for (auto itr = sInbox.begin(); itr != sInbox.end();)
        {
            if (getMSTimeDiff(itr->second.startedMs, now) > Tactics::REASSEMBLY_TIMEOUT_MS)
                itr = sInbox.erase(itr);
            else
                ++itr;
        }
    }

    size_t CountBuffers(uint32 senderLow)
    {
        size_t count = 0;
        for (auto const& [key, buffer] : sInbox)
            if (SenderOf(key) == senderLow)
                ++count;
        return count;
    }
}

namespace Tactics::Transport
{
    bool Send(ObjectGuid player, std::string const& payload)
    {
        if (!player || payload.empty() || payload.size() > MAX_SERVER_PAYLOAD)
            return false;

        if (payload.find_first_of(std::string("\0\n\r|", 4)) != std::string::npos)
            return false;

        uint32 const idx = sNextId.fetch_add(1) % ID_COUNT;
        char const id[2] = { ID_CHARS[idx / 62], ID_CHARS[idx % 62] };
        std::string const head = std::string(ADDON_PREFIX) + "\t";

        std::vector<std::string> slices;
        size_t pos = 0;
        while (pos < payload.size())
        {
            size_t len = std::min(MAX_FRAME_DATA, payload.size() - pos);
            if (pos + len < payload.size())
            {
                // never start the next slice on a UTF-8 continuation byte
                size_t cut = len;
                while (cut > 0 && (uint8(payload[pos + cut]) & 0xC0) == 0x80)
                    --cut;
                if (cut > 0)
                    len = cut;
            }
            slices.push_back(payload.substr(pos, len));
            pos += len;
        }

        std::vector<OutFrame> frames;
        frames.reserve(slices.size());
        for (size_t i = 0; i < slices.size(); ++i)
        {
            char flag = 'F';
            if (slices.size() > 1)
                flag = i == 0 ? 'B' : (i + 1 == slices.size() ? 'E' : 'C');

            std::string wire;
            wire.reserve(head.size() + 3 + slices[i].size());
            wire += head;
            wire += flag;
            wire += id[0];
            wire += id[1];
            wire += slices[i];
            frames.push_back({ player, std::move(wire) });
        }

        std::lock_guard<std::mutex> guard(sOutLock);
        if (sOutbox.size() + frames.size() > MAX_OUTBOX_FRAMES)
        {
            uint32 const now = getMSTime();
            if (!sOverflowLogMs || getMSTimeDiff(sOverflowLogMs, now) > 10000)
            {
                sOverflowLogMs = now;
                LOG_ERROR("module", "[tactics] addon outbox full ({} frames), message dropped", sOutbox.size());
            }
            return false;
        }

        for (OutFrame& frame : frames)
            sOutbox.push_back(std::move(frame));
        return true;
    }
}

// Internal entry points used by TacticsDataScripts.cpp (no header on purpose: C-private).
namespace Tactics::TransportDetail
{
    // World thread only.
    void Flush()
    {
        std::deque<OutFrame> frames;
        {
            std::lock_guard<std::mutex> guard(sOutLock);
            if (sOutbox.empty())
                return;
            frames.swap(sOutbox);
        }

        ObjectGuid lastGuid;
        Player* lastPlayer = nullptr;
        for (OutFrame const& frame : frames)
        {
            if (frame.player != lastGuid)
            {
                lastGuid = frame.player;
                lastPlayer = ObjectAccessor::FindConnectedPlayer(frame.player);
            }

            if (!lastPlayer || !lastPlayer->GetSession())
                continue;

            WorldPacket data;
            ChatHandler::BuildChatPacket(data, CHAT_MSG_WHISPER, LANG_ADDON, lastPlayer, lastPlayer, frame.wire);
            lastPlayer->SendDirectMessage(&data);
        }
    }

    // One frame (text after "BTAC\t") from a real player's addon. World thread (chat handling).
    void ReceiveFrame(Player* player, std::string const& frame)
    {
        if (!player || frame.size() < 3 || !IsIdChar(frame[1]) || !IsIdChar(frame[2]))
            return;

        char const flag = frame[0];
        std::string_view const data(frame.data() + 3, frame.size() - 3);
        uint32 const senderLow = player->GetGUID().GetCounter();

        if (flag == 'F')
        {
            if (!data.empty() && data.size() <= MAX_CLIENT_PAYLOAD)
                Host::OnClientMessage(player, std::string(data));
            return;
        }

        if (flag != 'B' && flag != 'C' && flag != 'E')
            return;

        std::string complete;
        {
            std::lock_guard<std::mutex> guard(sInLock);
            uint32 const now = getMSTime();
            PruneInbox(now);

            uint64 const key = BufferKey(senderLow, frame[1], frame[2]);
            auto itr = sInbox.find(key);

            if (flag == 'B')
            {
                if (itr == sInbox.end())
                {
                    if (CountBuffers(senderLow) >= MAX_BUFFERS_PER_SENDER)
                        return;
                    itr = sInbox.emplace(key, InBuffer()).first;
                }
                itr->second.data.assign(data.data(), data.size());
                itr->second.startedMs = now;
                return;
            }

            if (itr == sInbox.end())
                return;                                     // C/E without B: dropped

            if (itr->second.data.size() + data.size() > MAX_CLIENT_PAYLOAD)
            {
                sInbox.erase(itr);
                return;
            }

            itr->second.data.append(data.data(), data.size());
            if (flag == 'C')
                return;

            complete = std::move(itr->second.data);
            sInbox.erase(itr);
        }

        if (!complete.empty())
            Host::OnClientMessage(player, complete);
    }

    // Player logged out: drop its incomplete messages.
    void ForgetSender(uint32 senderLow)
    {
        std::lock_guard<std::mutex> guard(sInLock);
        for (auto itr = sInbox.begin(); itr != sInbox.end();)
        {
            if (SenderOf(itr->first) == senderLow)
                itr = sInbox.erase(itr);
            else
                ++itr;
        }
    }
}
