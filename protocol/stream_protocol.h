#ifndef STREAM_PROTOCOL_H
#define STREAM_PROTOCOL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Wire protocol: one Annex-B encoded frame per packet.
 * All multi-byte integers are little-endian. No JSON, no protobuf. */

#define STREAM_MAGIC       0x4950434DUL  /* ASCII "IPCM" */
#define STREAM_MAGIC_SIZE  4
#define STREAM_HEADER_SIZE 21            /* magic(4)+frame(4)+ts(8)+codec(1)+size(4) */
/* A corrupted header must not make the receiver allocate arbitrary memory.
 * 16 MiB leaves ample room for an intra 4K HEVC frame at the configured bitrate. */
#define STREAM_MAX_FRAME_SIZE (16U * 1024U * 1024U)

typedef enum {
    STREAM_CODEC_HEVC = 0,
    STREAM_CODEC_H264 = 1
} stream_codec_t;

/* Packed header written before every frame's encoded bytes. */
#if defined(_MSC_VER)
#pragma pack(push, 1)
#define STREAM_PACKED
#else
#define STREAM_PACKED __attribute__((packed))
#endif
typedef struct STREAM_PACKED {
    uint32_t      magic;        /* STREAM_MAGIC */
    uint32_t      frame_number; /* monotonically increasing */
    uint64_t      timestamp_us; /* CLOCK_MONOTONIC / mach_absolute_time in us */
    uint8_t       codec;        /* stream_codec_t */
    uint32_t      frame_size;   /* size of the encoded frame that follows */
} stream_header_t;
#if defined(_MSC_VER)
#pragma pack(pop)
#endif
#undef STREAM_PACKED

/* Helper: build a header in a caller-owned buffer (STREAM_HEADER_SIZE bytes). */
static inline void stream_header_write(uint8_t *out,
                                       uint32_t frame_number,
                                       uint64_t timestamp_us,
                                       uint8_t codec,
                                       uint32_t frame_size)
{
    out[0] = (uint8_t)(STREAM_MAGIC & 0xFF);
    out[1] = (uint8_t)((STREAM_MAGIC >> 8) & 0xFF);
    out[2] = (uint8_t)((STREAM_MAGIC >> 16) & 0xFF);
    out[3] = (uint8_t)((STREAM_MAGIC >> 24) & 0xFF);
    out[4] = (uint8_t)(frame_number & 0xFF);
    out[5] = (uint8_t)((frame_number >> 8) & 0xFF);
    out[6] = (uint8_t)((frame_number >> 16) & 0xFF);
    out[7] = (uint8_t)((frame_number >> 24) & 0xFF);
    out[8] = (uint8_t)(timestamp_us & 0xFF);
    out[9] = (uint8_t)((timestamp_us >> 8) & 0xFF);
    out[10] = (uint8_t)((timestamp_us >> 16) & 0xFF);
    out[11] = (uint8_t)((timestamp_us >> 24) & 0xFF);
    out[12] = (uint8_t)((timestamp_us >> 32) & 0xFF);
    out[13] = (uint8_t)((timestamp_us >> 40) & 0xFF);
    out[14] = (uint8_t)((timestamp_us >> 48) & 0xFF);
    out[15] = (uint8_t)((timestamp_us >> 56) & 0xFF);
    out[16] = (uint8_t)codec;
    out[17] = (uint8_t)(frame_size & 0xFF);
    out[18] = (uint8_t)((frame_size >> 8) & 0xFF);
    out[19] = (uint8_t)((frame_size >> 16) & 0xFF);
    out[20] = (uint8_t)((frame_size >> 24) & 0xFF);
}

/* Returns 1 if the first 4 bytes match STREAM_MAGIC, else 0. */
static inline int stream_magic_match(const uint8_t *buf)
{
    uint32_t m = (uint32_t)buf[0]
               | ((uint32_t)buf[1] << 8)
               | ((uint32_t)buf[2] << 16)
               | ((uint32_t)buf[3] << 24);
    return m == STREAM_MAGIC;
}

/* Decode explicitly instead of casting an unaligned network buffer to the
 * packed structure. Returns 0 for a bad magic value. */
static inline int stream_header_read(const uint8_t *buf, stream_header_t *out)
{
    if (!stream_magic_match(buf)) return 0;
    out->magic = STREAM_MAGIC;
    out->frame_number = (uint32_t)buf[4]
                      | ((uint32_t)buf[5] << 8)
                      | ((uint32_t)buf[6] << 16)
                      | ((uint32_t)buf[7] << 24);
    out->timestamp_us = (uint64_t)buf[8]
                      | ((uint64_t)buf[9] << 8)
                      | ((uint64_t)buf[10] << 16)
                      | ((uint64_t)buf[11] << 24)
                      | ((uint64_t)buf[12] << 32)
                      | ((uint64_t)buf[13] << 40)
                      | ((uint64_t)buf[14] << 48)
                      | ((uint64_t)buf[15] << 56);
    out->codec = buf[16];
    out->frame_size = (uint32_t)buf[17]
                    | ((uint32_t)buf[18] << 8)
                    | ((uint32_t)buf[19] << 16)
                    | ((uint32_t)buf[20] << 24);
    return 1;
}

static inline int stream_header_is_valid(const stream_header_t *header)
{
    return (header->codec == STREAM_CODEC_HEVC || header->codec == STREAM_CODEC_H264)
        && header->frame_size > 0
        && header->frame_size <= STREAM_MAX_FRAME_SIZE;
}

#ifdef __cplusplus
}
#endif

#endif /* STREAM_PROTOCOL_H */
