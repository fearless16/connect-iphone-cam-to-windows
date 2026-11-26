// Pure validation of Bonjour (DNS-SD) data for Wi-Fi discovery (T3.3).
// Everything a LAN peer announces is untrusted: check it before connecting.
// C++ standard headers only (R-ARCH-4); the Windows DNS-SD calls live in
// receiver.cpp.
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace wifi_discovery {

inline constexpr std::string_view kServiceType = "_ipcamstream._tcp";
inline constexpr std::string_view kBrowseName = "_ipcamstream._tcp.local";
inline constexpr size_t kMaxNameBytes = 255;  // DNS name limit

// True for "<instance>._ipcamstream._tcp.local" with a non-empty, printable
// ASCII instance part. Rejects anything else the network might hand us.
inline bool IsServiceInstanceName(std::string_view name) {
    constexpr std::string_view suffix = ".local";
    if (name.empty() || name.size() > kMaxNameBytes) return false;
    for (const char c : name) {
        const auto u = static_cast<unsigned char>(c);
        if (u < 0x20 || u > 0x7E) return false;
    }
    const std::string full = std::string(".") + std::string(kServiceType) + std::string(suffix);
    if (name.size() <= full.size()) return false;  // needs a non-empty instance
    return name.substr(name.size() - full.size()) == full;
}

// Returns the dotted-quad for a resolved endpoint, or nothing when the port is
// not the expected one or the address is not a usable unicast LAN address.
inline std::optional<std::string> FormatEndpoint(const uint8_t octets[4], uint16_t port,
                                                 uint16_t expectedPort) {
    if (port != expectedPort) return std::nullopt;
    if (octets[0] == 0 || octets[0] == 127 || octets[0] >= 224) return std::nullopt;
    return std::to_string(octets[0]) + "." + std::to_string(octets[1]) + "." +
           std::to_string(octets[2]) + "." + std::to_string(octets[3]);
}

}  // namespace wifi_discovery
