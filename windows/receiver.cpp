// Steps 6-7: connect over usbmuxd, receive protocol packets,
// decode HEVC with FFmpeg (D3D11VA hwaccel), measure decode FPS.
// Build: cl /std:c++20 receiver.cpp /I<ffmpeg/include> /I<libusbmuxd/include>
//        /link <ffmpeg.lib> <libusbmuxd.lib> ws2_32.lib

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>
#include <chrono>
#include <thread>
#include <string>
#include <cwchar>
#include <cstdlib>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>

#include "stream_protocol.h"   // from ../protocol
#include <usbmuxd.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <libavutil/pixfmt.h>
}

#define DEVICE_PORT 12345u
static constexpr bool kSaveReceivedStream = false;

static AVPixelFormat select_d3d11_format(AVCodecContext*, const AVPixelFormat* formats) {
    for (const AVPixelFormat* format = formats; *format != AV_PIX_FMT_NONE; ++format) {
        if (*format == AV_PIX_FMT_D3D11) return *format;
    }
    fprintf(stderr, "WARN: HEVC decoder did not offer D3D11 output; using software decode\n");
    return formats[0];
}

static int connect_tcp(const char* host) {
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char port[6]{};
    std::snprintf(port, sizeof(port), "%u", DEVICE_PORT);
    addrinfo* results = nullptr;
    if (getaddrinfo(host, port, &hints, &results) != 0) return -1;
    int socket = -1;
    for (addrinfo* item = results; item; item = item->ai_next) {
        SOCKET candidate = ::socket(item->ai_family, item->ai_socktype, item->ai_protocol);
        if (candidate == INVALID_SOCKET) continue;
        const DWORD timeoutMs = 1500;
        setsockopt(candidate, SOL_SOCKET, SO_RCVTIMEO,
                   reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));
        setsockopt(candidate, SOL_SOCKET, SO_SNDTIMEO,
                   reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));
        if (::connect(candidate, item->ai_addr, static_cast<int>(item->ai_addrlen)) == 0) {
            socket = static_cast<int>(candidate);
            break;
        }
        closesocket(candidate);
    }
    freeaddrinfo(results);
    if (socket >= 0) printf("INFO: connected to iPhone USB network at %s:%u\n", host, DEVICE_PORT);
    return socket;
}

static std::string discover_iphone_usb_host() {
    ULONG bytes = 16 * 1024;
    std::vector<uint8_t> storage(bytes);
    auto* adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data());
    ULONG status = GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_GATEWAYS,
                                        nullptr, adapters, &bytes);
    if (status == ERROR_BUFFER_OVERFLOW) {
        storage.resize(bytes);
        adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data());
        status = GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_GATEWAYS,
                                      nullptr, adapters, &bytes);
    }
    if (status != NO_ERROR) return {};

    for (auto* adapter = adapters; adapter; adapter = adapter->Next) {
        const wchar_t* name = adapter->FriendlyName ? adapter->FriendlyName : L"";
        const wchar_t* description = adapter->Description ? adapter->Description : L"";
        if (!wcsstr(name, L"Apple") && !wcsstr(description, L"Apple")) continue;
        for (auto* gateway = adapter->FirstGatewayAddress; gateway; gateway = gateway->Next) {
            if (gateway->Address.lpSockaddr->sa_family != AF_INET) continue;
            char host[INET_ADDRSTRLEN]{};
            const auto* address = reinterpret_cast<const sockaddr_in*>(gateway->Address.lpSockaddr);
            if (InetNtopA(AF_INET, &address->sin_addr, host, sizeof(host))) return host;
        }
    }
    return {};
}

static int connect_to_device(const char* usbNetworkHost) {
    // Personal Hotspot over USB creates a normal high-bandwidth Ethernet link.
    // This is the supported Windows transport and works with the Apple Devices
    // app; it does not depend on the incomplete Windows usbmuxd implementation.
    const int tcpSocket = connect_tcp(usbNetworkHost);
    if (tcpSocket >= 0) return tcpSocket;

    // Older Apple Mobile Device Support installations can still use the
    // libusbmuxd implementation. It is intentionally only a fallback.
    usbmuxd_device_info_t *list = nullptr;
    int count = usbmuxd_get_device_list(&list);
    if (count <= 0) {
        fprintf(stderr, "ERROR: no usbmuxd devices (is iTunes/AppleMobileDevice installed?)\n");
        return -1;
    }
    const int device_handle = static_cast<int>(list[0].handle);
    printf("INFO: device_handle=%d udid=%s\n", device_handle, list[0].udid);
    int fd = usbmuxd_connect(device_handle, DEVICE_PORT);
    usbmuxd_device_list_free(&list);
    if (fd < 0) {
        fprintf(stderr, "ERROR: usbmuxd_connect failed (phone app must be listening)\n");
        return -1;
    }
    printf("INFO: connected fd=%d\n", fd);
    return fd;
}

// Naive blocking read-until-full.
static bool read_exact(int fd, uint8_t *buf, size_t n, const char *part) {
    size_t got = 0;
    while (got < n) {
        int r = recv(fd, reinterpret_cast<char *>(buf + got),
                     static_cast<int>(n - got), 0);
        if (r <= 0) {
            // libusbmuxd on Windows can return a non-blocking socket. WSAEWOULDBLOCK
            // is not a disconnect; wait for the iPhone's next encoded frame.
            if (r == SOCKET_ERROR && WSAGetLastError() == WSAEWOULDBLOCK) {
                fd_set readable{};
                FD_SET(static_cast<SOCKET>(fd), &readable);
                timeval timeout{};
                timeout.tv_sec = 5;
                const int ready = select(0, &readable, nullptr, nullptr, &timeout);
                if (ready > 0) continue;
                if (ready == 0) {
                    fprintf(stderr, "WARN: timed out waiting for %s\n", part);
                } else {
                    fprintf(stderr, "ERROR: select %s failed: WSA=%d\n", part, WSAGetLastError());
                }
                return false;
            }
            if (r == 0) {
                fprintf(stderr, "ERROR: iPhone closed connection while reading %s (%zu/%zu bytes)\n", part, got, n);
            } else {
                fprintf(stderr, "ERROR: recv %s failed: WSA=%d\n", part, WSAGetLastError());
            }
            return false;
        }
        got += static_cast<size_t>(r);
    }
    return true;
}

static AVCodecContext *init_decoder() {
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_HEVC);
    if (!codec) { fprintf(stderr, "ERROR: HEVC decoder not found\n"); return nullptr; }
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) { fprintf(stderr, "ERROR: avcodec_alloc_context3 failed\n"); return nullptr; }

    // D3D11VA hardware acceleration.
    AVBufferRef *hw = nullptr;
    if (av_hwdevice_ctx_create(&hw, AV_HWDEVICE_TYPE_D3D11VA, nullptr, nullptr, 0) == 0) {
        ctx->hw_device_ctx = av_buffer_ref(hw);
        ctx->get_format = select_d3d11_format;
        av_buffer_unref(&hw);
        printf("INFO: D3D11VA requested\n");
    } else {
        printf("WARN: D3D11VA unavailable, falling back to software\n");
    }

    if (avcodec_open2(ctx, codec, nullptr) < 0) {
        fprintf(stderr, "ERROR: avcodec_open2 failed\n");
        avcodec_free_context(&ctx);
        return nullptr;
    }
    printf("INFO: HEVC decoder ready\n");
    return ctx;
}

static void receive_session(int fd) {
    // Saving a 4K60 stream fills storage quickly; keep live mode disk-free.
    FILE *out = kSaveReceivedStream ? fopen("received.h265", "wb") : nullptr;
    AVCodecContext *dec = init_decoder();

    std::vector<uint8_t> hdr(STREAM_HEADER_SIZE);
    uint64_t frames = 0, decoded = 0;
    auto t0 = std::chrono::steady_clock::now();
    printf("INFO: waiting for first HEVC frame from iPhone\n");

    while (true) {
        if (!read_exact(fd, hdr.data(), STREAM_HEADER_SIZE, "stream header")) break;
        stream_header_t h = {};
        if (!stream_header_read(hdr.data(), &h) || !stream_header_is_valid(&h)) {
            fprintf(stderr, "ERROR: invalid stream header, stream desync\n");
            break;
        }
        if (h.codec != STREAM_CODEC_HEVC) {
            fprintf(stderr, "ERROR: unsupported stream codec %u\n", static_cast<unsigned>(h.codec));
            break;
        }
        std::vector<uint8_t> frame(h.frame_size);
        if (!read_exact(fd, frame.data(), h.frame_size, "video frame")) break;

        if (frames == 0) {
            printf("INFO: first HEVC packet=%u bytes frame=%u\n",
                   h.frame_size, h.frame_number);
        }

        if (out) fwrite(frame.data(), 1, h.frame_size, out);
        frames++;

        // Step 7: decode with FFmpeg and count.
        if (dec) {
            AVPacket *pkt = av_packet_alloc();
            pkt->data = frame.data();
            pkt->size = static_cast<int>(h.frame_size);
            if (avcodec_send_packet(dec, pkt) == 0) {
                AVFrame *f = av_frame_alloc();
                while (avcodec_receive_frame(dec, f) == 0) decoded++;
                av_frame_free(&f);
            }
            av_packet_free(&pkt);
        }

        if (frames % 600 == 0) {
            auto now = std::chrono::steady_clock::now();
            double s = std::chrono::duration<double>(now - t0).count();
            printf("STAT: recv=%.1f fps decode=%llu frames\n", frames / s,
                   static_cast<unsigned long long>(decoded));
        }
    }

    if (out) fclose(out);
    if (dec) avcodec_free_context(&dec);
    printf("INFO: done, received %llu frames\n",
           static_cast<unsigned long long>(frames));
}

int main(int argc, char** argv) {
    WSADATA winsock{};
    if (WSAStartup(MAKEWORD(2, 2), &winsock) != 0) {
        fprintf(stderr, "ERROR: WSAStartup failed\n");
        return 1;
    }

    // Keep running across app restarts, lock/unlock recovery, and USB reconnects.
    // A double-clicked receiver must wait for the iPhone instead of flashing away.
    const char* environmentHost = std::getenv("IPHONE_CAMERA_HOST");
    const std::string discoveredHost = discover_iphone_usb_host();
    const std::string usbNetworkHost = argc > 1 ? argv[1] :
        (environmentHost && *environmentHost ? environmentHost :
         (discoveredHost.empty() ? "172.20.10.1" : discoveredHost));
    printf("INFO: iPhone Camera USB receiver started; USB-network host=%s port=%u\n",
           usbNetworkHost.c_str(), DEVICE_PORT);
    for (;;) {
        const int fd = connect_to_device(usbNetworkHost.c_str());
        if (fd >= 0) {
            receive_session(fd);
            closesocket(fd);
            fprintf(stderr, "WARN: stream ended; retrying in 1 second\n");
        } else {
            fprintf(stderr, "INFO: retrying iPhone connection in 1 second\n");
        }
        std::this_thread::sleep_for(std::chrono::seconds(1));
    }
}
