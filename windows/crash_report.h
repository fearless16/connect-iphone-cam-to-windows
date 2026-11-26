// Pure parsing for the crash-report side channel (T6.1, phone port 12347).
// This is not the video wire format. The phone sends: magic "ICRP", u32
// little-endian payload length, JSON payload. The receiver validates the header
// before allocating (R-ENG-INPUT) and answers with one ack byte after saving.
// C++ standard headers only (R-ARCH-4).
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <optional>
#include <string>

namespace crash_report {

inline constexpr uint16_t kPort = 12347;
inline constexpr size_t kHeaderSize = 8;
inline constexpr uint32_t kMaxPayloadBytes = 256 * 1024;
inline constexpr uint8_t kAck = 0x06;

// Returns the payload length, or nothing when the magic is wrong or the length
// is zero or above the cap.
inline std::optional<uint32_t> ParseHeader(const uint8_t header[kHeaderSize]) {
    if (header[0] != 'I' || header[1] != 'C' || header[2] != 'R' || header[3] != 'P') {
        return std::nullopt;
    }
    const uint32_t length = static_cast<uint32_t>(header[4]) |
                            (static_cast<uint32_t>(header[5]) << 8) |
                            (static_cast<uint32_t>(header[6]) << 16) |
                            (static_cast<uint32_t>(header[7]) << 24);
    if (length == 0 || length > kMaxPayloadBytes) return std::nullopt;
    return length;
}

// "crash-YYYYMMDD-HHMMSS.json": sorts by time and is always a safe file name.
inline std::string FileName(int year, int month, int day, int hour, int minute, int second) {
    char buffer[40];
    std::snprintf(buffer, sizeof(buffer), "crash-%04d%02d%02d-%02d%02d%02d.json",
                  year % 10000, month % 100, day % 100, hour % 100, minute % 100, second % 100);
    return buffer;
}

}  // namespace crash_report
