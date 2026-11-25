#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "hevc_sps.h"

namespace {

struct Golden {
    const char* name;
    int width;
    int height;
    const char* hex;
};

// SPS NAL units (NAL header first, no start code) from
// `ffmpeg -f lavfi -i testsrc2=size=WxH:rate=60 -frames:v 1 -c:v libx265 -f hevc`.
const Golden kGolden[] = {
    {"1280x720", 1280, 720,
     "420101016000000300900000030000030078a00280802d165959a4932bc05a020000030002000003007810"},
    {"1920x1080", 1920, 1080,
     "42010101600000030090000003000003007ba003c08010e596566924caf0168080000003008000001e04"},
    {"3840x2160", 3840, 2160,
     "420101016000000300900000030000030099a001e020021c596566924caf016808000003000800000301e040"},
    {"2160x3840 portrait", 2160, 3840,
     "420101016000000300900000030000030099a0010e2003c0596566924caf016808000003000800000301e040"},
    {"1916x1076 conformance window crop", 1916, 1076,
     "42010101600000030090000003000003007ba003c08010e77796566924caf0168080000003008000001e04"},
    {"1920x1080 two temporal sub-layers", 1920, 1080,
     "42010201600000030090000003000003007b0000a003c08010e5965662b349265780b404000003000400000300f020"},
};

int HexNibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    assert(false && "bad hex digit");
    return 0;
}

std::vector<uint8_t> FromHex(const char* hex) {
    std::vector<uint8_t> bytes;
    for (const char* p = hex; p[0] && p[1]; p += 2) {
        bytes.push_back(static_cast<uint8_t>((HexNibble(p[0]) << 4) | HexNibble(p[1])));
    }
    return bytes;
}

void Append(std::vector<uint8_t>& out, const std::vector<uint8_t>& bytes) {
    out.insert(out.end(), bytes.begin(), bytes.end());
}

}  // namespace

int main() {
    // Every golden SPS parses to its known size.
    for (const Golden& golden : kGolden) {
        const std::vector<uint8_t> sps = FromHex(golden.hex);
        int width = 0;
        int height = 0;
        const bool ok = HevcSpsDimensions(sps.data(), sps.size(), &width, &height);
        if (!ok || width != golden.width || height != golden.height) {
            std::fprintf(stderr, "FAIL %s: ok=%d got %dx%d\n", golden.name, ok, width, height);
            return 1;
        }
    }

    // Truncated input never crashes and never reads past the end (run under
    // an address sanitizer to make that visible). The parser stops after the
    // conformance window, so a truncated SPS parses only once every field it
    // needs is present: there is one threshold length, and everything shorter
    // fails while everything at or above it gives the same size.
    for (const Golden& golden : kGolden) {
        const std::vector<uint8_t> sps = FromHex(golden.hex);
        size_t threshold = sps.size() + 1;
        for (size_t length = 0; length <= sps.size(); ++length) {
            // Copy into an exactly-sized heap block so a read past `length`
            // is out of bounds for the sanitizer, not just past the vector.
            std::vector<uint8_t> truncated(sps.begin(), sps.begin() + static_cast<long>(length));
            int width = 0;
            int height = 0;
            const bool ok = HevcSpsDimensions(truncated.data(), truncated.size(), &width, &height);
            if (ok && threshold > sps.size()) threshold = length;
            if (threshold > sps.size()) {
                assert(!ok);
            } else {
                assert(ok && width == golden.width && height == golden.height);
            }
        }
        // profile_tier_level alone is 15 bytes, so the fields after it need more.
        assert(threshold > 15 && threshold <= sps.size());
    }

    int width = -1;
    int height = -1;

    // Empty, null, and garbage input.
    assert(!HevcSpsDimensions(nullptr, 0, &width, &height));
    assert(!HevcSpsDimensions(nullptr, 64, &width, &height));
    {
        const std::vector<uint8_t> sps = FromHex(kGolden[1].hex);
        assert(!HevcSpsDimensions(sps.data(), 0, &width, &height));
        assert(!HevcSpsDimensions(sps.data(), 1, &width, &height));
        assert(!HevcSpsDimensions(sps.data(), sps.size(), nullptr, &height));
        assert(!HevcSpsDimensions(sps.data(), sps.size(), &width, nullptr));
    }
    {
        const std::vector<uint8_t> noise(64, 0xff);
        assert(!HevcSpsDimensions(noise.data(), noise.size(), &width, &height));
        const std::vector<uint8_t> zeros(64, 0x00);
        assert(!HevcSpsDimensions(zeros.data(), zeros.size(), &width, &height));
    }

    // A NAL unit that is not an SPS is rejected.
    {
        std::vector<uint8_t> notSps = FromHex(kGolden[1].hex);
        notSps[0] = 0x40;  // VPS, type 32
        assert(!HevcSpsDimensions(notSps.data(), notSps.size(), &width, &height));
    }

    // sps_max_sub_layers_minus1 > 6 is rejected.
    {
        std::vector<uint8_t> bad = FromHex(kGolden[1].hex);
        bad[2] = 0x0f;  // vps id 0, max_sub_layers_minus1 = 7, nesting flag 1
        assert(!HevcSpsDimensions(bad.data(), bad.size(), &width, &height));
    }

    // Access-unit scan: VPS, then the SPS, then PPS and IDR, with mixed
    // 4-byte and 3-byte start codes. The SPS ends at the next start code.
    const std::vector<uint8_t> vps = {0x40, 0x01, 0x0c, 0x01, 0xff};
    const std::vector<uint8_t> pps = {0x44, 0x01, 0xc1, 0x72};
    const std::vector<uint8_t> idr = {0x26, 0x01, 0xaf, 0x08};
    const std::vector<uint8_t> sps1080 = FromHex(kGolden[1].hex);
    const std::vector<uint8_t> sps4k = FromHex(kGolden[2].hex);
    const std::vector<uint8_t> start4 = {0, 0, 0, 1};
    const std::vector<uint8_t> start3 = {0, 0, 1};
    {
        std::vector<uint8_t> au;
        Append(au, start4);
        Append(au, vps);
        Append(au, start3);
        Append(au, sps1080);
        width = height = 0;
        assert(HevcAccessUnitDimensions(au.data(), au.size(), &width, &height));
        assert(width == 1920 && height == 1080);
    }
    {
        std::vector<uint8_t> au;
        Append(au, start4);
        Append(au, vps);
        Append(au, start4);
        Append(au, sps4k);
        Append(au, start3);
        Append(au, pps);
        Append(au, start4);
        Append(au, idr);
        width = height = 0;
        assert(HevcAccessUnitDimensions(au.data(), au.size(), &width, &height));
        assert(width == 3840 && height == 2160);
    }
    {
        // No SPS in the access unit.
        std::vector<uint8_t> au;
        Append(au, start4);
        Append(au, vps);
        Append(au, start4);
        Append(au, pps);
        Append(au, start4);
        Append(au, idr);
        assert(!HevcAccessUnitDimensions(au.data(), au.size(), &width, &height));
        assert(!HevcAccessUnitDimensions(au.data(), 0, &width, &height));
        assert(!HevcAccessUnitDimensions(nullptr, 0, &width, &height));
        assert(!HevcAccessUnitDimensions(au.data(), au.size(), nullptr, &height));
    }
    {
        // SPS cut off by the end of the access unit at every length.
        std::vector<uint8_t> au;
        Append(au, start4);
        Append(au, sps1080);
        for (size_t length = 0; length <= au.size(); ++length) {
            std::vector<uint8_t> truncated(au.begin(), au.begin() + static_cast<long>(length));
            int w = 0;
            int h = 0;
            if (HevcAccessUnitDimensions(truncated.data(), truncated.size(), &w, &h)) {
                assert(w == 1920 && h == 1080);
            }
        }
    }

    std::puts("hevc_sps_test passed");
    return 0;
}
