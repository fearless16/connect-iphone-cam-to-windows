#include "gpu_frame_publisher.h"

#include <dxgi.h>
#include <mfapi.h>
#include <sddl.h>

extern "C" {
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>
}

using iphone_camera::gpu_transport::ControlBlock;
using iphone_camera::gpu_transport::FrameSlot;

GpuFramePublisher::~GpuFramePublisher() { Reset(); }

void GpuFramePublisher::Reset() noexcept {
    for (auto& mutex : mutexes_) mutex.Reset();
    for (auto& texture : textures_) texture.Reset();
    context_.Reset();
    device_.Reset();
    if (control_) UnmapViewOfFile(control_);
    control_ = nullptr;
    if (mapping_) CloseHandle(mapping_);
    mapping_ = nullptr;
    sequence_ = 0;
}

HRESULT GpuFramePublisher::Initialize(const AVFrame* frame, uint64_t source_timestamp_us) {
    if (!frame || frame->format != AV_PIX_FMT_D3D11 || !frame->data[0]) return E_INVALIDARG;
    auto* decoder_texture = reinterpret_cast<ID3D11Texture2D*>(frame->data[0]);
    HRESULT hr = decoder_texture->GetDevice(&device_);
    if (FAILED(hr)) return hr;
    device_->GetImmediateContext(&context_);
    D3D11_TEXTURE2D_DESC source_desc{};
    decoder_texture->GetDesc(&source_desc);
    if (source_desc.Width != 3840 || source_desc.Height != 2160 || source_desc.Format != DXGI_FORMAT_NV12)
        return MF_E_INVALIDMEDIATYPE;

    PSECURITY_DESCRIPTOR security_descriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:(A;;GRGW;;;SY)(A;;GRGW;;;LS)(A;;GRGW;;;OW)",
            SDDL_REVISION_1, &security_descriptor, nullptr)) {
        return HRESULT_FROM_WIN32(GetLastError());
    }
    SECURITY_ATTRIBUTES attributes{};
    attributes.nLength = sizeof(attributes);
    attributes.lpSecurityDescriptor = security_descriptor;
    mapping_ = CreateFileMappingW(INVALID_HANDLE_VALUE, &attributes, PAGE_READWRITE,
                                  0, sizeof(ControlBlock),
                                  iphone_camera::gpu_transport::kControlMappingName);
    LocalFree(security_descriptor);
    if (!mapping_) return HRESULT_FROM_WIN32(GetLastError());
    control_ = static_cast<ControlBlock*>(MapViewOfFile(mapping_, FILE_MAP_WRITE,
                                                         0, 0, sizeof(ControlBlock)));
    if (!control_) return HRESULT_FROM_WIN32(GetLastError());
    ZeroMemory(control_, sizeof(*control_));
    control_->magic = iphone_camera::gpu_transport::kMagic;
    control_->version = iphone_camera::gpu_transport::kVersion;
    control_->size = sizeof(*control_);
    control_->width = source_desc.Width;
    control_->height = source_desc.Height;
    control_->frame_rate_numerator = 60;
    control_->frame_rate_denominator = 1;
    control_->producer_pid = GetCurrentProcessId();

    Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
    Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
    DXGI_ADAPTER_DESC adapter_desc{};
    if (FAILED(device_.As(&dxgi_device)) || FAILED(dxgi_device->GetAdapter(&adapter)) ||
        FAILED(adapter->GetDesc(&adapter_desc))) return E_FAIL;
    control_->adapter.low_part = adapter_desc.AdapterLuid.LowPart;
    control_->adapter.high_part = adapter_desc.AdapterLuid.HighPart;

    D3D11_TEXTURE2D_DESC ring_desc = source_desc;
    ring_desc.BindFlags = 0;
    ring_desc.CPUAccessFlags = 0;
    ring_desc.Usage = D3D11_USAGE_DEFAULT;
    ring_desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX;
    for (uint32_t i = 0; i < iphone_camera::gpu_transport::kSlotCount; ++i) {
        if (FAILED(device_->CreateTexture2D(&ring_desc, nullptr, &textures_[i])) ||
            FAILED(textures_[i].As(&mutexes_[i]))) return E_FAIL;
        Microsoft::WRL::ComPtr<IDXGIResource> resource;
        HANDLE shared_handle = nullptr;
        if (FAILED(textures_[i].As(&resource)) || FAILED(resource->GetSharedHandle(&shared_handle)))
            return E_FAIL;
        control_->slots[i].shared_texture_handle =
            static_cast<uint64_t>(reinterpret_cast<uintptr_t>(shared_handle));
        control_->slots[i].producer_key = 0;
        control_->slots[i].consumer_key = 1;
        // Newly-created keyed mutexes start with key zero, owned by producer.
    }
    origin_source_us_ = source_timestamp_us;
    origin_time_100ns_ = MFGetSystemTime();
    return S_OK;
}

HRESULT GpuFramePublisher::Publish(const AVFrame* frame, uint64_t source_timestamp_us) {
    if (!control_) {
        HRESULT hr = Initialize(frame, source_timestamp_us);
        if (FAILED(hr)) return hr;
    }
    auto* decoder_texture = reinterpret_cast<ID3D11Texture2D*>(frame->data[0]);
    const uint32_t slot_index = static_cast<uint32_t>(sequence_ % iphone_camera::gpu_transport::kSlotCount);
    const FrameSlot& published = control_->slots[slot_index];
    HRESULT hr = mutexes_[slot_index]->AcquireSync(published.producer_key, 1000);
    if (FAILED(hr)) return hr;
    context_->CopySubresourceRegion(textures_[slot_index].Get(), 0, 0, 0, 0,
                                    decoder_texture, static_cast<UINT>(reinterpret_cast<uintptr_t>(frame->data[1])), nullptr);
    hr = mutexes_[slot_index]->ReleaseSync(published.consumer_key);
    if (FAILED(hr)) return hr;

    const uint64_t next_sequence = ++sequence_;
    FrameSlot& slot = control_->slots[slot_index];
    slot.timestamp_100ns = origin_time_100ns_ + static_cast<int64_t>(source_timestamp_us - origin_source_us_) * 10;
    slot.duration_100ns = 166667;
    MemoryBarrier();
    slot.sequence = next_sequence;
    InterlockedExchange64(reinterpret_cast<volatile LONG64*>(&control_->latest_sequence),
                          static_cast<LONG64>(next_sequence));
    return S_OK;
}
