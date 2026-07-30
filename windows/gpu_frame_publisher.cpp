#include "gpu_frame_publisher.h"

#include <cstdio>
#include <dxgi.h>
#include <dxgi1_2.h>
#include <sddl.h>

extern "C" {
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>
}

using iphone_camera::gpu_transport::ControlBlock;
using iphone_camera::gpu_transport::FrameSlot;

static int64_t current_time_100ns() noexcept {
    FILETIME file_time{};
    GetSystemTimeAsFileTime(&file_time);
    ULARGE_INTEGER value{};
    value.LowPart = file_time.dwLowDateTime;
    value.HighPart = file_time.dwHighDateTime;
    return static_cast<int64_t>(value.QuadPart);
}

GpuFramePublisher::~GpuFramePublisher() { Reset(); }

void GpuFramePublisher::Reset() noexcept {
    for (auto& mutex : mutexes_) mutex.Reset();
    for (auto& texture : textures_) texture.Reset();
    for (auto& handle : shared_handles_) {
        if (handle) CloseHandle(handle);
        handle = nullptr;
    }
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
    decoder_texture->GetDevice(device_.GetAddressOf());
    if (!device_) return E_FAIL;
    device_->GetImmediateContext(&context_);
    D3D11_TEXTURE2D_DESC source_desc{};
    decoder_texture->GetDesc(&source_desc);
    // HEVC decoder surfaces are coded-size aligned (for example 4096x2176
    // for a visible 3840x2160 frame). Advertise/copy the visible frame, not
    // that padded allocation, otherwise the virtual camera rejects 4K input.
    if (frame->width != 3840 || frame->height != 2160 || source_desc.Format != DXGI_FORMAT_NV12) {
        fprintf(stderr, "ERROR: unsupported GPU frame: visible=%dx%d surface=%ux%u format=%u\n",
                frame->width, frame->height, source_desc.Width, source_desc.Height,
                static_cast<unsigned>(source_desc.Format));
        return E_INVALIDARG;
    }

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
    control_->width = static_cast<uint32_t>(frame->width);
    control_->height = static_cast<uint32_t>(frame->height);
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

    // Do not clone the decoder descriptor: it carries decoder-only flags and
    // a coded-size array layout that cannot be turned into a shared texture.
    D3D11_TEXTURE2D_DESC ring_desc{};
    ring_desc.Width = static_cast<UINT>(frame->width);
    ring_desc.Height = static_cast<UINT>(frame->height);
    ring_desc.MipLevels = 1;
    ring_desc.ArraySize = 1;
    ring_desc.Format = DXGI_FORMAT_NV12;
    ring_desc.SampleDesc.Count = 1;
    ring_desc.SampleDesc.Quality = 0;
    ring_desc.Usage = D3D11_USAGE_DEFAULT;
    ring_desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    ring_desc.CPUAccessFlags = 0;
    // The documented D3D11.1 cross-process path. Legacy GetSharedHandle
    // resources leave validation driver-defined and fail on some AMD paths.
    ring_desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE |
                         D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX;
    for (uint32_t i = 0; i < iphone_camera::gpu_transport::kSlotCount; ++i) {
        HRESULT create_hr = device_->CreateTexture2D(&ring_desc, nullptr, &textures_[i]);
        if (FAILED(create_hr)) {
            fprintf(stderr, "ERROR: GPU ring CreateTexture2D failed: 0x%08lX\n",
                    static_cast<unsigned long>(create_hr));
            return create_hr;
        }
        HRESULT mutex_hr = textures_[i].As(&mutexes_[i]);
        if (FAILED(mutex_hr)) {
            fprintf(stderr, "ERROR: GPU ring IDXGIKeyedMutex query failed: 0x%08lX\n",
                    static_cast<unsigned long>(mutex_hr));
            return mutex_hr;
        }
        Microsoft::WRL::ComPtr<IDXGIResource1> resource;
        HRESULT resource_hr = textures_[i].As(&resource);
        if (FAILED(resource_hr)) return resource_hr;
        HRESULT share_hr = resource->CreateSharedHandle(nullptr,
                                                         DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE,
                                                         nullptr, &shared_handles_[i]);
        if (FAILED(share_hr)) {
            fprintf(stderr, "ERROR: GPU ring CreateSharedHandle failed: 0x%08lX\n",
                    static_cast<unsigned long>(share_hr));
            return share_hr;
        }
        control_->slots[i].shared_texture_handle =
            static_cast<uint64_t>(reinterpret_cast<uintptr_t>(shared_handles_[i]));
        control_->slots[i].producer_key = 0;
        control_->slots[i].consumer_key = 1;
        // Newly-created keyed mutexes start with key zero, owned by producer.
    }
    origin_source_us_ = source_timestamp_us;
    origin_time_100ns_ = current_time_100ns();
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
    // A producer must never block the USB/decode loop when OBS is not pulling
    // samples. WAIT_TIMEOUT is a positive Win32 value, so FAILED(hr) is not a
    // valid test here; only S_OK grants ownership of the keyed mutex.
    HRESULT hr = mutexes_[slot_index]->AcquireSync(published.producer_key, 0);
    if (hr == WAIT_TIMEOUT) return S_FALSE;
    if (hr != S_OK) {
        fprintf(stderr, "ERROR: GPU ring AcquireSync failed: 0x%08lX\n",
                static_cast<unsigned long>(hr));
        return FAILED(hr) ? hr : E_FAIL;
    }
    D3D11_BOX visible_box{};
    visible_box.right = static_cast<UINT>(frame->width);
    visible_box.bottom = static_cast<UINT>(frame->height);
    visible_box.back = 1;
    context_->CopySubresourceRegion(textures_[slot_index].Get(), 0, 0, 0, 0,
                                    decoder_texture, static_cast<UINT>(reinterpret_cast<uintptr_t>(frame->data[1])),
                                    &visible_box);
    hr = mutexes_[slot_index]->ReleaseSync(published.consumer_key);
    if (hr != S_OK) {
        fprintf(stderr, "ERROR: GPU ring ReleaseSync failed: 0x%08lX\n",
                static_cast<unsigned long>(hr));
        return FAILED(hr) ? hr : E_FAIL;
    }

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
