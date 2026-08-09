#pragma once

#include <cstddef>
#include <cstdint>

struct HevcAccessUnitInfo final {
    bool hasVps = false;
    bool hasSps = false;
    bool hasPps = false;
    bool hasIdr = false;

    bool IsDecoderJoinPoint() const {
        return hasVps && hasSps && hasPps && hasIdr;
    }
};

// Inspects Annex-B NAL units in one encoded access unit. A decoder joining a
// live HEVC stream needs all parameter sets and an IDR in that same unit.
inline HevcAccessUnitInfo InspectHevcAccessUnit(const uint8_t* data, size_t size) {
    HevcAccessUnitInfo info{};
    if (!data) return info;

    size_t offset = 0;
    while (offset + 3 < size) {
        size_t prefixSize = 0;
        if (offset + 4 < size && data[offset] == 0 && data[offset + 1] == 0 &&
            data[offset + 2] == 0 && data[offset + 3] == 1) {
            prefixSize = 4;
        } else if (data[offset] == 0 && data[offset + 1] == 0 && data[offset + 2] == 1) {
            prefixSize = 3;
        }
        if (!prefixSize) {
            ++offset;
            continue;
        }

        const size_t nalOffset = offset + prefixSize;
        if (nalOffset + 1 >= size) break;
        const uint8_t nalType = (data[nalOffset] >> 1) & 0x3f;
        switch (nalType) {
            case 32: info.hasVps = true; break;
            case 33: info.hasSps = true; break;
            case 34: info.hasPps = true; break;
            case 19:
            case 20: info.hasIdr = true; break;
            default: break;
        }
        offset = nalOffset + 2;
    }
    return info;
}
