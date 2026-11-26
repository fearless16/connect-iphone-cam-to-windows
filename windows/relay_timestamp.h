#pragma once

#include <cstdint>

// Converts sender timestamps into a relay-local, nondecreasing microsecond
// clock. Source timestamps may restart after a camera/encoder recovery; do
// not subtract them as unsigned values in the MPEG-TS relay.
class RelayTimestampClock final {
public:
    static constexpr uint64_t kFrameDurationUs = 16'667;

    // A phone reconnect starts a new source-timestamp domain, while OBS keeps
    // consuming the same relay timeline. Preserve the relay position and make
    // the first frame of the new session advance by one nominal frame.
    void BeginSession() {
        has_source_timestamp_ = false;
    }

    uint64_t Rebase(uint64_t timestampUs) {
        if (!has_source_timestamp_) {
            has_source_timestamp_ = true;
            last_source_timestamp_us_ = timestampUs;
            if (has_relay_timestamp_) {
                relative_us_ += kFrameDurationUs;
            } else {
                has_relay_timestamp_ = true;
            }
            return relative_us_;
        }
        if (timestampUs <= last_source_timestamp_us_) {
            relative_us_ += kFrameDurationUs;
        } else {
            relative_us_ += timestampUs - last_source_timestamp_us_;
        }
        last_source_timestamp_us_ = timestampUs;
        return relative_us_;
    }

private:
    bool has_source_timestamp_ = false;
    bool has_relay_timestamp_ = false;
    uint64_t last_source_timestamp_us_ = 0;
    uint64_t relative_us_ = 0;
};

// G5: the relay timeline follows PC arrival time, not the phone clock. OBS
// schedules Media Source frames by PTS, so a phone clock that runs fast against
// the PC (crystals differ by tens of ppm) would add delay that OBS never drains
// over a long stream, and a queued burst would stay late. Arrival time is one
// continuous PC clock, so the origin is never reset between phone sessions:
// a reconnect simply shows up as a gap.
class ArrivalTimestampClock final {
public:
    // Returns microseconds since the first stamped frame, strictly increasing.
    uint64_t Stamp(uint64_t arrivalUs) {
        if (!has_origin_) {
            has_origin_ = true;
            origin_us_ = arrivalUs;
            last_us_ = 0;
            return 0;
        }
        const uint64_t relative = arrivalUs > origin_us_ ? arrivalUs - origin_us_ : 0;
        last_us_ = relative > last_us_ ? relative : last_us_ + 1;
        return last_us_;
    }

private:
    bool has_origin_ = false;
    uint64_t origin_us_ = 0;
    uint64_t last_us_ = 0;
};
