#include <cassert>
#include <cstdint>
#include <cstdlib>

#include "stream_timing.h"

namespace {
constexpr uint64_t kFrameUs = 16'667;      // ~60 fps
constexpr uint64_t kLatencyUs = 5'000;     // arbitrary fixed transport latency
constexpr uint64_t kClockOriginUs = 987'654'321;  // unrelated clock origins

bool Near(int64_t actual, int64_t expected, int64_t tolerance) {
    return std::llabs(actual - expected) <= tolerance;
}
}  // namespace

int main() {
    // Steady 60 fps: no extra delay, no skew, no bursts.
    {
        StreamTimingStats stats;
        stats.BeginSession();
        for (uint64_t i = 0; i < 600; ++i) {
            stats.OnFrame(i * kFrameUs, kClockOriginUs + i * kFrameUs + kLatencyUs);
        }
        assert(stats.ExtraDelayUs() == 0);
        assert(stats.WindowMaxExtraDelayUs() == 0);
        assert(stats.SkewUs() == 0);
        assert(stats.BurstFrames() == 0);
        assert(Near(stats.MaxArrivalGapUs(), static_cast<int64_t>(kFrameUs), 1));
    }

    // A 100 ms stall followed by a burst that drains the backlog.
    {
        StreamTimingStats stats;
        stats.BeginSession();
        uint64_t arrival = 0;
        uint64_t i = 0;
        for (; i < 10; ++i) {
            arrival = kClockOriginUs + i * kFrameUs + kLatencyUs;
            stats.OnFrame(i * kFrameUs, arrival);
        }
        assert(stats.ExtraDelayUs() == 0);
        // Frame 10 arrives 100 ms late; later frames arrive 1 ms apart until
        // they catch up with their natural arrival time.
        arrival += kFrameUs + 100'000;
        stats.OnFrame(i * kFrameUs, arrival);
        ++i;
        assert(Near(stats.ExtraDelayUs(), 100'000, 1));
        for (; i < 60; ++i) {
            const uint64_t natural = kClockOriginUs + i * kFrameUs + kLatencyUs;
            arrival = natural > arrival + 1'000 ? natural : arrival + 1'000;
            stats.OnFrame(i * kFrameUs, arrival);
        }
        assert(Near(stats.MaxArrivalGapUs(), 116'667, 2));
        assert(stats.BurstFrames() > 0);
        assert(Near(stats.WindowMaxExtraDelayUs(), 100'000, 1));
        assert(stats.ExtraDelayUs() == 0);  // backlog fully drained

        // The window resets; the session minimum and trend survive.
        stats.ResetWindow();
        assert(stats.BurstFrames() == 0);
        assert(stats.MaxArrivalGapUs() == 0);
        assert(stats.WindowMaxExtraDelayUs() == 0);
    }

    // A source timestamp that goes backwards must not crash or underflow.
    {
        StreamTimingStats stats;
        stats.BeginSession();
        stats.OnFrame(1'000'000, 2'000'000);
        stats.OnFrame(500'000, 2'016'667);
        stats.OnFrame(0, 0);  // arrival going backwards too
        assert(stats.ExtraDelayUs() >= 0);
        assert(stats.ExtraDelayUs() < 10'000'000);
        assert(stats.MaxArrivalGapUs() >= 0);
        assert(stats.MaxArrivalGapUs() < 10'000'000);
    }

    // Hostile extremes are clamped instead of overflowing.
    {
        StreamTimingStats stats;
        stats.BeginSession();
        stats.OnFrame(0, 0);
        stats.OnFrame(UINT64_MAX, 0);
        stats.OnFrame(0, UINT64_MAX);
        assert(stats.ExtraDelayUs() >= 0);
        assert(stats.MaxArrivalGapUs() >= 0);
    }

    // 100 ppm clock drift over 10 minutes at 60 fps: skew is about 60 ms.
    {
        StreamTimingStats stats;
        stats.BeginSession();
        const uint64_t frames = 10ull * 60 * 60;
        for (uint64_t i = 0; i < frames; ++i) {
            const uint64_t source = i * kFrameUs;
            const uint64_t arrival = kClockOriginUs + source + source / 10'000 + kLatencyUs;
            stats.OnFrame(source, arrival);
        }
        assert(Near(stats.SkewUs(), 60'000, 1'000));
        assert(Near(stats.ExtraDelayUs(), stats.SkewUs(), 1));
        assert(stats.BurstFrames() == 0);
    }

    // BeginSession forgets the previous session completely.
    {
        StreamTimingStats stats;
        stats.OnFrame(0, 1'000);
        stats.OnFrame(kFrameUs, 1'000 + kFrameUs + 50'000);
        assert(stats.ExtraDelayUs() == 50'000);
        stats.BeginSession();
        stats.OnFrame(0, 9'000'000);
        assert(stats.ExtraDelayUs() == 0);
        assert(stats.SkewUs() == 0);
        assert(stats.MaxArrivalGapUs() == 0);
    }

    return 0;
}
