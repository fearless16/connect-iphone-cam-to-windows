#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

// T2.6 (G6): flow control for the loopback TCP relay to OBS (--obs-tcp).
//
// OBS plays a Media Source by its timestamps, anchored at the first frame it
// decodes, so any backlog it holds at that moment stays for the whole session.
// Over UDP the receiver cannot see that backlog. FFmpeg's receive thread keeps
// queueing while OBS is not reading (a hidden source, a scene switch), and OBS
// later plays the queue late. Over TCP the receiver sees OBS stop reading:
// unsent bytes age in the send queue. It then drops frames instead of
// queueing them, and resumes on the next decoder-join AU once OBS reads again.

// Muxed MPEG-TS bytes waiting for the OBS client, with access-unit boundaries.
// Drops happen only at those boundaries, so the stream stays 188-byte aligned.
class ObsTcpSendQueue final {
public:
    // Starts the record for one access unit; Append adds its bytes. A record
    // that received no bytes (the frame was dropped) is reused.
    void BeginFrame(uint64_t arrivalUs) {
        if (!frames_.empty() && frames_.back().start == bytes_.size()) {
            frames_.back().arrivalUs = arrivalUs;
            return;
        }
        frames_.push_back(Frame{bytes_.size(), arrivalUs});
    }

    void Append(const uint8_t* data, size_t size) {
        if (size == 0) return;
        if (frames_.empty()) frames_.push_back(Frame{bytes_.size(), 0});
        bytes_.insert(bytes_.end(), data, data + size);
    }

    const uint8_t* Data() const { return bytes_.data() + sent_; }
    size_t Size() const { return bytes_.size() - sent_; }

    // `count` bytes from Data() reached the socket.
    void Consume(size_t count) {
        sent_ += count < Size() ? count : Size();
        if (sent_ == bytes_.size()) {
            Clear();  // the usual case: everything left at once; capacity stays
            return;
        }
        // Forget frames that are fully sent; keep the one being sent.
        size_t first = 0;
        while (first + 1 < frames_.size() && frames_[first + 1].start <= sent_) ++first;
        if (first > 0) frames_.erase(frames_.begin(), frames_.begin() + static_cast<std::ptrdiff_t>(first));
        if (sent_ >= kCompactBytes) {  // rare: OBS takes data slowly
            const size_t shift = frames_.front().start;
            bytes_.erase(bytes_.begin(), bytes_.begin() + static_cast<std::ptrdiff_t>(shift));
            sent_ -= shift;
            for (Frame& frame : frames_) frame.start -= shift;
        }
    }

    // True when OBS has not taken a frame that finished arriving more than
    // `maxAgeUs` before `nowUs`.
    bool IsBacklogged(uint64_t nowUs, uint64_t maxAgeUs) const {
        if (Size() == 0) return false;
        const uint64_t arrival = frames_[OldestUnsentIndex()].arrivalUs;
        return nowUs > arrival && nowUs - arrival > maxAgeUs;
    }

    // Drops every whole frame after the oldest unsent one. That one stays, even
    // if none of it has gone out yet: the queue then empties only when OBS
    // actually takes data, which is how the relay knows OBS reads again.
    // Returns the bytes dropped.
    size_t DropUnsentFrames() {
        if (Size() == 0) return 0;
        const size_t keepIndex = OldestUnsentIndex();
        const size_t cut = keepIndex + 1 < frames_.size() ? frames_[keepIndex + 1].start : bytes_.size();
        const size_t dropped = bytes_.size() - cut;
        bytes_.resize(cut);
        frames_.resize(keepIndex + 1);
        return dropped;
    }

    void Clear() {
        bytes_.clear();
        frames_.clear();
        sent_ = 0;
    }

private:
    static constexpr size_t kCompactBytes = 4u * 1024u * 1024u;

    struct Frame {
        size_t start;
        uint64_t arrivalUs;
    };

    // The frame that holds the next unsent byte (call only when Size() > 0).
    size_t OldestUnsentIndex() const {
        size_t index = 0;
        while (index + 1 < frames_.size() && frames_[index + 1].start <= sent_) ++index;
        return index;
    }

    std::vector<uint8_t> bytes_;
    std::vector<Frame> frames_;
    size_t sent_ = 0;
};

enum class ObsTcpAction { Write, Drop };

// Per-access-unit decision for the OBS TCP relay, and the OBS timeline.
class ObsTcpFlowControl final {
public:
    // Unsent data older than this means OBS stopped reading. It is well above
    // the time a 4K keyframe needs on loopback, and short enough to keep OBS live.
    static constexpr uint64_t kMaxBacklogUs = 100'000;

    // Call once per access unit, before it is muxed.
    ObsTcpAction OnFrame(bool clientConnected, bool backlogged, bool joinPoint) {
        if (!clientConnected || backlogged) {
            if (clientConnected && !stalled_) {
                stalled_ = true;
                ++stalls_;
            }
            needs_join_ = true;
            ++dropped_;
            return ObsTcpAction::Drop;
        }
        if (needs_join_ && !joinPoint) {
            ++dropped_;
            return ObsTcpAction::Drop;
        }
        if (needs_join_) {
            needs_join_ = false;
            stalled_ = false;
            resume_ = true;
        }
        return ObsTcpAction::Write;
    }

    // A client attached or went away: the next written AU must be a join point.
    void OnClientChanged() {
        needs_join_ = true;
        stalled_ = false;
    }

    // Maps the relay arrival timeline to what OBS sees. After a run of dropped
    // frames the next written frame lands one nominal frame after the last
    // written one: a forward jump would make OBS wait out the gap and keep it
    // as delay. Gaps while frames keep being written stay intact. The result
    // grows strictly as long as `relativeUs` does.
    uint64_t MapTimelineUs(uint64_t relativeUs, uint64_t nominalFrameUs) {
        uint64_t out = relativeUs > offset_us_ ? relativeUs - offset_us_ : 0;
        if (resume_ && has_last_) {
            const uint64_t continued = last_out_us_ + nominalFrameUs;
            if (out > continued) {
                offset_us_ += out - continued;
                out = continued;
            }
        }
        resume_ = false;
        has_last_ = true;
        last_out_us_ = out;
        return out;
    }

    bool Stalled() const { return stalled_; }
    uint64_t Stalls() const { return stalls_; }
    uint64_t DroppedFrames() const { return dropped_; }

private:
    bool needs_join_ = true;
    bool stalled_ = false;
    bool resume_ = false;
    bool has_last_ = false;
    uint64_t offset_us_ = 0;
    uint64_t last_out_us_ = 0;
    uint64_t stalls_ = 0;
    uint64_t dropped_ = 0;
};
