#include <cassert>
#include <cstdint>

#include "relay_timestamp.h"

int main() {
    RelayTimestampClock clock;

    clock.BeginSession();

    assert(clock.Rebase(1'000'000) == 0);
    assert(clock.Rebase(1'016'667) == 16'667);

    // Simulate a camera/encoder recovery whose source clock restarts lower.
    // The relay must advance one frame instead of underflowing uint64_t.
    assert(clock.Rebase(250) == 33'334);
    assert(clock.Rebase(16'917) == 50'001);

    // A duplicate timestamp is handled the same way and cannot regress PTS.
    assert(clock.Rebase(16'917) == 66'668);

    // A new iPhone connection is a new source-timestamp session, but OBS keeps
    // consuming the same MPEG-TS timeline. Even when the phone restarts at
    // zero, the first mux timestamp in session B must advance strictly past A.
    const uint64_t lastSessionATimestamp = clock.Rebase(33'584);
    clock.BeginSession();
    const uint64_t firstSessionBTimestamp = clock.Rebase(0);
    assert(firstSessionBTimestamp > lastSessionATimestamp);
    assert(clock.Rebase(16'667) > firstSessionBTimestamp);

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

    // Values near UINT64_MAX / 2 do not overflow.
    ArrivalTimestampClock large;
    const uint64_t base = UINT64_MAX / 2;
    assert(large.Stamp(base) == 0);
    assert(large.Stamp(base + 16'667) == 16'667);
    assert(large.Stamp(base + 16'667) == 16'668);
    assert(large.Stamp(base - 1) == 16'669);
    return 0;
}
