#include "gpu_frame_consumer.h"

#include <dxgi.h>
#include <dxgi1_2.h>

namespace iphone_camera::gpu_transport {

GpuFrameConsumer::~GpuFrameConsumer() { Reset(); }

void GpuFrameConsumer::Reset() noexcept {
    input_mutex_.Reset();
    input_texture_.Reset();
    input_handle_ = 0;
    context_.Reset();
    device_.Reset();
    if (device_manager_ && device_handle_ && device_locked_) {
        device_manager_->UnlockDevice(device_handle_, FALSE);
        device_locked_ = false;
    }
    if (device_manager_ && device_handle_) {
        device_manager_->CloseDeviceHandle(device_handle_);
    }
    device_handle_ = nullptr;
    device_manager_.Reset();
    if (producer_process_) CloseHandle(producer_process_);
    producer_process_ = nullptr;
    producer_pid_ = 0;
    if (control_) UnmapViewOfFile(control_);
    control_ = nullptr;
    if (mapping_) CloseHandle(mapping_);
    mapping_ = nullptr;
    generation_ = 0;
    last_sequence_ = 0;
}

HRESULT GpuFrameConsumer::OpenControlBlock() {
    if (control_) return S_OK;
    mapping_ = OpenFileMappingW(FILE_MAP_READ, FALSE, kControlMappingName);
    if (!mapping_) return HRESULT_FROM_WIN32(GetLastError());
    control_ = static_cast<ControlBlock*>(MapViewOfFile(mapping_, FILE_MAP_READ,
                                                         0, 0, sizeof(ControlBlock)));
    if (!control_) return HRESULT_FROM_WIN32(GetLastError());
    if (!valid(*control_)) return MF_E_INVALIDMEDIATYPE;
    return S_OK;
}

HRESULT GpuFrameConsumer::ValidateAdapter() const {
    if (!control_ || control_->adapter.low_part != adapter_.low_part ||
        control_->adapter.high_part != adapter_.high_part) {
        return MF_E_UNSUPPORTED_D3D_TYPE;
    }
    return S_OK;
}

HRESULT GpuFrameConsumer::SetDevice(IUnknown* dxgi_manager) {
    if (!dxgi_manager) return E_POINTER;
    Reset();
    HRESULT hr = dxgi_manager->QueryInterface(IID_PPV_ARGS(&device_manager_));
    if (FAILED(hr)) return hr;
    hr = device_manager_->OpenDeviceHandle(&device_handle_);
    if (FAILED(hr)) return hr;
    hr = device_manager_->LockDevice(device_handle_, IID_PPV_ARGS(&device_), TRUE);
    if (FAILED(hr)) return hr;
    device_locked_ = true;
    device_->GetImmediateContext(&context_);

    Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
    Microsoft::WRL::ComPtr<IDXGIAdapter> dxgi_adapter;
    DXGI_ADAPTER_DESC desc{};
    if (FAILED(device_.As(&dxgi_device)) ||
        FAILED(dxgi_device->GetAdapter(&dxgi_adapter)) ||
        FAILED(dxgi_adapter->GetDesc(&desc))) return E_FAIL;
    adapter_.low_part = desc.AdapterLuid.LowPart;
    adapter_.high_part = desc.AdapterLuid.HighPart;
    return S_OK;
}

HRESULT GpuFrameConsumer::OpenSlot(const FrameSlot& slot) {
    if (slot.shared_texture_handle == 0) return MF_E_TRANSFORM_NEED_MORE_INPUT;
    if (input_handle_ == slot.shared_texture_handle && input_texture_) return S_OK;
    input_mutex_.Reset();
    input_texture_.Reset();
    input_handle_ = 0;

    // A D3D11.1 NT shared handle is process-local. Duplicate it from the
    // receiver process, then open it with the documented OpenSharedResource1.
    if (producer_pid_ != control_->producer_pid || !producer_process_) {
        if (producer_process_) CloseHandle(producer_process_);
        producer_process_ = OpenProcess(PROCESS_DUP_HANDLE, FALSE, control_->producer_pid);
        producer_pid_ = control_->producer_pid;
        if (!producer_process_) return HRESULT_FROM_WIN32(GetLastError());
    }
    HANDLE remote_handle = reinterpret_cast<HANDLE>(static_cast<uintptr_t>(slot.shared_texture_handle));
    HANDLE local_handle = nullptr;
    if (!DuplicateHandle(producer_process_, remote_handle, GetCurrentProcess(),
                         &local_handle, 0, FALSE, DUPLICATE_SAME_ACCESS)) {
        return HRESULT_FROM_WIN32(GetLastError());
    }
    Microsoft::WRL::ComPtr<ID3D11Device1> device1;
    HRESULT hr = device_.As(&device1);
    if (SUCCEEDED(hr)) hr = device1->OpenSharedResource1(local_handle, IID_PPV_ARGS(&input_texture_));
    CloseHandle(local_handle);
    if (FAILED(hr)) return hr;
    hr = input_texture_.As(&input_mutex_);
    if (FAILED(hr)) return hr;
    input_handle_ = slot.shared_texture_handle;
    return S_OK;
}

HRESULT GpuFrameConsumer::CopyLatest(IMFSample* destination,
                                     LONGLONG* timestamp_100ns,
                                     LONGLONG* duration_100ns,
                                     bool* discontinuity) {
    if (!destination || !timestamp_100ns || !duration_100ns || !discontinuity)
        return E_POINTER;
    *discontinuity = false;
    HRESULT hr = OpenControlBlock();
    if (FAILED(hr)) return hr;
    hr = ValidateAdapter();
    if (FAILED(hr)) return hr;
    const uint64_t sequence = InterlockedCompareExchange64(
        reinterpret_cast<volatile LONG64*>(&control_->latest_sequence), 0, 0);
    if (sequence == 0) return MF_E_TRANSFORM_NEED_MORE_INPUT;
    const FrameSlot slot = control_->slots[sequence % kSlotCount];
    if (slot.sequence != sequence) return MF_E_TRANSFORM_NEED_MORE_INPUT;
    hr = OpenSlot(slot);
    if (FAILED(hr)) return hr;

    Microsoft::WRL::ComPtr<IMFMediaBuffer> buffer;
    Microsoft::WRL::ComPtr<IMFDXGIBuffer> dxgi_buffer;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> output_texture;
    UINT subresource = 0;
    if (FAILED(destination->GetBufferByIndex(0, &buffer)) ||
        FAILED(buffer.As(&dxgi_buffer)) ||
        FAILED(dxgi_buffer->GetResource(IID_PPV_ARGS(&output_texture))) ||
        FAILED(dxgi_buffer->GetSubresourceIndex(&subresource))) return E_NOINTERFACE;

    if (generation_ != control_->generation) {
        generation_ = control_->generation;
        last_sequence_ = 0;
        *discontinuity = true;
    }
    // Frame Server pulls samples asynchronously. Do not treat the positive
    // WAIT_TIMEOUT/WAIT_ABANDONED values as success: no copy/release is legal
    // until AcquireSync returned exactly S_OK.
    hr = input_mutex_->AcquireSync(slot.consumer_key, 0);
    if (hr == WAIT_TIMEOUT) return MF_E_TRANSFORM_NEED_MORE_INPUT;
    if (hr != S_OK) return FAILED(hr) ? hr : E_FAIL;
    context_->CopySubresourceRegion(output_texture.Get(), subresource, 0, 0, 0,
                                    input_texture_.Get(), 0, nullptr);
    hr = input_mutex_->ReleaseSync(slot.producer_key);
    if (hr != S_OK) return FAILED(hr) ? hr : E_FAIL;
    *timestamp_100ns = slot.timestamp_100ns;
    *duration_100ns = slot.duration_100ns;
    *discontinuity = *discontinuity || (last_sequence_ != 0 && sequence != last_sequence_ + 1);
    last_sequence_ = sequence;
    return S_OK;
}

} // namespace iphone_camera::gpu_transport
