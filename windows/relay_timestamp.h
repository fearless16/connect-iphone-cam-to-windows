#pragma once

#include <cstdint>

// Converts sender timestamps into a relay-local, nondecreasing microsecond
// clock. Source timestamps may restart after a camera/encoder recovery; do
// not subtract them as unsigned values in the MPEG-TS relay.
class RelayTimestampClock final {
public:
    static constexpr uint64_t kFrameDurationUs = 16'667;

    uint64_t Rebase(uint64_t timestampUs) {
        if (!has_source_timestamp_) {
            has_source_timestamp_ = true;
            last_source_timestamp_us_ = timestampUs;
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
    uint64_t last_source_timestamp_us_ = 0;
    uint64_t relative_us_ = 0;
};
