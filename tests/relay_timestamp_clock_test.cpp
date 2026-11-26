#include <cassert>
#include <cstdint>

#include "relay_timestamp.h"

int main() {
    static_assert(kNominalFrameDurationUs == 16'667, "one 60 fps frame");

    // G5: the relay timeline follows PC arrival time.
    ArrivalTimestampClock arrival;
    assert(arrival.Stamp(5'000'000) == 0);                 // the first value is 0
    assert(arrival.Stamp(5'016'667) == 16'667);            // spacing preserved
    assert(arrival.Stamp(5'016'667) == 16'668);            // identical arrival: +1 us
    assert(arrival.Stamp(5'016'667) == 16'669);
    assert(arrival.Stamp(5'000'100) == 16'670);            // earlier arrival never regresses
    assert(arrival.Stamp(4'000'000) == 16'671);            // before the origin: no underflow
    assert(arrival.Stamp(5'316'667) == 316'667);           // a stall gap is preserved
    // The origin is never reset: a phone reconnect 2 s later is a 2 s gap.
    assert(arrival.Stamp(7'316'667) == 2'316'667);

    // Strictly increasing over a long run of mixed arrivals.
    ArrivalTimestampClock mixed;
    uint64_t previous = mixed.Stamp(1'000);
    for (uint64_t i = 1; i < 100'000; ++i) {
        const uint64_t now = 1'000 + i * 16'667 - (i % 7 == 0 ? 40'000 : 0);
        const uint64_t stamped = mixed.Stamp(now);
        assert(stamped > previous);
        previous = stamped;
    }

    // An idle receiver: a 10-hour gap between sessions advances by
    // kMaxGapUs only, and the next frames keep their real spacing.
    ArrivalTimestampClock idle;
    assert(idle.Stamp(1'000'000) == 0);
    assert(idle.Stamp(1'016'667) == 16'667);
    const uint64_t tenHours = 10ull * 3600 * 1'000'000;
    const uint64_t resumed = idle.Stamp(1'016'667 + tenHours);
    assert(resumed == 16'667 + ArrivalTimestampClock::kMaxGapUs);
    assert(idle.Stamp(1'033'334 + tenHours) == resumed + 16'667);
    // A gap at the limit is kept exactly.
    ArrivalTimestampClock edge;
    assert(edge.Stamp(0) == 0);
    assert(edge.Stamp(ArrivalTimestampClock::kMaxGapUs) == ArrivalTimestampClock::kMaxGapUs);

    // Values near UINT64_MAX / 2 do not overflow.
    ArrivalTimestampClock large;
    const uint64_t base = UINT64_MAX / 2;
    assert(large.Stamp(base) == 0);
    assert(large.Stamp(base + 16'667) == 16'667);
    assert(large.Stamp(base + 16'667) == 16'668);
    assert(large.Stamp(base - 1) == 16'669);
    return 0;
}
