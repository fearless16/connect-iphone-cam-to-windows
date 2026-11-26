#include <cassert>
#include <cstdint>
#include <string>

#include "crash_report.h"

using namespace crash_report;

static void Header(uint8_t out[kHeaderSize], const char* magic, uint32_t length) {
    for (int i = 0; i < 4; ++i) out[i] = static_cast<uint8_t>(magic[i]);
    out[4] = static_cast<uint8_t>(length);
    out[5] = static_cast<uint8_t>(length >> 8);
    out[6] = static_cast<uint8_t>(length >> 16);
    out[7] = static_cast<uint8_t>(length >> 24);
}

int main() {
    uint8_t h[kHeaderSize];

    // Golden bytes the Swift side produces for a 7-byte payload.
    const uint8_t golden[kHeaderSize] = {0x49, 0x43, 0x52, 0x50, 7, 0, 0, 0};
    auto parsed = ParseHeader(golden);
    assert(parsed && *parsed == 7);

    Header(h, "ICRP", 1);
    assert(ParseHeader(h) && *ParseHeader(h) == 1);
    Header(h, "ICRP", kMaxPayloadBytes);
    assert(ParseHeader(h) && *ParseHeader(h) == kMaxPayloadBytes);
    Header(h, "ICRP", 0x01020304 & 0x3FFFF);  // multi-byte length is read little-endian
    assert(ParseHeader(h) && *ParseHeader(h) == (0x01020304u & 0x3FFFF));

    Header(h, "ICRP", 0);
    assert(!ParseHeader(h));                       // empty
    Header(h, "ICRP", kMaxPayloadBytes + 1);
    assert(!ParseHeader(h));                       // over the cap
    Header(h, "ICRP", 0xFFFFFFFFu);
    assert(!ParseHeader(h));                       // never allocate for this
    Header(h, "XCRP", 10);
    assert(!ParseHeader(h));                       // wrong magic
    Header(h, "icrp", 10);
    assert(!ParseHeader(h));                       // magic is case-sensitive

    assert(kPort == 12347);
    assert(kAck == 0x06);
    assert(FileName(2026, 11, 26, 9, 5, 7) == "crash-20261126-090507.json");
    // Out-of-range values cannot produce path separators or a long name.
    assert(FileName(123456, 99, 99, 99, 99, 99).size() == std::string("crash-00000000-000000.json").size());
    return 0;
}
