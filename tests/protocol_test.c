#include "../protocol/stream_protocol.h"
#include <stdio.h>
#include <assert.h>

int main(void) {
    uint8_t buf[STREAM_HEADER_SIZE];
    stream_header_write(buf, 7, 123456789ULL, STREAM_CODEC_HEVC, 1024);

    assert(stream_magic_match(buf));
    stream_header_t *h = (stream_header_t *)buf;
    assert(h->magic == STREAM_MAGIC);
    assert(h->frame_number == 7);
    assert(h->frame_size == 1024);
    assert(h->codec == STREAM_CODEC_HEVC);

    // Negative: corrupt magic -> must not match.
    uint8_t bad[STREAM_HEADER_SIZE];
    stream_header_write(bad, 1, 0, STREAM_CODEC_HEVC, 1);
    bad[0] ^= 0xFF;
    assert(!stream_magic_match(bad));

    printf("protocol_test.c: OK\n");
    return 0;
}
