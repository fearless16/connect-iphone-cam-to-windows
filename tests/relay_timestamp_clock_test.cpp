#include <cassert>
#include <cstdint>

#include "relay_timestamp.h"

int main() {
    RelayTimestampClock clock;

    assert(clock.Rebase(1'000'000) == 0);
    assert(clock.Rebase(1'016'667) == 16'667);

    // Simulate a camera/encoder recovery whose source clock restarts lower.
    // The relay must advance one frame instead of underflowing uint64_t.
    assert(clock.Rebase(250) == 33'334);
    assert(clock.Rebase(16'917) == 50'001);

    // A duplicate timestamp is handled the same way and cannot regress PTS.
    assert(clock.Rebase(16'917) == 66'668);
    return 0;
}
