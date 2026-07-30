#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

// A two-slot, instance-owned latest-frame store.  The decoder never waits for
// DirectShow, and DirectShow only ever sees a complete frame.
class LatestFrameStore {
public:
    explicit LatestFrameStore(size_t frameBytes)
        : slots_{std::vector<uint8_t>(frameBytes), std::vector<uint8_t>(frameBytes)},
          frameBytes_(frameBytes) {}

    void publish(const uint8_t* frame, size_t bytes) {
        if (!frame || bytes != frameBytes_) return;
        std::lock_guard<std::mutex> lock(mutex_);
        const unsigned next = active_ ^ 1u;
        std::memcpy(slots_[next].data(), frame, frameBytes_);
        active_ = next;
        hasFrame_ = true;
        ++generation_;
    }

    bool copyLatest(uint8_t* destination, size_t bytes, uint64_t* generation = nullptr) const {
        if (!destination || bytes != frameBytes_) return false;
        std::lock_guard<std::mutex> lock(mutex_);
        if (!hasFrame_) return false;
        std::memcpy(destination, slots_[active_].data(), frameBytes_);
        if (generation) *generation = generation_;
        return true;
    }

private:
    mutable std::mutex mutex_;
    std::vector<uint8_t> slots_[2];
    size_t frameBytes_;
    unsigned active_ = 0;
    bool hasFrame_ = false;
    uint64_t generation_ = 0;
};
