#include "../protocol/stream_protocol.h"
#include <stdio.h>
#include <time.h>

/* Micro-benchmark: header pack/unpack throughput. No allocation in the loop. */
int main(void) {
    uint8_t buf[STREAM_HEADER_SIZE];
    const int N = 5_000_000;
    clock_t t0 = clock();
    for (int i = 0; i < N; i++) {
        stream_header_write(buf, (uint32_t)i, (uint64_t)i, STREAM_CODEC_HEVC, (uint32_t)i);
        uint32_t m = (uint32_t)buf[0] | ((uint32_t)buf[1] << 8) |
                     ((uint32_t)buf[2] << 16) | ((uint32_t)buf[3] << 24);
        if (m != STREAM_MAGIC) return 1;
    }
    clock_t t1 = clock();
    double secs = (double)(t1 - t0) / CLOCKS_PER_SEC;
    printf("protocol_bench: %d headers in %.3fs = %.1f Mops/s\n", N, secs, N / secs / 1e6);
    return 0;
}
