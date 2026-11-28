#pragma once

#include <cstdint>

// Nominal duration of one 60 fps frame. Used for the MPEG-TS packet duration
// and the OBS TCP timeline step; it never sets a timestamp. Source gaps are
// counted by SourceGapCounter (stream_timing.h), which learns the cadence.
constexpr uint64_t kNominalFrameDurationUs = 16'667;

// G5: the relay timeline follows PC arrival time, not the phone clock. OBS
// schedules Media Source frames by PTS, so a phone clock that runs fast against
// the PC (crystals differ by tens of ppm) would add delay that OBS never drains
// over a long stream, and a queued burst would stay late. Arrival time is one
// continuous PC clock, so the origin is never reset between phone sessions:
// a reconnect simply shows up as a gap.
//
// A gap longer than kMaxGapUs (the receiver idled between sessions, maybe for
// hours) advances the timeline by kMaxGapUs only. OBS resets its schedule on
// any jump over 3 s anyway, and this keeps PTS growing with streamed time, not
// with how long the receiver has been running (33-bit MPEG-TS PTS wraps after
// 26.5 h).
class ArrivalTimestampClock final {
public:
    static constexpr uint64_t kMaxGapUs = 2'000'000;

    // Returns microseconds since the first stamped frame, strictly increasing.
    uint64_t Stamp(uint64_t arrivalUs) {
        if (!has_origin_) {
            has_origin_ = true;
            origin_us_ = arrivalUs;
            last_us_ = 0;
            return 0;
        }
        const uint64_t relative = arrivalUs > origin_us_ ? arrivalUs - origin_us_ : 0;
        if (relative > last_us_ + kMaxGapUs) {
            // Move the origin forward so this frame lands kMaxGapUs after the
            // last one; later frames keep their real spacing from here.
            origin_us_ += relative - (last_us_ + kMaxGapUs);
            last_us_ += kMaxGapUs;
            return last_us_;
        }
        last_us_ = relative > last_us_ ? relative : last_us_ + 1;
        return last_us_;
    }

private:
    bool has_origin_ = false;
    uint64_t origin_us_ = 0;
    uint64_t last_us_ = 0;
};
