#include <cassert>
#include <cstdint>
#include <cstring>

#include "stream_protocol.h"

int main() {
    uint8_t wire[STREAM_HEADER_SIZE] = {};
    stream_header_write(wire, 42, 987654321ULL, STREAM_CODEC_HEVC, 1024);

    stream_header_t header = {};
    assert(stream_header_read(wire, &header));
    assert(header.magic == STREAM_MAGIC);
    assert(header.frame_number == 42);
    assert(header.timestamp_us == 987654321ULL);
    assert(header.codec == STREAM_CODEC_HEVC);
    assert(header.frame_size == 1024);
    assert(stream_header_is_valid(&header));

    wire[0] ^= 0xff;
    assert(!stream_header_read(wire, &header));

    stream_header_write(wire, 1, 1, 99, 1024);
    assert(stream_header_read(wire, &header));
    assert(!stream_header_is_valid(&header));

    stream_header_write(wire, 1, 1, STREAM_CODEC_HEVC, STREAM_MAX_FRAME_SIZE + 1);
    assert(stream_header_read(wire, &header));
    assert(!stream_header_is_valid(&header));
    return 0;
}
