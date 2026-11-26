#include <cassert>
#include <cstdint>
#include <string>

#include "wifi_discovery.h"

using namespace wifi_discovery;

int main() {
    // Instance names.
    assert(IsServiceInstanceName("Prajjwal's iPhone._ipcamstream._tcp.local"));
    assert(IsServiceInstanceName("a._ipcamstream._tcp.local"));
    assert(!IsServiceInstanceName(""));
    assert(!IsServiceInstanceName("_ipcamstream._tcp.local"));        // no instance
    assert(!IsServiceInstanceName("._ipcamstream._tcp.local"));       // empty instance
    assert(!IsServiceInstanceName("phone._http._tcp.local"));         // wrong service
    assert(!IsServiceInstanceName("phone._ipcamstream._udp.local"));  // wrong protocol
    assert(!IsServiceInstanceName("phone._ipcamstream._tcp.example.com"));
    assert(!IsServiceInstanceName("ph\x01one._ipcamstream._tcp.local"));  // control byte
    assert(!IsServiceInstanceName("ph\xC3\xA9one._ipcamstream._tcp.local"));  // non-ASCII
    assert(!IsServiceInstanceName(std::string(300, 'a') + "._ipcamstream._tcp.local"));

    // Endpoints.
    const uint8_t lan[4] = {192, 168, 1, 42};
    auto ok = FormatEndpoint(lan, 12345, 12345);
    assert(ok && *ok == "192.168.1.42");
    const uint8_t linkLocal[4] = {169, 254, 10, 2};  // direct cable / ad-hoc is legitimate
    assert(FormatEndpoint(linkLocal, 12345, 12345));
    assert(!FormatEndpoint(lan, 12346, 12345));      // wrong port
    assert(!FormatEndpoint(lan, 0, 12345));
    const uint8_t any[4] = {0, 0, 0, 0};
    const uint8_t loop[4] = {127, 0, 0, 1};
    const uint8_t multicast[4] = {224, 0, 0, 251};
    const uint8_t broadcast[4] = {255, 255, 255, 255};
    assert(!FormatEndpoint(any, 12345, 12345));
    assert(!FormatEndpoint(loop, 12345, 12345));
    assert(!FormatEndpoint(multicast, 12345, 12345));
    assert(!FormatEndpoint(broadcast, 12345, 12345));
    const uint8_t edge[4] = {223, 255, 255, 254};
    assert(FormatEndpoint(edge, 12345, 12345));
    return 0;
}
