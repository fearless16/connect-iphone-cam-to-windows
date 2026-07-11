// Step 8 (full): self-contained DirectShow push-source filter "iPhone Camera".
// OBS loads this in its own process. The filter:
//   1. connects to the phone over usbmuxd (port 12345)
//   2. parses the binary protocol (see stream_protocol.h)
//   3. decodes HEVC with FFmpeg, converts to RGB32
//   4. fills the output pin from a ring buffer
// Build links: strmiids.lib, strmbase.lib, avcodec.lib, avutil.lib, swscale.lib,
//              usbmuxd.lib, ws2_32.lib, d3d11.lib

#include <winsock2.h>
#include <ws2tcpip.h>
#include <streams.h>
#include <cstdint>
#include <atomic>
#include <thread>
#include <vector>

#include "stream_protocol.h"
#include <usbmuxd.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
}

#define DEVICE_PORT 12345u

// ---- Frame source: decoder thread pushes decoded RGB32 here ----
class FrameRing {
public:
    static constexpr int W = 3840, H = 2160;
    static constexpr int STRIDE = W * 4;            // RGB32
    static constexpr size_t FRAME_BYTES = STRIDE * H;
    void push(uint8_t *rgb) { std::memcpy(buf_.data(), rgb, FRAME_BYTES); ready_.store(true); }
    bool pop(uint8_t *dst) {
        if (!ready_.load()) return false;
        std::memcpy(dst, buf_.data(), FRAME_BYTES);
        return true;
    }
private:
    std::vector<uint8_t> buf_ = std::vector<uint8_t>(FRAME_BYTES);
    std::atomic<bool> ready_{false};
};
static FrameRing g_ring;
static std::atomic<bool> g_running{false};

// ---- Worker: receive + decode ----
static bool read_exact(int fd, uint8_t *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        int r = recv(fd, reinterpret_cast<char *>(buf + got),
                     static_cast<int>(n - got), 0);
        if (r <= 0) return false;
        got += static_cast<size_t>(r);
    }
    return true;
}

static void worker() {
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        fprintf(stderr, "CAMERA: WSAStartup failed\n"); return;
    }
    usbmuxd_device_info_t *list = nullptr;
    if (usbmuxd_get_device_list(&list) <= 0) {
        fprintf(stderr, "CAMERA: no device\n");
        WSACleanup();
        return;
    }
    uint32_t handle = list[0].handle;
    int fd = usbmuxd_connect(handle, DEVICE_PORT);
    usbmuxd_device_list_free(&list);
    if (fd < 0) { fprintf(stderr, "CAMERA: connect failed\n"); WSACleanup(); return; }

    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_HEVC);
    AVCodecContext *dec = avcodec_alloc_context3(codec);
    avcodec_open2(dec, codec, nullptr);

    // RGB32 destination buffers
    std::vector<uint8_t> rgb(FrameRing::FRAME_BYTES);
    struct SwsContext *sws = sws_getContext(
        FrameRing::W, FrameRing::H, AV_PIX_FMT_YUV420P,
        FrameRing::W, FrameRing::H, AV_PIX_FMT_RGB32,
        SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);

    std::vector<uint8_t> hdr(STREAM_HEADER_SIZE);
    while (g_running.load()) {
        if (!read_exact(fd, hdr.data(), STREAM_HEADER_SIZE)) break;
        if (!stream_magic_match(hdr.data())) { fprintf(stderr, "CAMERA: desync\n"); break; }
        auto *h = reinterpret_cast<stream_header_t *>(hdr.data());
        std::vector<uint8_t> frame(h->frame_size);
        if (!read_exact(fd, frame.data(), h->frame_size)) break;

        AVPacket *pkt = av_packet_alloc();
        pkt->data = frame.data();
        pkt->size = static_cast<int>(h->frame_size);
        AVFrame *yuv = av_frame_alloc();
        if (avcodec_send_packet(dec, pkt) == 0) {
            if (avcodec_receive_frame(dec, yuv) == 0) {
                uint8_t *dst[1] = { rgb.data() };
                int dstStride[1] = { FrameRing::STRIDE };
                sws_scale(sws, yuv->data, yuv->linesize, 0, FrameRing::H, dst, dstStride);
                g_ring.push(rgb.data());
            }
        }
        av_frame_free(&yuv);
        av_packet_free(&pkt);
    }
    closesocket(fd);
    sws_freeContext(sws);
    avcodec_free_context(&dec);
    WSACleanup();
}

// ---- Output pin ----
class CStreamPin : public CBaseOutputPin {
public:
    CStreamPin(HRESULT *hr, CBaseFilter *filter)
        : CBaseOutputPin(L"Out", filter, &m_lock, hr, L"Output") {}

    HRESULT DecideBufferSize(IMemAllocator *alloc, ALLOCATOR_PROPERTIES *p) override {
        p->cBuffers = 1;
        p->cbBuffer = static_cast<long>(FrameRing::FRAME_BYTES);
        ALLOCATOR_PROPERTIES actual;
        return alloc->SetProperties(p, &actual);
    }
    HRESULT GetMediaType(int i, CMediaType *mt) override {
        if (i != 0) return VFW_S_NO_MORE_ITEMS;
        mt->SetType(&MEDIATYPE_Video);
        mt->SetSubtype(&MEDIASUBTYPE_RGB32);
        mt->SetFormatType(&FORMAT_VideoInfo);
        VIDEOINFOHEADER vih = {};
        vih.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        vih.bmiHeader.biWidth = FrameRing::W;
        vih.bmiHeader.biHeight = FrameRing::H;
        vih.bmiHeader.biPlanes = 1;
        vih.bmiHeader.biBitCount = 32;
        vih.bmiHeader.biSizeImage = static_cast<DWORD>(FrameRing::FRAME_BYTES);
        vih.AvgTimePerFrame = 166666;
        mt->SetFormat(reinterpret_cast<BYTE *>(&vih), sizeof(vih));
        return S_OK;
    }
    HRESULT FillBuffer(IMediaSample *sample) override {
        BYTE *dst = nullptr;
        if (FAILED(sample->GetPointer(&dst))) return S_FALSE;
        if (!g_ring.pop(dst)) std::memset(dst, 0, FrameRing::FRAME_BYTES);
        sample->SetActualDataLength(static_cast<long>(FrameRing::FRAME_BYTES));
        sample->SetSyncPoint(TRUE);
        return S_OK;
    }
protected:
    CCritSec m_lock;
};

// ---- Filter ----
class CIPhoneCameraFilter : public CBaseFilter {
public:
    CIPhoneCameraFilter(LPUNKNOWN p, HRESULT *hr)
        : CBaseFilter(L"iPhone Camera", p, &m_stateLock, GUID_NULL), m_pin(hr, this) {
        g_running.store(true);
        m_thread = std::thread(worker);
    }
    ~CIPhoneCameraFilter() {
        g_running.store(false);
        if (m_thread.joinable()) m_thread.join();
    }
    CBasePin *GetPin(int n) override { return n == 0 ? &m_pin : nullptr; }
    int GetPinCount() override { return 1; }
    static CLSID clsid() {
        static const GUID g = {0x9f3a2c01,0x1b4e,0x4c8a,{0x9b,0x12,0x33,0x7a,0x55,0x9c,0x10,0x2d}};
        return g;
    }
private:
    CStreamPin m_pin;
    CCritSec m_stateLock;
    std::thread m_thread;
};

// ---- Registration ----
extern "C" BOOL WINAPI DllMain(HINSTANCE, DWORD, LPVOID) { return TRUE; }

CFactoryTemplate g_templates[] = {
    { L"iPhone Camera", &CIPhoneCameraFilter::clsid(),
      [](LPUNKNOWN p, HRESULT *hr) -> CUnknown * {
          return new CIPhoneCameraFilter(p, hr);
      }, nullptr, nullptr }
};
int g_cTemplates = 1;

STDAPI DllRegisterServer() { return AMovieDllRegisterServer2(TRUE); }
STDAPI DllUnregisterServer() { return AMovieDllRegisterServer2(FALSE); }
