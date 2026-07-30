// Experimental DirectShow push-source filter. It deliberately delivers the
// newest complete decoded frame at the graph clock cadence; it is not a claim
// of verified end-to-end 4K60 performance.

#include <winsock2.h>
#include <streams.h>
#include <amvideo.h>
#include <uuids.h>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

#include "frame_store.h"
#include "stream_protocol.h"
#include <usbmuxd.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/pixfmt.h>
#include <libswscale/swscale.h>
}

namespace {
constexpr uint16_t kDevicePort = 12345;
constexpr long kWidth = 3840;
constexpr long kHeight = 2160;
constexpr long kStride = kWidth * 4;
constexpr size_t kFrameBytes = static_cast<size_t>(kStride) * kHeight;
constexpr REFERENCE_TIME kFrameDuration = 10'000'000 / 60;

const CLSID CLSID_IPhoneCamera =
{0x9f3a2c01, 0x1b4e, 0x4c8a, {0x9b, 0x12, 0x33, 0x7a, 0x55, 0x9c, 0x10, 0x2d}};

bool readExact(int fd, uint8_t* destination, size_t bytes, const std::atomic<bool>& running) {
    size_t received = 0;
    while (received < bytes && running.load(std::memory_order_acquire)) {
        const int result = recv(fd, reinterpret_cast<char*>(destination + received),
                                static_cast<int>(bytes - received), 0);
        if (result <= 0) return false;
        received += static_cast<size_t>(result);
    }
    return received == bytes;
}

class CameraReceiver {
public:
    explicit CameraReceiver(LatestFrameStore& frames) : frames_(frames) {}
    ~CameraReceiver() { stop(); }

    void start() {
        if (thread_.joinable()) return;
        running_.store(true, std::memory_order_release);
        thread_ = std::thread(&CameraReceiver::run, this);
    }
    void stop() {
        running_.store(false, std::memory_order_release);
        const int fd = socket_.load(std::memory_order_acquire);
        if (fd >= 0) shutdown(fd, SD_BOTH); // unblocks recv so destruction cannot hang.
        if (thread_.joinable()) thread_.join();
    }

private:
    int connectDevice() {
        usbmuxd_device_info_t* devices = nullptr;
        const int count = usbmuxd_get_device_list(&devices);
        if (count <= 0) return -1;
        const int fd = usbmuxd_connect(devices[0].device_id, kDevicePort);
        usbmuxd_device_list_free(&devices);
        return fd;
    }

    bool receiveSession(int fd) {
        const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_HEVC);
        AVCodecContext* decoder = codec ? avcodec_alloc_context3(codec) : nullptr;
        if (!decoder || avcodec_open2(decoder, codec, nullptr) < 0) {
            avcodec_free_context(&decoder);
            return false;
        }
        AVFrame* decoded = av_frame_alloc();
        SwsContext* scaler = nullptr;
        std::vector<uint8_t> header(STREAM_HEADER_SIZE);
        std::vector<uint8_t> rgb(kFrameBytes);
        bool ok = decoded != nullptr;

        while (ok && running_.load(std::memory_order_acquire)) {
            stream_header_t streamHeader{};
            if (!readExact(fd, header.data(), header.size(), running_) ||
                !stream_header_read(header.data(), &streamHeader) ||
                !stream_header_is_valid(&streamHeader) ||
                streamHeader.codec != STREAM_CODEC_HEVC) {
                ok = false;
                break;
            }
            std::vector<uint8_t> encoded(streamHeader.frame_size);
            if (!readExact(fd, encoded.data(), encoded.size(), running_)) { ok = false; break; }

            AVPacket packet{};
            packet.data = encoded.data();
            packet.size = static_cast<int>(encoded.size());
            if (avcodec_send_packet(decoder, &packet) < 0) continue;
            while (running_.load(std::memory_order_acquire) && avcodec_receive_frame(decoder, decoded) == 0) {
                if (decoded->width != kWidth || decoded->height != kHeight) continue;
                scaler = sws_getCachedContext(scaler, decoded->width, decoded->height,
                    static_cast<AVPixelFormat>(decoded->format), kWidth, kHeight,
                    AV_PIX_FMT_BGRA, SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
                if (!scaler) { ok = false; break; }
                uint8_t* planes[] = {rgb.data()};
                int strides[] = {kStride};
                sws_scale(scaler, decoded->data, decoded->linesize, 0, kHeight, planes, strides);
                frames_.publish(rgb.data(), rgb.size());
            }
        }
        sws_freeContext(scaler);
        av_frame_free(&decoded);
        avcodec_free_context(&decoder);
        return ok;
    }

    void run() {
        while (running_.load(std::memory_order_acquire)) {
            const int fd = connectDevice();
            if (fd >= 0) {
                socket_.store(fd, std::memory_order_release);
                receiveSession(fd);
                socket_.store(-1, std::memory_order_release);
                closesocket(fd);
            }
            // A device disconnect or bad packet is recoverable. This backoff
            // prevents a disconnected phone from spinning a CPU core.
            for (int tick = 0; tick < 10 && running_.load(std::memory_order_acquire); ++tick)
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }

    LatestFrameStore& frames_;
    std::atomic<bool> running_{true};
    std::atomic<int> socket_{-1};
    std::thread thread_;
};

class CIPhoneCameraSource;

class CIPhoneCameraStream final : public CSourceStream {
public:
    CIPhoneCameraStream(HRESULT* hr, CIPhoneCameraSource* parent, LatestFrameStore& frames);
    HRESULT GetMediaType(CMediaType* mediaType) override;
    HRESULT DecideBufferSize(IMemAllocator* allocator, ALLOCATOR_PROPERTIES* requested) override;
    HRESULT FillBuffer(IMediaSample* sample) override;
    // CSourceStream owns the graph worker thread. These are the supported
    // virtual lifecycle hooks (Active/Inactive are not virtual in BaseClasses).
    HRESULT OnThreadCreate() override;
    HRESULT OnThreadDestroy() override;

private:
    CIPhoneCameraSource* parent_;
    LatestFrameStore& frames_;
    REFERENCE_TIME sampleTime_ = 0;
};

class CIPhoneCameraSource final : public CSource {
public:
    CIPhoneCameraSource(LPUNKNOWN outer, HRESULT* hr)
        : CSource(L"iPhone Camera", outer, CLSID_IPhoneCamera),
          frames_(kFrameBytes), stream_(hr, this, frames_), receiver_(frames_) {}

    void startReceiver() { receiver_.start(); }
    void stopReceiver() { receiver_.stop(); }

private:
    LatestFrameStore frames_;
    CIPhoneCameraStream stream_;
    CameraReceiver receiver_;
};

CIPhoneCameraStream::CIPhoneCameraStream(HRESULT* hr, CIPhoneCameraSource* parent, LatestFrameStore& frames)
    : CSourceStream(L"iPhone Camera Output", hr, parent, L"Output"), parent_(parent), frames_(frames) {}

HRESULT CIPhoneCameraStream::GetMediaType(CMediaType* mediaType) {
    if (!mediaType) return E_POINTER;
    mediaType->SetType(&MEDIATYPE_Video);
    mediaType->SetSubtype(&MEDIASUBTYPE_RGB32);
    mediaType->SetFormatType(&FORMAT_VideoInfo);
    VIDEOINFOHEADER video{};
    video.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    video.bmiHeader.biWidth = kWidth;
    video.bmiHeader.biHeight = -kHeight; // top-down BGRA memory layout
    video.bmiHeader.biPlanes = 1;
    video.bmiHeader.biBitCount = 32;
    video.bmiHeader.biCompression = BI_RGB;
    video.bmiHeader.biSizeImage = static_cast<DWORD>(kFrameBytes);
    video.AvgTimePerFrame = kFrameDuration;
    mediaType->SetFormat(reinterpret_cast<BYTE*>(&video), sizeof(video));
    mediaType->SetTemporalCompression(FALSE);
    mediaType->SetSampleSize(static_cast<ULONG>(kFrameBytes));
    return S_OK;
}

HRESULT CIPhoneCameraStream::DecideBufferSize(IMemAllocator* allocator, ALLOCATOR_PROPERTIES* requested) {
    if (!allocator || !requested) return E_POINTER;
    requested->cBuffers = 2;
    requested->cbBuffer = static_cast<LONG>(kFrameBytes);
    ALLOCATOR_PROPERTIES actual{};
    const HRESULT hr = allocator->SetProperties(requested, &actual);
    if (FAILED(hr)) return hr;
    return actual.cbBuffer < static_cast<LONG>(kFrameBytes) ? E_FAIL : S_OK;
}

HRESULT CIPhoneCameraStream::OnThreadCreate() {
    parent_->startReceiver();
    return S_OK;
}

HRESULT CIPhoneCameraStream::OnThreadDestroy() {
    parent_->stopReceiver();
    return S_OK;
}

HRESULT CIPhoneCameraStream::FillBuffer(IMediaSample* sample) {
    if (!sample) return E_POINTER;
    BYTE* destination = nullptr;
    HRESULT hr = sample->GetPointer(&destination);
    if (FAILED(hr) || !destination) return FAILED(hr) ? hr : E_FAIL;
    if (!frames_.copyLatest(destination, kFrameBytes)) std::memset(destination, 0, kFrameBytes);
    sample->SetActualDataLength(static_cast<LONG>(kFrameBytes));
    const REFERENCE_TIME endTime = sampleTime_ + kFrameDuration;
    sample->SetTime(&sampleTime_, &endTime);
    sampleTime_ = endTime;
    sample->SetSyncPoint(TRUE);
    sample->SetDiscontinuity(FALSE);
    return S_OK;
}

CUnknown* WINAPI CreateIPhoneCamera(LPUNKNOWN outer, HRESULT* hr) {
    return new CIPhoneCameraSource(outer, hr);
}

const REGPINTYPES kPinTypes[] = {{&MEDIATYPE_Video, &MEDIASUBTYPE_RGB32}};
const REGFILTERPINS2 kPins[] = {{REG_PINFLAG_B_OUTPUT, 1, 1, kPinTypes, 0, nullptr, nullptr}};
const REGFILTER2 kFilterRegistration = {2, MERIT_DO_NOT_USE, 1, kPins};
} // namespace

CFactoryTemplate g_Templates[] = {
    {L"iPhone Camera", &CLSID_IPhoneCamera, CreateIPhoneCamera, nullptr, nullptr}
};
int g_cTemplates = sizeof(g_Templates) / sizeof(g_Templates[0]);

STDAPI DllRegisterServer() {
    HRESULT hr = AMovieDllRegisterServer2(TRUE);
    if (FAILED(hr)) return hr;

    IFilterMapper2* mapper = nullptr;
    hr = CoCreateInstance(CLSID_FilterMapper2, nullptr, CLSCTX_INPROC_SERVER,
                          IID_PPV_ARGS(&mapper));
    if (SUCCEEDED(hr)) {
        hr = mapper->RegisterFilter(CLSID_IPhoneCamera, L"iPhone Camera", nullptr,
                                    &CLSID_VideoInputDeviceCategory, nullptr, &kFilterRegistration);
        mapper->Release();
    }
    // Do not leave a creatable COM class behind when its capture category
    // registration fails; regsvr32 can be retried cleanly.
    if (FAILED(hr)) AMovieDllRegisterServer2(FALSE);
    return hr;
}

STDAPI DllUnregisterServer() {
    IFilterMapper2* mapper = nullptr;
    HRESULT categoryHr = CoCreateInstance(CLSID_FilterMapper2, nullptr, CLSCTX_INPROC_SERVER,
                                          IID_PPV_ARGS(&mapper));
    if (SUCCEEDED(categoryHr)) {
        categoryHr = mapper->UnregisterFilter(&CLSID_VideoInputDeviceCategory, nullptr, CLSID_IPhoneCamera);
        mapper->Release();
    }
    const HRESULT classHr = AMovieDllRegisterServer2(FALSE);
    return FAILED(categoryHr) ? categoryHr : classHr;
}
