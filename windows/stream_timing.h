#pragma once

#include <algorithm>
#include <cstdint>

// Pure, dependency-free arrival-timing statistics for one receive session.
// The phone stamps each frame with its own clock; the PC stamps arrival with
// steady_clock. The two clocks have unrelated origins, so only the *change* of
// (arrival - source) is meaningful: it grows when frames are held up (transport
// stall, probe backlog) or when the clocks drift apart. All arithmetic is
// signed so a source timestamp that goes backwards cannot underflow
// (R-ENG-TIME). Inputs are clamped, so extreme values cannot overflow.
class StreamTimingStats final {
public:
    // Frames closer together than this count as a burst (a backlog draining).
    static constexpr int64_t kBurstGapUs = 2'000;

    // Forget everything: call when a new phone connection starts.
    void BeginSession() {
        *this = StreamTimingStats{};
    }

    void OnFrame(uint64_t sourceUs, uint64_t arrivalUs) {
        const int64_t source = Clamp(sourceUs);
        const int64_t arrival = Clamp(arrivalUs);
        const int64_t offset = arrival - source;

        if (!has_frame_) {
            has_frame_ = true;
            first_offset_ = offset;
            min_offset_ = offset;
        } else {
            min_offset_ = std::min(min_offset_, offset);
            const int64_t gap = std::max<int64_t>(0, arrival - last_arrival_);
            max_arrival_gap_us_ = std::max(max_arrival_gap_us_, gap);
            if (gap < kBurstGapUs) ++burst_frames_;
        }
        last_arrival_ = arrival;

        extra_delay_us_ = offset - min_offset_;
        window_max_extra_delay_us_ = std::max(window_max_extra_delay_us_, extra_delay_us_);
        skew_us_ = offset - first_offset_;
    }

    // Clears the per-report-window maxima and counters. The session minimum,
    // first offset and skew trend deliberately survive.
    void ResetWindow() {
        window_max_extra_delay_us_ = extra_delay_us_;
        max_arrival_gap_us_ = 0;
        burst_frames_ = 0;
    }

    // Current offset above the best (smallest) offset seen this session.
    int64_t ExtraDelayUs() const { return extra_delay_us_; }
    int64_t WindowMaxExtraDelayUs() const { return window_max_extra_delay_us_; }
    // Offset change since the first frame; a slow trend means clock drift or
    // delay that never drains.
    int64_t SkewUs() const { return skew_us_; }
    int64_t MaxArrivalGapUs() const { return max_arrival_gap_us_; }
    uint32_t BurstFrames() const { return burst_frames_; }

private:
    // Keep |source - arrival| far from int64 overflow even for hostile input.
    static constexpr int64_t kLimit = int64_t{1} << 61;

    static int64_t Clamp(uint64_t value) {
        return value > static_cast<uint64_t>(kLimit) ? kLimit : static_cast<int64_t>(value);
    }

    bool has_frame_ = false;
    int64_t first_offset_ = 0;
    int64_t min_offset_ = 0;
    int64_t last_arrival_ = 0;
    int64_t extra_delay_us_ = 0;
    int64_t window_max_extra_delay_us_ = 0;
    int64_t skew_us_ = 0;
    int64_t max_arrival_gap_us_ = 0;
    uint32_t burst_frames_ = 0;
};
