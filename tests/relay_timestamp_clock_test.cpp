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
    return 0;
}
