#pragma once

#include <windows.h>
#include <d3d11_4.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <wrl/client.h>

#include "gpu_frame_transport.h"

namespace iphone_camera::gpu_transport {

// Lives inside the Media Foundation source DLL. The Windows Frame Server gives
// it the exact D3D11 device that backs its sample allocator. `copy_latest`
// does one GPU CopyResource from the receiver's shared NV12 texture to that
// allocator texture; it never maps either texture to the CPU.
class GpuFrameConsumer final {
public:
    GpuFrameConsumer() = default;
    ~GpuFrameConsumer();

    GpuFrameConsumer(const GpuFrameConsumer&) = delete;
    GpuFrameConsumer& operator=(const GpuFrameConsumer&) = delete;

    HRESULT SetDevice(IUnknown* dxgi_manager);
    HRESULT CopyLatest(IMFSample* destination, LONGLONG* timestamp_100ns,
                       LONGLONG* duration_100ns, bool* discontinuity);
    void Reset() noexcept;

private:
    HRESULT OpenControlBlock();
    HRESULT OpenSlot(const FrameSlot& slot);
    HRESULT ValidateAdapter() const;

    HANDLE mapping_ = nullptr;
    ControlBlock* control_ = nullptr;
    uint32_t generation_ = 0;
    uint64_t last_sequence_ = 0;
    AdapterIdentity adapter_{};
    Microsoft::WRL::ComPtr<IMFDXGIDeviceManager> device_manager_;
    HANDLE device_handle_ = nullptr;
    bool device_locked_ = false;
    Microsoft::WRL::ComPtr<ID3D11Device> device_;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> input_texture_;
    Microsoft::WRL::ComPtr<IDXGIKeyedMutex> input_mutex_;
    uint64_t input_handle_ = 0;
};

} // namespace iphone_camera::gpu_transport
