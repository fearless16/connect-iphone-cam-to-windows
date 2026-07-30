#include "../windows/mf_virtual_camera/gpu_frame_transport.h"

int main() {
    using namespace iphone_camera::gpu_transport;
    ControlBlock block{};
    block.magic = kMagic;
    block.version = kVersion;
    block.size = sizeof(block);
    block.width = 3840;
    block.height = 2160;
    block.frame_rate_numerator = 60;
    block.frame_rate_denominator = 1;
    return valid(block) ? 0 : 1;
}
