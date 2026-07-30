#pragma once

// GPU-only hand-off between the USB/HEVC receiver and the Media Foundation
// source loaded by Windows Frame Server. No pixels belong in this mapping:
// 4K NV12 at 60 fps is roughly 746 MB/s before any extra copies.
#include <cstdint>
#include <windows.h>

namespace iphone_camera::gpu_transport {

inline constexpr wchar_t kControlMappingName[] =
    L"Local\\IPhoneCameraStream.GpuFrames.v1";
inline constexpr uint32_t kMagic = 0x46435049; // "IPCF", little-endian
inline constexpr uint16_t kVersion = 1;
inline constexpr uint32_t kSlotCount = 4;

// Producer and consumer must use a device created on this adapter LUID. The
// source rejects a mismatch instead of silently downloading frames to RAM.
struct AdapterIdentity {
    int32_t low_part;
    int32_t high_part;
};

struct FrameSlot {
    // Duplicated into the Frame Server process with DuplicateHandle. It names
    // an NV12 D3D11 texture created with SHARED_KEYEDMUTEX.
    uint64_t shared_texture_handle;
    uint64_t producer_key;
    uint64_t consumer_key;
    int64_t timestamp_100ns;
    int64_t duration_100ns;
    uint64_t sequence;
};

struct ControlBlock {
    uint32_t magic;
    uint16_t version;
    uint16_t size;
    AdapterIdentity adapter;
    uint32_t width;
    uint32_t height;
    uint32_t frame_rate_numerator;
    uint32_t frame_rate_denominator;
    volatile uint64_t latest_sequence;
    volatile uint32_t producer_pid;
    volatile uint32_t generation;
    FrameSlot slots[kSlotCount];
};

static_assert(sizeof(FrameSlot) == 48, "wire layout must stay stable");

inline bool valid(const ControlBlock& block) noexcept {
    return block.magic == kMagic && block.version == kVersion &&
        block.size == sizeof(ControlBlock) && block.width == 3840 &&
        block.height == 2160 && block.frame_rate_numerator == 60 &&
        block.frame_rate_denominator == 1;
}

} // namespace iphone_camera::gpu_transport
