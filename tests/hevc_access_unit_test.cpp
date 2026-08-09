#include <cassert>
#include <cstdint>
#include <vector>

#include "hevc_access_unit.h"

static void AppendNal(std::vector<uint8_t>& accessUnit, uint8_t type,
                      bool fourByteStartCode = true) {
    if (fourByteStartCode) accessUnit.push_back(0);
    accessUnit.push_back(0);
    accessUnit.push_back(0);
    accessUnit.push_back(1);
    accessUnit.push_back(static_cast<uint8_t>(type << 1));
    accessUnit.push_back(1);
    accessUnit.push_back(0xaa);
}

int main() {
    std::vector<uint8_t> idrOnly;
    AppendNal(idrOnly, 19);
    const HevcAccessUnitInfo idrOnlyInfo = InspectHevcAccessUnit(idrOnly.data(), idrOnly.size());
    assert(idrOnlyInfo.hasIdr);
    assert(!idrOnlyInfo.IsDecoderJoinPoint());

    // Parameter sets can legally appear in any order within the access unit.
    std::vector<uint8_t> mixedOrder;
    AppendNal(mixedOrder, 20, false);
    AppendNal(mixedOrder, 34);
    AppendNal(mixedOrder, 32, false);
    AppendNal(mixedOrder, 33);
    const HevcAccessUnitInfo mixedInfo = InspectHevcAccessUnit(mixedOrder.data(), mixedOrder.size());
    assert(mixedInfo.hasIdr && mixedInfo.hasVps && mixedInfo.hasSps && mixedInfo.hasPps);
    assert(mixedInfo.IsDecoderJoinPoint());

    std::vector<uint8_t> missingPps;
    AppendNal(missingPps, 32);
    AppendNal(missingPps, 33);
    AppendNal(missingPps, 19);
    assert(!InspectHevcAccessUnit(missingPps.data(), missingPps.size()).IsDecoderJoinPoint());

    std::vector<uint8_t> craNotIdr;
    AppendNal(craNotIdr, 32);
    AppendNal(craNotIdr, 33);
    AppendNal(craNotIdr, 34);
    AppendNal(craNotIdr, 21);
    assert(!InspectHevcAccessUnit(craNotIdr.data(), craNotIdr.size()).IsDecoderJoinPoint());

    assert(!InspectHevcAccessUnit(nullptr, 0).IsDecoderJoinPoint());
    return 0;
}
