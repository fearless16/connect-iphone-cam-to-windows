#pragma once

#include <array>
#include <cstdint>
#include <windows.h>
#include <d3d11_4.h>
#include <wrl/client.h>

#include "mf_virtual_camera/gpu_frame_transport.h"

struct AVFrame;

// Owns the producer side of the 4K60 GPU ring. It is intentionally separate
// from MF/OBS: receiver.exe remains the only process that talks to the phone.
class GpuFramePublisher final {
public:
    GpuFramePublisher() = default;
    ~GpuFramePublisher();

    GpuFramePublisher(const GpuFramePublisher&) = delete;
    GpuFramePublisher& operator=(const GpuFramePublisher&) = delete;

    // `source_timestamp_us` is converted once per iPhone session into the MF
    // 100-nanosecond timebase, preserving the source cadence rather than wall
    // clock jitter.
    HRESULT Publish(const AVFrame* frame, uint64_t source_timestamp_us);
    void Reset() noexcept;

private:
    HRESULT Initialize(const AVFrame* frame, uint64_t source_timestamp_us);

    HANDLE mapping_ = nullptr;
    iphone_camera::gpu_transport::ControlBlock* control_ = nullptr;
    Microsoft::WRL::ComPtr<ID3D11Device> device_;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
    std::array<Microsoft::WRL::ComPtr<ID3D11Texture2D>, iphone_camera::gpu_transport::kSlotCount> textures_;
    std::array<Microsoft::WRL::ComPtr<IDXGIKeyedMutex>, iphone_camera::gpu_transport::kSlotCount> mutexes_;
    std::array<HANDLE, iphone_camera::gpu_transport::kSlotCount> shared_handles_{};
    uint64_t origin_source_us_ = 0;
    int64_t origin_time_100ns_ = 0;
    uint64_t sequence_ = 0;
};
