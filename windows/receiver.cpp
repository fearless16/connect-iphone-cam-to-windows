// Steps 6-7: connect over usbmuxd, receive protocol packets,
// decode HEVC with FFmpeg (D3D11VA hwaccel), measure decode FPS.
// Build: cl /std:c++20 receiver.cpp /I<ffmpeg/include> /I<libusbmuxd/include>
//        /link <ffmpeg.lib> <libusbmuxd.lib> ws2_32.lib

#include <cstdio>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <vector>
#include <chrono>
#include <thread>
#include <string>
#include <atomic>
#include <cwchar>
#include <cstdlib>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <windows.h>

#include "gpu_frame_publisher.h"
#include "hevc_access_unit.h"
#include "hevc_sps.h"
#include "relay_recovery.h"
#include "relay_timestamp.h"
#include "stream_timing.h"

#include "stream_protocol.h"   // from ../protocol
#include <usbmuxd.h>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <libavutil/pixfmt.h>
}

#define DEVICE_PORT 12345u
// Set by the console control handler (Ctrl+C, Ctrl+Break, window close).
static std::atomic<bool> g_stopRequested{false};

struct DecodeTelemetry {
    bool d3d11_requested = false;
    bool first_frame_reported = false;
    uint64_t d3d11_frames = 0;
    uint64_t software_frames = 0;
    uint64_t gpu_backpressure_drops = 0;
};

// Outcome of one relay write. Gate drops are intentional (waiting for a
// decoder-join AU after a failure) and are counted apart from real failures.
enum class RelayWriteResult { Written, GateDrop, Failed };

// OBS Media Source officially accepts MPEG-TS over UDP.  This relay keeps
// iPhone HEVC compressed until it reaches OBS; no frame is mapped or copied on
// the CPU.  OBS owns the hardware decode on the selected Radeon adapter.
class ObsUdpRelay final {
public:
    static constexpr const char* kUrl = "udp://127.0.0.1:12346?pkt_size=1316";

    ~ObsUdpRelay() { Close(); }

    void BeginSession() {
        timestamp_clock_.BeginSession();
    }

    bool Open(bool isRecovery) {
        // Every open starts from a fully released FFmpeg context. This also
        // makes a failed recovery attempt safe to retry on a later IDR.
        Close(false);
        int status = avformat_alloc_output_context2(&context_, nullptr, "mpegts", kUrl);
        if (status < 0 || !context_) return Report("avformat_alloc_output_context2", status);
        stream_ = avformat_new_stream(context_, nullptr);
        if (!stream_) {
            const bool reported = Report("avformat_new_stream", AVERROR(ENOMEM));
            Close(false);
            return reported;
        }
        stream_->codecpar->codec_type = AVMEDIA_TYPE_VIDEO;
        stream_->codecpar->codec_id = AV_CODEC_ID_HEVC;
        stream_->codecpar->width = width_;
        stream_->codecpar->height = height_;
        stream_->avg_frame_rate = AVRational{60, 1};
        AVDictionary* options = nullptr;
        av_dict_set(&options, "pat_period", "0.1", 0);
        av_dict_set(&options, "muxdelay", "0", 0);
        av_dict_set(&options, "muxpreload", "0", 0);
        av_dict_set(&options, "flush_packets", "1", 0);
        if (isRecovery) {
            av_dict_set(&options, "mpegts_flags", "+initial_discontinuity", 0);
        }
        status = avio_open2(&context_->pb, kUrl, AVIO_FLAG_WRITE, nullptr, nullptr);
        if (status < 0) {
            av_dict_free(&options);
            const bool reported = Report("avio_open2", status);
            Close(false);
            return reported;
        }
        status = avformat_write_header(context_, &options);
        av_dict_free(&options);
        if (status < 0) {
            const bool reported = Report("avformat_write_header", status);
            Close(false);
            return reported;
        }
        header_written_ = true;
        muxer_time_base_ = stream_->time_base;
        printf("INFO: OBS relay ready; Media Source input=%s format=mpegts tb=%d/%d\n",
               kUrl, muxer_time_base_.num, muxer_time_base_.den);
        return true;
    }

    RelayWriteResult Write(const AVPacket& source, uint64_t timestampUs,
                           const HevcAccessUnitInfo& accessUnit) {
        bool reopenedForThisWrite = false;
        // The stream size can change between sessions (quality presets). Re-read
        // it from the SPS only at join points (about every 2 s): no allocation,
        // and a log line only when the size actually changes.
        if (accessUnit.IsDecoderJoinPoint()) {
            int w = 0;
            int h = 0;
            if (HevcAccessUnitDimensions(source.data, static_cast<size_t>(source.size), &w, &h) &&
                (w != width_ || h != height_)) {
                width_ = w;
                height_ = h;
                printf("INFO: stream size %dx%d\n", w, h);
                if (!Open(true)) {
                    // Retry on the next join point through the recovery gate,
                    // which reopens with the size recorded above.
                    recovery_gate_.OnReopenFailure();
                    next_reopen_attempt_ = std::chrono::steady_clock::now() + std::chrono::seconds(1);
                    return RelayWriteResult::Failed;
                }
            }
        }
        const RelayRecoveryAction action = recovery_gate_.BeforeWrite(
            accessUnit.IsDecoderJoinPoint());
        if (action == RelayRecoveryAction::Drop) return RelayWriteResult::GateDrop;
        if (action == RelayRecoveryAction::ReopenAndWrite) {
            const auto now = std::chrono::steady_clock::now();
            if (now < next_reopen_attempt_) return RelayWriteResult::GateDrop;
            if (!Open(true)) {
                recovery_gate_.OnReopenFailure();
                next_reopen_attempt_ = now + std::chrono::seconds(1);
                return RelayWriteResult::Failed;
            }
            recovery_gate_.OnReopenSuccess();
            reopenedForThisWrite = true;
        }
        if (!context_ || !stream_) return RelayWriteResult::Failed;
        const uint64_t relativeUs = timestamp_clock_.Rebase(timestampUs);
        AVPacket* packet = av_packet_alloc();
        if (!packet || av_packet_ref(packet, &source) < 0) {
            av_packet_free(&packet);
            if (reopenedForThisWrite) {
                next_reopen_attempt_ = std::chrono::steady_clock::now() + std::chrono::seconds(1);
            }
            return RelayWriteResult::Failed;
        }
        packet->stream_index = stream_->index;
        const int64_t candidatePts = av_rescale_q(static_cast<int64_t>(relativeUs),
                                                   AVRational{1, 1'000'000}, muxer_time_base_);
        packet->pts = last_mux_pts_ == AV_NOPTS_VALUE
            ? candidatePts : std::max(candidatePts, last_mux_pts_ + 1);
        packet->dts = packet->pts;
        last_mux_pts_ = packet->pts;
        packet->duration = av_rescale_q(16'667, AVRational{1, 1'000'000}, muxer_time_base_);
        if (accessUnit.hasIdr) packet->flags |= AV_PKT_FLAG_KEY;
        const int status = av_interleaved_write_frame(context_, packet);
        av_packet_free(&packet);
        if (status >= 0) {
            recovery_gate_.OnWriteSuccess();
            if (reopenedForThisWrite) {
                printf("INFO: OBS relay recovered on fresh HEVC decoder-join AU\n");
            }
            return RelayWriteResult::Written;
        }
        if (reopenedForThisWrite) {
            next_reopen_attempt_ = std::chrono::steady_clock::now() + std::chrono::seconds(1);
        }
        if (recovery_gate_.OnWriteFailure()) {
            fprintf(stderr,
                    "WARN: OBS relay write failed %u consecutive times; "
                    "waiting for HEVC decoder-join AU to reopen\n",
                    RelayRecoveryGate::kConsecutiveFailureThreshold);
            Close(false);
            if (!reopenedForThisWrite) {
                next_reopen_attempt_ = std::chrono::steady_clock::now();
            }
            return RelayWriteResult::Failed;
        }
        ReportWriteFailure(status);
        return RelayWriteResult::Failed;
    }

private:
    bool ReportWriteFailure(int status) {
        const auto now = std::chrono::steady_clock::now();
        if (now >= next_write_error_log_) {
            next_write_error_log_ = now + std::chrono::seconds(5);
            return Report("av_interleaved_write_frame", status);
        }
        return false;
    }

    bool Report(const char* operation, int status) {
        char text[AV_ERROR_MAX_STRING_SIZE]{};
        av_strerror(status, text, sizeof(text));
        fprintf(stderr, "ERROR: OBS relay %s failed: %s (%d)\n", operation, text, status);
        return false;
    }

    void Close(bool writeTrailer = true) noexcept {
        if (!context_) return;
        if (writeTrailer && header_written_ && context_->pb) {
            av_write_trailer(context_);
        }
        if (context_->pb) {
            avio_closep(&context_->pb);
        }
        avformat_free_context(context_);
        context_ = nullptr;
        stream_ = nullptr;
        header_written_ = false;
    }

    AVFormatContext* context_ = nullptr;
    AVStream* stream_ = nullptr;
    bool header_written_ = false;
    int width_ = 3840;
    int height_ = 2160;
    AVRational muxer_time_base_{1, 90'000};
    RelayTimestampClock timestamp_clock_{};
    RelayRecoveryGate recovery_gate_{};
    int64_t last_mux_pts_ = AV_NOPTS_VALUE;
    std::chrono::steady_clock::time_point next_write_error_log_{};
    std::chrono::steady_clock::time_point next_reopen_attempt_{};
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

static constexpr long kConnectTimeoutMs = 2'000;

static bool finish_nonblocking_connect(SOCKET socket) {
    fd_set writable{};
    fd_set exceptional{};
    FD_SET(socket, &writable);
    FD_SET(socket, &exceptional);
    timeval timeout{};
    timeout.tv_sec = kConnectTimeoutMs / 1'000;
    timeout.tv_usec = (kConnectTimeoutMs % 1'000) * 1'000;
    const int selected = select(0, nullptr, &writable, &exceptional, &timeout);
    if (selected <= 0) return false;

    int soError = 0;
    int soErrorSize = sizeof(soError);
    return getsockopt(socket, SOL_SOCKET, SO_ERROR,
                      reinterpret_cast<char*>(&soError), &soErrorSize) == 0 && soError == 0;
}

static SOCKET connect_tcp(const char* host, bool requireUsbInterface) {
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
        // A local USB forwarder (for example go-ios) listens on loopback and
        // already owns the Apple-device leg. Do not bind that connection to
        // the Personal Hotspot adapter; doing so makes localhost forwarding
        // impossible and unnecessarily couples the fallback to tethering.
        const bool loopbackForward = item->ai_family == AF_INET &&
            ntohl(reinterpret_cast<const sockaddr_in*>(item->ai_addr)->sin_addr.s_addr) == INADDR_LOOPBACK;
        if (requireUsbInterface && !loopbackForward &&
            (item->ai_family != AF_INET || !bind_iphone_usb_interface(candidate, host))) {
            closesocket(candidate);
            continue;
        }
        u_long nonBlocking = 1;
        if (ioctlsocket(candidate, FIONBIO, &nonBlocking) != 0) {
            closesocket(candidate);
            continue;
        }
        const int connected = ::connect(candidate, item->ai_addr, static_cast<int>(item->ai_addrlen));
        const int connectError = connected == 0 ? 0 : WSAGetLastError();
        const bool established = connected == 0 ||
            ((connectError == WSAEWOULDBLOCK || connectError == WSAEINPROGRESS ||
              connectError == WSAEALREADY) && finish_nonblocking_connect(candidate));
        if (established) {
            nonBlocking = 0;
            if (ioctlsocket(candidate, FIONBIO, &nonBlocking) != 0) {
                closesocket(candidate);
                continue;
            }
            socket = candidate;
            break;
        }
        closesocket(candidate);
    }
    freeaddrinfo(results);
    if (socket != INVALID_SOCKET) {
        if (requireUsbInterface) {
            printf("INFO: connected to iPhone USB network at %s:%u\n", host, DEVICE_PORT);
        } else {
            printf("INFO: connected to iPhone at %s:%u (direct TCP)\n", host, DEVICE_PORT);
        }
    }
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

static SOCKET connect_to_device(const char* host, bool directTcp) {
    if (directTcp) {
        const SOCKET direct = connect_tcp(host, false);
        if (direct == INVALID_SOCKET) {
            fprintf(stderr, "WARN: direct TCP connect to %s:%u failed\n", host, DEVICE_PORT);
        }
        return direct;
    }
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
    const SOCKET tcpSocket = connect_tcp(host, true);
    if (tcpSocket != INVALID_SOCKET) return tcpSocket;
    fprintf(stderr, "ERROR: no iPhone USB transport available (AMDS/usbmux or USB network)\n");
    return INVALID_SOCKET;
}

// Limits for one logical read. A phone that is merely idle (no frame to send
// yet) must not be treated like a stalled mid-packet transfer.
static constexpr long kHeaderIdleTimeoutMs = 15'000;
static constexpr long kPayloadTimeoutMs = 5'000;
// Longest single select(); keeps Ctrl+C responsive without busy-waiting.
static constexpr long kWaitSliceMs = 250;

// Blocking read-until-full with a deadline and a stop check.
static bool read_exact(SOCKET fd, uint8_t *buf, size_t n, const char *part, long timeoutMs) {
    size_t got = 0;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    while (got < n) {
        if (g_stopRequested.load()) return false;
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
        const long sliceMs = std::min<long>(static_cast<long>(remaining.count()), kWaitSliceMs);
        timeval timeout{};
        timeout.tv_sec = sliceMs / 1'000;
        timeout.tv_usec = (sliceMs % 1'000) * 1'000;
        const int ready = select(0, &readable, nullptr, nullptr, &timeout);
        if (ready == 0) continue;  // slice elapsed; the loop head enforces the deadline

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

static void receive_session(SOCKET fd, ObsUdpRelay* relay) {
    const bool obsUdpRelay = relay != nullptr;
    DecodeTelemetry decodeTelemetry{};
    GpuFramePublisher gpuPublisher{};
    AVCodecContext *dec = obsUdpRelay ? nullptr : init_decoder(decodeTelemetry);
    if (relay) relay->BeginSession();
    StreamTimingStats timing;
    timing.BeginSession();
    AVPacket *packet = av_packet_alloc();
    AVFrame *decodedFrame = av_frame_alloc();
    if (!packet || !decodedFrame) {
        fprintf(stderr, "ERROR: FFmpeg packet/frame allocation failed\n");
        av_packet_free(&packet);
        av_frame_free(&decodedFrame);
        if (dec) avcodec_free_context(&dec);
        return;
    }

    std::vector<uint8_t> hdr(STREAM_HEADER_SIZE);
    uint64_t frames = 0, decoded = 0;
    uint64_t skippedUntilRandomAccess = 0, relayWriteFailures = 0, relayGateDrops = 0;
    bool waitingForRandomAccess = true;
    uint64_t firstTimestampUs = 0, previousTimestampUs = 0, sourceGapFrames = 0;
    auto t0 = std::chrono::steady_clock::now();
    printf("INFO: waiting for first HEVC frame from iPhone\n");

    while (true) {
        if (!read_exact(fd, hdr.data(), STREAM_HEADER_SIZE, "stream header", kHeaderIdleTimeoutMs)) break;
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
        if (!read_exact(fd, packet->data, h.frame_size, "video frame", kPayloadTimeoutMs)) {
            av_packet_unref(packet);
            break;
        }
        const uint64_t arrivalUs = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count());
        timing.OnFrame(h.timestamp_us, arrivalUs);
        packet->pts = static_cast<int64_t>(h.timestamp_us);
        packet->dts = packet->pts;
        const HevcAccessUnitInfo accessUnit = InspectHevcAccessUnit(packet->data, h.frame_size);

        if (waitingForRandomAccess) {
            if (!accessUnit.IsDecoderJoinPoint()) {
                ++skippedUntilRandomAccess;
                if (skippedUntilRandomAccess == 1 || skippedUntilRandomAccess % 60 == 0) {
                    fprintf(stderr,
                            "INFO: waiting for HEVC VPS/SPS/PPS+IDR join AU; "
                            "skipped %llu frames\n",
                            static_cast<unsigned long long>(skippedUntilRandomAccess));
                }
                av_packet_unref(packet);
                continue;
            }
            if (dec) avcodec_flush_buffers(dec);
            waitingForRandomAccess = false;
            printf("INFO: HEVC decoder-join AU received after %llu skipped frames\n",
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

        frames++;

        if (obsUdpRelay) {
            const RelayWriteResult written = relay->Write(*packet, h.timestamp_us, accessUnit);
            if (written == RelayWriteResult::Failed) {
                ++relayWriteFailures;
            } else if (written == RelayWriteResult::GateDrop) {
                ++relayGateDrops;
            }
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
            printf("STAT: recv=%.1f fps sourcePTS=%.1f gaps=%llu relayDrop=%llu relayGateDrop=%llu decode=%llu gpu=%llu cpu=%llu ringDrop=%llu "
                   "extraDelayMs=%.1f maxExtraMs=%.1f maxGapMs=%.1f burst=%u skewMs=%.1f mode=%s frames\n",
                   frames / s, sourceFps,
                   static_cast<unsigned long long>(sourceGapFrames),
                   static_cast<unsigned long long>(relayWriteFailures),
                   static_cast<unsigned long long>(relayGateDrops),
                   static_cast<unsigned long long>(decoded),
                   static_cast<unsigned long long>(decodeTelemetry.d3d11_frames),
                   static_cast<unsigned long long>(decodeTelemetry.software_frames),
                   static_cast<unsigned long long>(decodeTelemetry.gpu_backpressure_drops),
                   timing.ExtraDelayUs() / 1000.0,
                   timing.WindowMaxExtraDelayUs() / 1000.0,
                   timing.MaxArrivalGapUs() / 1000.0,
                   static_cast<unsigned>(timing.BurstFrames()),
                   timing.SkewUs() / 1000.0,
                   obsUdpRelay ? "OBS_UDP_HEVC" : "GPU_RING");
            timing.ResetWindow();
        }
    }

    av_packet_free(&packet);
    av_frame_free(&decodedFrame);
    if (dec) avcodec_free_context(&dec);
    printf("INFO: done, received %llu frames\n",
           static_cast<unsigned long long>(frames));
}

static int run_receiver(bool obsUdpRelay, const std::string& usbNetworkHost, bool directTcp) {
    // Keep one MPEG-TS muxer alive across phone reconnects. This preserves its
    // transport-stream continuity counters and the OBS-facing timestamp domain.
    // This helper also guarantees the relay closes while Winsock is still live.
    ObsUdpRelay relay;
    if (obsUdpRelay && !relay.Open(false)) return 1;

    while (!g_stopRequested.load()) {
        const SOCKET fd = connect_to_device(usbNetworkHost.c_str(), directTcp);
        if (fd != INVALID_SOCKET) {
            receive_session(fd, obsUdpRelay ? &relay : nullptr);
            closesocket(fd);
            if (g_stopRequested.load()) break;
            fprintf(stderr, "WARN: stream ended; retrying in 1 second\n");
        } else {
            fprintf(stderr, "INFO: retrying iPhone connection in 1 second\n");
        }
        // One second in short slices so a stop request is not delayed.
        for (int slice = 0; slice < 10 && !g_stopRequested.load(); ++slice) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }
    printf("INFO: stop requested; closing OBS relay\n");
    return 0;
}

// Ctrl+C, Ctrl+Break and closing the console window all request a clean stop.
// The relay then writes its MPEG-TS trailer and closes before WSACleanup.
static BOOL WINAPI console_control_handler(DWORD event) {
    switch (event) {
        case CTRL_C_EVENT:
        case CTRL_BREAK_EVENT:
        case CTRL_CLOSE_EVENT:
            g_stopRequested.store(true);
            return TRUE;
        default:
            return FALSE;
    }
}

// Clicking the console enables QuickEdit selection, which suspends any thread
// that writes to the console. The relay must never stall on a log line.
static void disable_console_quick_edit() {
    HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
    DWORD mode = 0;
    if (input == nullptr || input == INVALID_HANDLE_VALUE || !GetConsoleMode(input, &mode)) return;
    mode &= ~static_cast<DWORD>(ENABLE_QUICK_EDIT_MODE);
    mode |= ENABLE_EXTENDED_FLAGS;
    SetConsoleMode(input, mode);
}

int main(int argc, char** argv) {
    WSADATA winsock{};
    if (WSAStartup(MAKEWORD(2, 2), &winsock) != 0) {
        fprintf(stderr, "ERROR: WSAStartup failed\n");
        return 1;
    }
    disable_console_quick_edit();
    SetConsoleCtrlHandler(console_control_handler, TRUE);

    // Keep running across app restarts, lock/unlock recovery, and USB reconnects.
    // A double-clicked receiver must wait for the iPhone instead of flashing away.
    const char* environmentHost = std::getenv("IPHONE_CAMERA_HOST");
    // OBS relay is the production path.  Make it the double-click/default
    // behavior so users do not have to remember a command-line switch.
    bool obsUdpRelay = true;
    const char* explicitHost = nullptr;
    const char* directHost = nullptr;
    for (int index = 1; index < argc; ++index) {
        if (std::strcmp(argv[index], "--obs-udp") == 0) {
            obsUdpRelay = true;
        } else if (std::strcmp(argv[index], "--gpu-ring") == 0) {
            // Retain the old diagnostic publisher only for development.
            obsUdpRelay = false;
        } else if (std::strcmp(argv[index], "--host") == 0) {
            if (index + 1 >= argc) {
                fprintf(stderr, "Usage: receiver.exe [--obs-udp|--gpu-ring] [--host <iPhone address>] [iPhone USB host]\n");
                return 2;
            }
            directHost = argv[++index];
        } else if (!explicitHost) {
            explicitHost = argv[index];
        } else {
            fprintf(stderr, "Usage: receiver.exe [--obs-udp|--gpu-ring] [--host <iPhone address>] [iPhone USB host]\n");
            return 2;
        }
    }
    const bool directTcp = directHost != nullptr;
    const std::string discoveredHost = directTcp ? std::string() : discover_iphone_usb_host();
    const std::string usbNetworkHost = directTcp ? directHost : explicitHost ? explicitHost :
        (environmentHost && *environmentHost ? environmentHost :
         (discoveredHost.empty() ? "172.20.10.1" : discoveredHost));
    printf("INFO: iPhone Camera USB receiver build=%s\n",
           obsUdpRelay ? "OBS_UDP_HEVC_RELAY_V1" : "GPU_RING_DIAGNOSTICS_V2");
    if (directTcp) {
        printf("INFO: iPhone Camera receiver started; direct TCP host=%s port=%u\n",
               usbNetworkHost.c_str(), DEVICE_PORT);
    } else {
        printf("INFO: iPhone Camera USB receiver started; USB-network host=%s port=%u\n",
               usbNetworkHost.c_str(), DEVICE_PORT);
    }
    const int receiverStatus = run_receiver(obsUdpRelay, usbNetworkHost, directTcp);
    WSACleanup();
    return receiverStatus;
}
