#include <cassert>
#include <cstdint>
#include <vector>

#include "frame_store.h"

int main() {
    LatestFrameStore store(4);
    uint8_t output[4] = {};
    assert(!store.copyLatest(output, sizeof(output)));

    const uint8_t first[] = {1, 2, 3, 4};
    store.publish(first, sizeof(first));
    uint64_t generation = 0;
    assert(store.copyLatest(output, sizeof(output), &generation));
    assert(generation == 1);
    assert(output[0] == 1 && output[3] == 4);

    const uint8_t second[] = {5, 6, 7, 8};
    store.publish(second, sizeof(second));
    assert(store.copyLatest(output, sizeof(output), &generation));
    assert(generation == 2);
    assert(output[0] == 5 && output[3] == 8);
    return 0;
}
