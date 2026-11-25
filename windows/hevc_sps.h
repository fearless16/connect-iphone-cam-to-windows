#pragma once

#include <cstddef>
#include <cstdint>

// Reads the coded picture size out of an HEVC SPS (H.265 section 7.3.2.2).
// Pure logic: no allocation, no I/O, never reads outside [nal, nal + size).

namespace hevc_sps_detail {

// MSB-first bit reader that removes emulation-prevention bytes (00 00 03)
// while reading, so the SPS needs no copy.
class BitReader final {
public:
    BitReader(const uint8_t* data, size_t size) : data_(data), size_(size) {}

    bool ReadBit(uint32_t* bit) {
        if (bitsLeft_ == 0 && !LoadByte()) return false;
        --bitsLeft_;
        *bit = (current_ >> bitsLeft_) & 1u;
        return true;
    }

    bool ReadBits(unsigned count, uint32_t* value) {
        uint32_t result = 0;
        for (unsigned i = 0; i < count; ++i) {
            uint32_t bit = 0;
            if (!ReadBit(&bit)) return false;
            result = (result << 1) | bit;
        }
        *value = result;
        return true;
    }

    bool Skip(unsigned count) {
        uint32_t bit = 0;
        for (unsigned i = 0; i < count; ++i) {
            if (!ReadBit(&bit)) return false;
        }
        return true;
    }

    // Exp-Golomb ue(v). Fails if the prefix is longer than 31 zero bits.
    bool ReadUe(uint32_t* value) {
        unsigned zeros = 0;
        uint32_t bit = 0;
        for (;;) {
            if (!ReadBit(&bit)) return false;
            if (bit) break;
            if (++zeros > 31) return false;
        }
        uint32_t suffix = 0;
        if (zeros > 0 && !ReadBits(zeros, &suffix)) return false;
        *value = ((1u << zeros) - 1u) + suffix;
        return true;
    }

private:
    bool LoadByte() {
        if (pos_ >= size_) return false;
        uint8_t byte = data_[pos_++];
        if (zeroRun_ >= 2 && byte == 0x03) {
            zeroRun_ = 0;
            if (pos_ >= size_) return false;
            byte = data_[pos_++];
        }
        zeroRun_ = byte == 0 ? (zeroRun_ < 2 ? zeroRun_ + 1 : 2) : 0;
        current_ = byte;
        bitsLeft_ = 8;
        return true;
    }

    const uint8_t* data_;
    size_t size_;
    size_t pos_ = 0;
    uint32_t current_ = 0;
    unsigned bitsLeft_ = 0;
    unsigned zeroRun_ = 0;
};

}  // namespace hevc_sps_detail

// Parses one SPS NAL unit (starting at its 2-byte NAL header, no start code).
// Returns false on any malformed or truncated input. Never reads out of bounds.
inline bool HevcSpsDimensions(const uint8_t* nal, size_t size, int* width, int* height) {
    if (!nal || !width || !height || size < 2) return false;
    if (((nal[0] >> 1) & 0x3f) != 33) return false;

    hevc_sps_detail::BitReader reader(nal, size);
    uint32_t value = 0;
    if (!reader.Skip(16)) return false;  // NAL header
    if (!reader.Skip(4)) return false;   // sps_video_parameter_set_id

    uint32_t maxSubLayersMinus1 = 0;
    if (!reader.ReadBits(3, &maxSubLayersMinus1) || maxSubLayersMinus1 > 6) return false;
    if (!reader.Skip(1)) return false;   // sps_temporal_id_nesting_flag

    // profile_tier_level(1, sps_max_sub_layers_minus1)
    if (!reader.Skip(96)) return false;  // 88 general profile bits + general_level_idc
    bool profilePresent[6] = {};
    bool levelPresent[6] = {};
    for (uint32_t i = 0; i < maxSubLayersMinus1; ++i) {
        if (!reader.ReadBits(1, &value)) return false;
        profilePresent[i] = value != 0;
        if (!reader.ReadBits(1, &value)) return false;
        levelPresent[i] = value != 0;
    }
    if (maxSubLayersMinus1 > 0 && !reader.Skip(2 * (8 - maxSubLayersMinus1))) return false;
    for (uint32_t i = 0; i < maxSubLayersMinus1; ++i) {
        if (profilePresent[i] && !reader.Skip(88)) return false;
        if (levelPresent[i] && !reader.Skip(8)) return false;
    }

    if (!reader.ReadUe(&value)) return false;  // sps_seq_parameter_set_id
    uint32_t chromaFormatIdc = 0;
    if (!reader.ReadUe(&chromaFormatIdc) || chromaFormatIdc > 3) return false;
    if (chromaFormatIdc == 3 && !reader.Skip(1)) return false;  // separate_colour_plane_flag

    uint32_t picWidth = 0;
    uint32_t picHeight = 0;
    if (!reader.ReadUe(&picWidth) || !reader.ReadUe(&picHeight)) return false;

    uint32_t cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0;
    uint32_t conformanceWindowFlag = 0;
    if (!reader.ReadBits(1, &conformanceWindowFlag)) return false;
    if (conformanceWindowFlag &&
        (!reader.ReadUe(&cropLeft) || !reader.ReadUe(&cropRight) ||
         !reader.ReadUe(&cropTop) || !reader.ReadUe(&cropBottom))) {
        return false;
    }

    int64_t subWidthC = 1;
    int64_t subHeightC = 1;
    if (chromaFormatIdc == 1) {
        subWidthC = 2;
        subHeightC = 2;
    } else if (chromaFormatIdc == 2) {
        subWidthC = 2;
    }
    const int64_t croppedWidth =
        static_cast<int64_t>(picWidth) - subWidthC * (static_cast<int64_t>(cropLeft) + cropRight);
    const int64_t croppedHeight =
        static_cast<int64_t>(picHeight) - subHeightC * (static_cast<int64_t>(cropTop) + cropBottom);
    if (croppedWidth < 16 || croppedWidth > 16384) return false;
    if (croppedHeight < 16 || croppedHeight > 16384) return false;
    *width = static_cast<int>(croppedWidth);
    *height = static_cast<int>(croppedHeight);
    return true;
}

// Finds the first SPS (NAL type 33) in an Annex-B access unit and parses it.
inline bool HevcAccessUnitDimensions(const uint8_t* au, size_t size, int* width, int* height) {
    if (!au || !width || !height) return false;

    size_t offset = 0;
    while (offset + 3 < size) {
        size_t prefixSize = 0;
        if (offset + 4 < size && au[offset] == 0 && au[offset + 1] == 0 &&
            au[offset + 2] == 0 && au[offset + 3] == 1) {
            prefixSize = 4;
        } else if (au[offset] == 0 && au[offset + 1] == 0 && au[offset + 2] == 1) {
            prefixSize = 3;
        }
        if (!prefixSize) {
            ++offset;
            continue;
        }

        const size_t nalOffset = offset + prefixSize;
        if (nalOffset + 1 >= size) break;
        const uint8_t nalType = (au[nalOffset] >> 1) & 0x3f;
        if (nalType != 33) {
            offset = nalOffset + 2;
            continue;
        }
        // Emulation prevention guarantees 00 00 01 never occurs inside a NAL
        // unit, so the next start code (or the end) bounds this SPS.
        size_t end = nalOffset + 2;
        while (end + 2 < size && !(au[end] == 0 && au[end + 1] == 0 && au[end + 2] == 1)) {
            ++end;
        }
        if (end + 2 >= size) end = size;
        return HevcSpsDimensions(au + nalOffset, end - nalOffset, width, height);
    }
    return false;
}
