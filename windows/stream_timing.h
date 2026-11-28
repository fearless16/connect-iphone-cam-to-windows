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

// Counts frames missing from the source timeline (phone timestamps) without
// assuming a frame rate. The phone streams at 60 fps or 30 fps (Cinematic) and
// can switch mid-session, so the cadence is learned from the deltas: a delta
// within +/-25% of the cadence is on time; a longer one counts the frames it
// skipped. A gap is committed only once an on-cadence frame follows it, so a
// run of kRelockIntervals consistent off-cadence deltas is taken as a cadence
// change instead, and those deltas are not counted as gaps.
class SourceGapCounter final {
public:
    static constexpr uint32_t kRelockIntervals = 8;

    void OnTimestamp(uint64_t sourceUs) {
        if (!has_last_ || sourceUs <= last_us_) {
            // First frame, or a duplicate or backwards stamp: not a gap.
            has_last_ = true;
            last_us_ = sourceUs;
            return;
        }
        const uint64_t delta = sourceUs - last_us_;
        last_us_ = sourceUs;
        if (cadence_us_ == 0) {
            cadence_us_ = delta;
            return;
        }
        if (Within(delta, cadence_us_)) {
            Commit();
            return;
        }
        if (run_ > 0 && Within(delta, run_us_)) {
            ++run_;
        } else {
            Commit();
            run_ = 1;
            run_us_ = delta;
        }
        if (delta > cadence_us_ + cadence_us_ / 2) {
            pending_gaps_ = SaturatingAdd(pending_gaps_, RoundedFrames(delta) - 1);
        }
        if (run_ >= kRelockIntervals) {
            cadence_us_ = run_us_;
            pending_gaps_ = 0;
            run_ = 0;
        }
    }

    uint64_t GapFrames() const { return gaps_; }
    uint64_t CadenceUs() const { return cadence_us_; }

private:
    static bool Within(uint64_t value, uint64_t reference) {
        return value >= reference - reference / 4 && value <= reference + reference / 4;
    }
    static uint64_t SaturatingAdd(uint64_t a, uint64_t b) {
        return a > UINT64_MAX - b ? UINT64_MAX : a + b;
    }
    // delta / cadence rounded to nearest, without overflow for any delta.
    uint64_t RoundedFrames(uint64_t delta) const {
        return delta / cadence_us_ + (delta % cadence_us_ >= (cadence_us_ + 1) / 2 ? 1 : 0);
    }
    void Commit() {
        gaps_ = SaturatingAdd(gaps_, pending_gaps_);
        pending_gaps_ = 0;
        run_ = 0;
    }

    bool has_last_ = false;
    uint64_t last_us_ = 0;
    uint64_t cadence_us_ = 0;
    uint64_t run_us_ = 0;
    uint32_t run_ = 0;
    uint64_t pending_gaps_ = 0;
    uint64_t gaps_ = 0;
};
