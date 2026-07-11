// Steps 6-7: connect over usbmuxd, receive protocol packets,
// decode HEVC with FFmpeg (D3D11VA hwaccel), measure decode FPS.
// Build (MSYS2): g++ -std=c++20 receiver.cpp -o receiver.exe \
//   $(pkg-config --libs libavcodec libavutil) -lusbmuxd -lws2_32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>
#include <chrono>
#include "stream_protocol.h"
#include <usbmuxd.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
}

#define DEVICE_PORT 12345u

static int connect_to_device() {
    usbmuxd_device_info_t *list = nullptr;
    int count = usbmuxd_get_device_list(&list);
    if (count <= 0) {
        fprintf(stderr, "ERROR: no usbmuxd devices (is Apple Mobile Device support installed?)\n");
        return -1;
    }
    uint32_t handle = list[0].handle;
    printf("INFO: handle=%u udid=%s\n", handle, list[0].udid);
    int fd = usbmuxd_connect(handle, DEVICE_PORT);
    usbmuxd_device_list_free(&list);
    if (fd < 0) {
        fprintf(stderr, "ERROR: usbmuxd_connect failed (phone app must be listening)\n");
        return -1;
    }
    printf("INFO: connected fd=%d\n", fd);
    return fd;
}

// Naive blocking read-until-full.
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

static AVCodecContext *init_decoder() {
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_HEVC);
    if (!codec) { fprintf(stderr, "ERROR: HEVC decoder not found\n"); return nullptr; }
    AVCodecContext *ctx = avcodec_alloc_context3(codec);

    AVBufferRef *hw = nullptr;
    if (av_hwdevice_ctx_create(&hw, AV_HWDEVICE_TYPE_D3D11VA, nullptr, nullptr, 0) == 0) {
        ctx->hw_device_ctx = av_buffer_ref(hw);
        av_buffer_unref(&hw);
        printf("INFO: D3D11VA enabled\n");
    } else {
        printf("WARN: D3D11VA unavailable, falling back to software\n");
    }

    if (avcodec_open2(ctx, codec, nullptr) < 0) {
        fprintf(stderr, "ERROR: avcodec_open2 failed\n");
        return nullptr;
    }
    return ctx;
}

int main() {
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        fprintf(stderr, "ERROR: WSAStartup failed\n");
        return 1;
    }
    int fd = connect_to_device();
    if (fd < 0) { WSACleanup(); return 1; }

    FILE *out = fopen("received.h265", "wb");
    AVCodecContext *dec = init_decoder();

    std::vector<uint8_t> hdr(STREAM_HEADER_SIZE);
    uint64_t frames = 0, decoded = 0;
    auto t0 = std::chrono::steady_clock::now();

    while (true) {
        if (!read_exact(fd, hdr.data(), STREAM_HEADER_SIZE)) break;
        if (!stream_magic_match(hdr.data())) {
            fprintf(stderr, "ERROR: bad magic, stream desync\n");
            break;
        }
        stream_header_t *h = reinterpret_cast<stream_header_t *>(hdr.data());
        std::vector<uint8_t> frame(h->frame_size);
        if (!read_exact(fd, frame.data(), h->frame_size)) break;

        fwrite(frame.data(), 1, h->frame_size, out);
        frames++;

        if (dec) {
            AVPacket *pkt = av_packet_alloc();
            pkt->data = frame.data();
            pkt->size = static_cast<int>(h->frame_size);
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

    fclose(out);
    if (dec) avcodec_free_context(&dec);
    closesocket(fd);
    WSACleanup();
    printf("INFO: done, received %llu frames\n", static_cast<unsigned long long>(frames));
    return 0;
}
