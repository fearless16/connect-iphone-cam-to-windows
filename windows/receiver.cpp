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

#include "gpu_frame_publisher.h"

#include "stream_protocol.h"   // from ../protocol
#include <usbmuxd.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <libavutil/avutil.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <libavutil/pixfmt.h>
}

#define DEVICE_PORT 12345u
static constexpr bool kSaveReceivedStream = false;

struct DecodeTelemetry {
    bool d3d11_requested = false;
    bool first_frame_reported = false;
    uint64_t d3d11_frames = 0;
    uint64_t software_frames = 0;
    uint64_t gpu_backpressure_drops = 0;
};

// OBS Media Source officially accepts MPEG-TS over UDP.  This relay keeps
// iPhone HEVC compressed until it reaches OBS; no frame is mapped or copied on
// the CPU.  OBS owns the hardware decode on the selected Radeon adapter.
class ObsUdpRelay final {
public:
    static constexpr const char* kUrl = "udp://127.0.0.1:12346?pkt_size=1316";

    ~ObsUdpRelay() { Close(); }

    bool Open() {
        int status = avformat_alloc_output_context2(&context_, nullptr, "mpegts", kUrl);
        if (status < 0 || !context_) return Report("avformat_alloc_output_context2", status);
        stream_ = avformat_new_stream(context_, nullptr);
        if (!stream_) return Report("avformat_new_stream", AVERROR(ENOMEM));
        stream_->time_base = AVRational{1, 1'000'000};
        stream_->codecpar->codec_type = AVMEDIA_TYPE_VIDEO;
        stream_->codecpar->codec_id = AV_CODEC_ID_HEVC;
        stream_->codecpar->width = 3840;
        stream_->codecpar->height = 2160;
        status = avio_open(&context_->pb, kUrl, AVIO_FLAG_WRITE);
        if (status < 0) return Report("avio_open", status);
        status = avformat_write_header(context_, nullptr);
        if (status < 0) return Report("avformat_write_header", status);
        printf("INFO: OBS relay ready; Media Source input=%s format=mpegts\\n", kUrl);
        return true;
    }

    bool Write(const AVPacket& packet, uint64_t timestampUs, bool isKeyframe) {
        if (!context_ || !stream_) return false;
        AVPacket output{};
        output.data = packet.data;
        output.size = packet.size;
        output.stream_index = stream_->index;
        output.pts = static_cast<int64_t>(timestampUs);
        output.dts = output.pts;
        output.duration = 16'667;
        if (isKeyframe) output.flags |= AV_PKT_FLAG_KEY;
        const int status = av_interleaved_write_frame(context_, &output);
        return status >= 0 || Report("av_interleaved_write_frame", status);
    }

private:
    bool Report(const char* operation, int status) {
        char text[AV_ERROR_MAX_STRING_SIZE]{};
        av_strerror(status, text, sizeof(text));
        fprintf(stderr, "ERROR: OBS relay %s failed: %s (%d)\\n", operation, text, status);
        return false;
    }

    void Close() noexcept {
        if (!context_) return;
        if (context_->pb) {
            av_write_trailer(context_);
            avio_closep(&context_->pb);
        }
        avformat_free_context(context_);
        context_ = nullptr;
        stream_ = nullptr;
    }

    AVFormatContext* context_ = nullptr;
    AVStream* stream_ = nullptr;
};

static AVPixelFormat select_d3d11_format(AVCodecContext*, const AVPixelFormat* formats) {
    for (const AVPixelFormat* format = formats; *format != AV_PIX_FMT_NONE; ++format) {
        if (*format == AV_PIX_FMT_D3D11) return *format;
    }
    fprintf(stderr, "WARN: HEVC decoder did not offer D3D11 output; using software decode\n");
    return formats[0];
}

// Windows can prefer an unrelated Wi-Fi default route when both Wi-Fi and the
// iPhone USB-tether adapter have the same metric. Bind explicitly to the IPv4
// address on the Apple adapter whose gateway is the requested iPhone host.
static bool bind_iphone_usb_interface(SOCKET socket, const char* host) {
    IN_ADDR requestedHost{};
    if (InetPtonA(AF_INET, host, &requestedHost) != 1) return false;

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
    if (status != NO_ERROR) return false;

    for (auto* adapter = adapters; adapter; adapter = adapter->Next) {
        const wchar_t* name = adapter->FriendlyName ? adapter->FriendlyName : L"";
        const wchar_t* description = adapter->Description ? adapter->Description : L"";
        if (!wcsstr(name, L"Apple") && !wcsstr(description, L"Apple")) continue;

        bool gatewayMatches = false;
        for (auto* gateway = adapter->FirstGatewayAddress; gateway; gateway = gateway->Next) {
            if (gateway->Address.lpSockaddr->sa_family != AF_INET) continue;
            const auto* address = reinterpret_cast<const sockaddr_in*>(gateway->Address.lpSockaddr);
            if (address->sin_addr.S_un.S_addr == requestedHost.S_un.S_addr) {
                gatewayMatches = true;
                break;
            }
        }
        if (!gatewayMatches) continue;

        for (auto* unicast = adapter->FirstUnicastAddress; unicast; unicast = unicast->Next) {
            if (unicast->Address.lpSockaddr->sa_family != AF_INET) continue;
            const auto* local = reinterpret_cast<const sockaddr_in*>(unicast->Address.lpSockaddr);
            if (::bind(socket, reinterpret_cast<const sockaddr*>(local), sizeof(*local)) == 0) {
                char address[INET_ADDRSTRLEN]{};
                InetNtopA(AF_INET, &local->sin_addr, address, sizeof(address));
                printf("INFO: bound iPhone USB network source=%s\n", address);
                return true;
            }
            return false;
        }
    }
    return false;
}

static SOCKET connect_tcp(const char* host) {
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char port[6]{};
    std::snprintf(port, sizeof(port), "%u", DEVICE_PORT);
    addrinfo* results = nullptr;
    if (getaddrinfo(host, port, &hints, &results) != 0) return INVALID_SOCKET;
    SOCKET socket = INVALID_SOCKET;
    for (addrinfo* item = results; item; item = item->ai_next) {
        SOCKET candidate = ::socket(item->ai_family, item->ai_socktype, item->ai_protocol);
        if (candidate == INVALID_SOCKET) continue;
        if (item->ai_family != AF_INET || !bind_iphone_usb_interface(candidate, host)) {
            closesocket(candidate);
            continue;
        }
        if (::connect(candidate, item->ai_addr, static_cast<int>(item->ai_addrlen)) == 0) {
            socket = candidate;
            break;
        }
        closesocket(candidate);
    }
    freeaddrinfo(results);
    if (socket != INVALID_SOCKET) printf("INFO: connected to iPhone USB network at %s:%u\n", host, DEVICE_PORT);
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

static SOCKET connect_to_device(const char* usbNetworkHost) {
    // Native Apple Mobile Device Service/usbmux is the preferred USB path.
    // It does not rely on iPhone Personal Hotspot exposing an inbound port.
    usbmuxd_device_info_t *list = nullptr;
    const int count = usbmuxd_get_device_list(&list);
    const usbmuxd_device_info_t* usbDevice = nullptr;
    for (int index = 0; index < count; ++index) {
        if (list[index].conn_type == CONNECTION_TYPE_USB) {
            usbDevice = &list[index];
            break;
        }
    }
    if (usbDevice != nullptr) {
        const int device_handle = static_cast<int>(usbDevice->handle);
        printf("INFO: device_handle=%d udid=%s\n", device_handle, usbDevice->udid);
        int fd = usbmuxd_connect(device_handle, DEVICE_PORT);
        if (list != nullptr) usbmuxd_device_list_free(&list);
        if (fd >= 0) {
            printf("INFO: connected fd=%d\n", fd);
            // libusbmuxd exposes a legacy int descriptor. Preserve the full-width
            // SOCKET type for all Winsock calls after this compatibility boundary.
            return static_cast<SOCKET>(fd);
        }
        fprintf(stderr, "WARN: usbmuxd_connect failed; trying USB network fallback\n");
    } else if (list != nullptr) {
        usbmuxd_device_list_free(&list);
    }

    // Personal Hotspot over USB remains a useful fallback when AMDS has not
    // enumerated the device yet.
    const SOCKET tcpSocket = connect_tcp(usbNetworkHost);
    if (tcpSocket != INVALID_SOCKET) return tcpSocket;
    fprintf(stderr, "ERROR: no iPhone USB transport available (AMDS/usbmux or USB network)\n");
    return INVALID_SOCKET;
}

// Naive blocking read-until-full.
static bool read_exact(SOCKET fd, uint8_t *buf, size_t n, const char *part) {
    size_t got = 0;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (got < n) {
        // Wait before each read instead of imposing a short SO_RCVTIMEO on the
        // socket. A 4K HEVC packet can be large, and a brief USB scheduling
        // stall must not be treated as a broken iPhone connection.
        fd_set readable{};
        FD_SET(fd, &readable);
        const auto now = std::chrono::steady_clock::now();
        if (now >= deadline) {
            fprintf(stderr, "WARN: timed out waiting for %s\n", part);
            return false;
        }
        const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now);
        timeval timeout{};
        timeout.tv_sec = static_cast<long>(remaining.count() / 1'000);
        timeout.tv_usec = static_cast<long>((remaining.count() % 1'000) * 1'000);
        const int ready = select(0, &readable, nullptr, nullptr, &timeout);
        if (ready == 0) {
            fprintf(stderr, "WARN: timed out waiting for %s\n", part);
            return false;
        }
        if (ready < 0) {
            fprintf(stderr, "ERROR: select %s failed: WSA=%d\n", part, WSAGetLastError());
            return false;
        }
        int r = recv(fd, reinterpret_cast<char *>(buf + got),
                     static_cast<int>(n - got), 0);
        if (r <= 0) {
            // libusbmuxd may expose a non-blocking socket. That condition is
            // not a disconnect: wait again until this logical read's deadline.
            const int socketError = WSAGetLastError();
            if (r == SOCKET_ERROR && socketError == WSAEWOULDBLOCK) {
                continue;
            }
            if (r == 0) {
                fprintf(stderr, "ERROR: iPhone closed connection while reading %s (%zu/%zu bytes)\n", part, got, n);
            } else {
                fprintf(stderr, "ERROR: recv %s failed: WSA=%d\n", part, socketError);
            }
            return false;
        }
        got += static_cast<size_t>(r);
    }
    return true;
}

static AVCodecContext *init_decoder(DecodeTelemetry &telemetry) {
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_HEVC);
    if (!codec) { fprintf(stderr, "ERROR: HEVC decoder not found\n"); return nullptr; }
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) { fprintf(stderr, "ERROR: avcodec_alloc_context3 failed\n"); return nullptr; }

    // D3D11VA hardware acceleration.
    AVBufferRef *hw = nullptr;
    if (av_hwdevice_ctx_create(&hw, AV_HWDEVICE_TYPE_D3D11VA, nullptr, nullptr, 0) == 0) {
        telemetry.d3d11_requested = true;
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

// An Annex-B HEVC connection can start at any packet boundary. VPS/SPS/PPS by
// themselves are not enough. Require IDR (NAL 19/20), not CRA/BLA: only IDR
// guarantees a decoder joining mid-stream needs no earlier reference picture.
static bool contains_hevc_idr(const uint8_t* data, size_t size) {
    for (size_t i = 0; i + 4 < size; ++i) {
        size_t prefix = 0;
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) prefix = 3;
        else if (i + 5 < size && data[i] == 0 && data[i + 1] == 0 &&
                 data[i + 2] == 0 && data[i + 3] == 1) prefix = 4;
        if (!prefix) continue;
        const size_t nal = i + prefix;
        if (nal >= size) return false;
        const uint8_t nal_type = (data[nal] >> 1) & 0x3f;
        if (nal_type == 19 || nal_type == 20) return true;
        i = nal;
    }
    return false;
}

static int drain_decoder(AVCodecContext *decoder, AVFrame *frame, uint64_t &decoded,
                         DecodeTelemetry &telemetry, GpuFramePublisher &publisher,
                         uint64_t fallback_timestamp_us) {
    for (;;) {
        const int status = avcodec_receive_frame(decoder, frame);
        if (status == 0) {
            ++decoded;
            if (frame->format == AV_PIX_FMT_D3D11) {
                ++telemetry.d3d11_frames;
                if (!telemetry.first_frame_reported) {
                    telemetry.first_frame_reported = true;
                    printf("INFO: verified GPU decode: D3D11 NV12 surface %dx%d\n",
                           frame->width, frame->height);
                }
                const uint64_t timestamp_us = frame->best_effort_timestamp == AV_NOPTS_VALUE
                    ? fallback_timestamp_us : static_cast<uint64_t>(frame->best_effort_timestamp);
                const HRESULT publish_hr = publisher.Publish(frame, timestamp_us);
                if (publish_hr == S_FALSE) {
                    ++telemetry.gpu_backpressure_drops;
                } else if (FAILED(publish_hr)) {
                    fprintf(stderr, "ERROR: GPU frame publish failed: 0x%08lX\n",
                            static_cast<unsigned long>(publish_hr));
                }
            } else {
                ++telemetry.software_frames;
                if (!telemetry.first_frame_reported) {
                    telemetry.first_frame_reported = true;
                    fprintf(stderr, "ERROR: decoder returned %s, not a D3D11 surface\n",
                            av_get_pix_fmt_name(static_cast<AVPixelFormat>(frame->format)));
                }
            }
            av_frame_unref(frame);
            continue;
        }
        if (status == AVERROR(EAGAIN) || status == AVERROR_EOF) return 0;
        fprintf(stderr, "ERROR: avcodec_receive_frame failed: %d\n", status);
        return status;
    }
}

static void receive_session(SOCKET fd, bool obsUdpRelay) {
    // Saving a 4K60 stream fills storage quickly; keep live mode disk-free.
    FILE *out = kSaveReceivedStream ? fopen("received.h265", "wb") : nullptr;
    DecodeTelemetry decodeTelemetry{};
    GpuFramePublisher gpuPublisher{};
    AVCodecContext *dec = obsUdpRelay ? nullptr : init_decoder(decodeTelemetry);
    ObsUdpRelay relay;
    if (obsUdpRelay && !relay.Open()) return;
    AVPacket *packet = av_packet_alloc();
    AVFrame *decodedFrame = av_frame_alloc();
    if (!packet || !decodedFrame) {
        fprintf(stderr, "ERROR: FFmpeg packet/frame allocation failed\n");
        av_packet_free(&packet);
        av_frame_free(&decodedFrame);
        if (out) fclose(out);
        if (dec) avcodec_free_context(&dec);
        return;
    }

    std::vector<uint8_t> hdr(STREAM_HEADER_SIZE);
    uint64_t frames = 0, decoded = 0;
    uint64_t skippedUntilRandomAccess = 0;
    bool waitingForRandomAccess = true;
    uint64_t firstTimestampUs = 0, previousTimestampUs = 0, sourceGapFrames = 0;
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
        // av_new_packet supplies AV_INPUT_BUFFER_PADDING_SIZE zero bytes, which
        // optimized FFmpeg bitstream readers are allowed to read past payload.
        if (av_new_packet(packet, static_cast<int>(h.frame_size)) < 0) {
            fprintf(stderr, "ERROR: av_new_packet failed for %u bytes\n", h.frame_size);
            break;
        }
        if (!read_exact(fd, packet->data, h.frame_size, "video frame")) {
            av_packet_unref(packet);
            break;
        }
        packet->pts = static_cast<int64_t>(h.timestamp_us);
        packet->dts = packet->pts;

        if (waitingForRandomAccess) {
            if (!contains_hevc_idr(packet->data, h.frame_size)) {
                ++skippedUntilRandomAccess;
                if (skippedUntilRandomAccess == 1 || skippedUntilRandomAccess % 60 == 0) {
                    fprintf(stderr, "INFO: waiting for HEVC IDR; skipped %llu delta frames\n",
                            static_cast<unsigned long long>(skippedUntilRandomAccess));
                }
                av_packet_unref(packet);
                continue;
            }
            if (dec) avcodec_flush_buffers(dec);
            waitingForRandomAccess = false;
            printf("INFO: HEVC IDR frame received after %llu skipped frames\n",
                   static_cast<unsigned long long>(skippedUntilRandomAccess));
        }

        if (frames == 0) {
            printf("INFO: first HEVC packet=%u bytes frame=%u\n",
                   h.frame_size, h.frame_number);
            firstTimestampUs = h.timestamp_us;
        } else if (h.timestamp_us > previousTimestampUs) {
            const uint64_t deltaUs = h.timestamp_us - previousTimestampUs;
            // A 60 fps source should advance by about 16.7 ms. Count only
            // significant gaps so this remains useful if the encoder jitters.
            if (deltaUs > 25'000) {
                sourceGapFrames += (deltaUs + 8'333) / 16'666 - 1;
            }
        }
        previousTimestampUs = h.timestamp_us;

        if (out) fwrite(packet->data, 1, h.frame_size, out);
        frames++;

        if (obsUdpRelay && !relay.Write(*packet, h.timestamp_us,
                                        contains_hevc_idr(packet->data, h.frame_size))) {
            av_packet_unref(packet);
            break;
        }

        // Default mode decodes with FFmpeg/D3D11VA for the GPU frame publisher.
        if (dec) {
            int status = avcodec_send_packet(dec, packet);
            if (status == AVERROR(EAGAIN)) {
                if (drain_decoder(dec, decodedFrame, decoded, decodeTelemetry, gpuPublisher,
                                  h.timestamp_us) == 0) {
                    status = avcodec_send_packet(dec, packet);
                }
            }
            if (status < 0) {
                fprintf(stderr, "ERROR: avcodec_send_packet failed: %d\n", status);
            } else {
                drain_decoder(dec, decodedFrame, decoded, decodeTelemetry, gpuPublisher,
                              h.timestamp_us);
            }
        }
        av_packet_unref(packet);

        if (frames % 120 == 0) {
            auto now = std::chrono::steady_clock::now();
            double s = std::chrono::duration<double>(now - t0).count();
            const double sourceSeconds = previousTimestampUs > firstTimestampUs
                ? static_cast<double>(previousTimestampUs - firstTimestampUs) / 1'000'000.0 : 0.0;
            const double sourceFps = sourceSeconds > 0
                ? static_cast<double>(frames - 1) / sourceSeconds : 0.0;
            printf("STAT: recv=%.1f fps sourcePTS=%.1f gaps=%llu decode=%llu gpu=%llu cpu=%llu ringDrop=%llu mode=%s frames\n",
                   frames / s, sourceFps,
                   static_cast<unsigned long long>(sourceGapFrames),
                   static_cast<unsigned long long>(decoded),
                   static_cast<unsigned long long>(decodeTelemetry.d3d11_frames),
                   static_cast<unsigned long long>(decodeTelemetry.software_frames),
                   static_cast<unsigned long long>(decodeTelemetry.gpu_backpressure_drops),
                   obsUdpRelay ? "OBS_UDP_HEVC" : "GPU_RING");
        }
    }

    if (out) fclose(out);
    av_packet_free(&packet);
    av_frame_free(&decodedFrame);
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
    // OBS relay is the production path.  Make it the double-click/default
    // behavior so users do not have to remember a command-line switch.
    bool obsUdpRelay = true;
    const char* explicitHost = nullptr;
    for (int index = 1; index < argc; ++index) {
        if (std::strcmp(argv[index], "--obs-udp") == 0) {
            obsUdpRelay = true;
        } else if (std::strcmp(argv[index], "--gpu-ring") == 0) {
            // Retain the old diagnostic publisher only for development.
            obsUdpRelay = false;
        } else if (!explicitHost) {
            explicitHost = argv[index];
        } else {
            fprintf(stderr, "Usage: receiver.exe [--obs-udp|--gpu-ring] [iPhone USB host]\n");
            return 2;
        }
    }
    const std::string discoveredHost = discover_iphone_usb_host();
    const std::string usbNetworkHost = explicitHost ? explicitHost :
        (environmentHost && *environmentHost ? environmentHost :
         (discoveredHost.empty() ? "172.20.10.1" : discoveredHost));
    printf("INFO: iPhone Camera USB receiver build=%s\n",
           obsUdpRelay ? "OBS_UDP_HEVC_RELAY_V1" : "GPU_RING_DIAGNOSTICS_V2");
    printf("INFO: iPhone Camera USB receiver started; USB-network host=%s port=%u\n",
           usbNetworkHost.c_str(), DEVICE_PORT);
    for (;;) {
        const SOCKET fd = connect_to_device(usbNetworkHost.c_str());
        if (fd != INVALID_SOCKET) {
            receive_session(fd, obsUdpRelay);
            closesocket(fd);
            fprintf(stderr, "WARN: stream ended; retrying in 1 second\n");
        } else {
            fprintf(stderr, "INFO: retrying iPhone connection in 1 second\n");
        }
        std::this_thread::sleep_for(std::chrono::seconds(1));
    }
}
