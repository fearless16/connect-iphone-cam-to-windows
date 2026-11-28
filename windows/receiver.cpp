// receiver.exe: finds the iPhone (usbmux over USB, Personal Hotspot fallback,
// --host direct TCP, or --wifi Bonjour discovery), validates every protocol
// packet, gates on HEVC decoder-join points, and relays the still-compressed
// stream to OBS as MPEG-TS on udp://127.0.0.1:12346, or with --obs-tcp on
// tcp://127.0.0.1:12346 (T2.6: drops frames instead of queueing them when OBS
// stops reading). --gpu-ring is the old D3D11 decode diagnostic.
// Build: scripts/build_receiver_msys2.sh (mirrors the CI windows job).

#include <cstdio>
#include <cstdarg>
#include <io.h>
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
#include <mutex>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include <windows.h>
#include <windns.h>

#include "crash_report.h"
#include "gpu_frame_publisher.h"
#include "hevc_access_unit.h"
#include "hevc_sps.h"
#include "obs_tcp_flow.h"
#include "relay_recovery.h"
#include "relay_timestamp.h"
#include "stream_timing.h"
#include "wifi_discovery.h"

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
// iPhone Personal Hotspot gateway, used when no Apple adapter is detected.
static constexpr const char* kPersonalHotspotGateway = "172.20.10.1";
// Set by the console control handler (Ctrl+C, Ctrl+Break, window close).
static std::atomic<bool> g_stopRequested{false};
// Signalled by main after the relay has closed and Winsock is cleaned up. The
// close-window handler waits on it, because Windows ends the process as soon
// as that handler returns.
static HANDLE g_stoppedEvent = nullptr;
static constexpr DWORD kCloseWaitMs = 4'000;

// Every log line is one write. Redirected to a file, this CRT writes unbuffered
// stdout and stderr a byte at a time, so a line from the crash-report thread
// would otherwise land inside a main-thread line and garble both.
#ifdef __MINGW_PRINTF_FORMAT
__attribute__((format(__MINGW_PRINTF_FORMAT, 2, 3)))
#endif
static void log_line(FILE* stream, const char* format, ...) {
    char line[2048];
    va_list args;
    va_start(args, format);
    const int length = std::vsnprintf(line, sizeof(line), format, args);
    va_end(args);
    if (length <= 0) return;
    size_t size = static_cast<size_t>(length);
    if (size >= sizeof(line)) {  // truncated: keep the line break
        size = sizeof(line) - 1;
        line[size - 1] = '\n';
    }
    _write(_fileno(stream), line, static_cast<unsigned>(size));
}

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

// T2.6 (G6): the loopback TCP endpoint OBS connects to (--obs-tcp, Media Source
// input tcp://127.0.0.1:12346). It binds 127.0.0.1 only (R-ENG-SEC), serves one
// client (a new connection replaces the old one: that is OBS reconnecting), and
// never blocks the receive loop.
class ObsTcpEndpoint final {
public:
    static constexpr u_short kPort = 12346;
    // Small on purpose: whatever sits in socket buffers when OBS stops reading
    // reaches OBS late. While OBS reads, a 1.5 MB keyframe still passes in
    // about 2 ms on loopback (e2e tcp_steady).
    static constexpr int kSendBufferBytes = 64 * 1024;

    ObsTcpEndpoint() = default;
    ObsTcpEndpoint(const ObsTcpEndpoint&) = delete;  // owns sockets
    ObsTcpEndpoint& operator=(const ObsTcpEndpoint&) = delete;
    ~ObsTcpEndpoint() {
        Disconnect();
        if (listener_ != INVALID_SOCKET) closesocket(listener_);
    }

    // Accepts a waiting OBS connection and notices a closed one. Returns true
    // when the attached client changed (connected, replaced, or gone).
    bool Poll() {
        if (listener_ == INVALID_SOCKET && !Listen()) return false;
        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(listener_, &readable);
        if (client_ != INVALID_SOCKET) FD_SET(client_, &readable);
        timeval zero{0, 0};
        if (select(0, &readable, nullptr, nullptr, &zero) <= 0) return false;
        bool changed = false;
        // OBS never sends: a readable client socket means it closed or reset.
        if (client_ != INVALID_SOCKET && FD_ISSET(client_, &readable)) {
            char scratch[512];
            const int got = recv(client_, scratch, sizeof(scratch), 0);
            if (got == 0 || (got == SOCKET_ERROR && WSAGetLastError() != WSAEWOULDBLOCK)) {
                log_line(stdout, "INFO: OBS disconnected from tcp://127.0.0.1:%u\n", kPort);
                Disconnect();
                changed = true;
            }
        }
        if (FD_ISSET(listener_, &readable)) {
            const SOCKET accepted = accept(listener_, nullptr, nullptr);
            if (accepted != INVALID_SOCKET) {
                u_long nonBlocking = 1;
                ioctlsocket(accepted, FIONBIO, &nonBlocking);
                const BOOL noDelay = TRUE;
                setsockopt(accepted, IPPROTO_TCP, TCP_NODELAY,
                           reinterpret_cast<const char*>(&noDelay), sizeof(noDelay));
                setsockopt(accepted, SOL_SOCKET, SO_SNDBUF,
                           reinterpret_cast<const char*>(&kSendBufferBytes), sizeof(kSendBufferBytes));
                if (client_ != INVALID_SOCKET) Disconnect();
                client_ = accepted;
                log_line(stdout, "INFO: OBS connected to tcp://127.0.0.1:%u; starting at the next HEVC keyframe\n",
                         kPort);
                changed = true;
            }
        }
        return changed;
    }

    bool Connected() const { return client_ != INVALID_SOCKET; }

    // Listens before the first frame, so OBS can connect while the phone is
    // not streaming yet. Retried by Poll() if it fails.
    void EnsureListening() {
        if (listener_ == INVALID_SOCKET) Listen();
    }

    // Sends what the socket takes, waiting up to `waitUs` for room. Windows
    // buffers only ~0.3 MB on loopback, so a 1-2 MB 4K keyframe needs OBS to
    // read while it is sent; the short wait covers OBS being mid-decode. The
    // rest goes out on the next frame. Returns false if the client failed; it
    // is then closed.
    bool Flush(ObsTcpSendQueue& queue, int64_t waitUs = 0) {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::microseconds(waitUs);
        while (client_ != INVALID_SOCKET && queue.Size() > 0) {
            const size_t chunk = std::min<size_t>(queue.Size(), 1u << 20);
            const int sent = send(client_, reinterpret_cast<const char*>(queue.Data()),
                                  static_cast<int>(chunk), 0);
            if (sent > 0) {
                queue.Consume(static_cast<size_t>(sent));
                continue;
            }
            if (sent == SOCKET_ERROR && WSAGetLastError() == WSAEWOULDBLOCK) {
                const auto left = std::chrono::duration_cast<std::chrono::microseconds>(
                    deadline - std::chrono::steady_clock::now()).count();
                if (left <= 0) return true;
                fd_set writable;
                FD_ZERO(&writable);
                FD_SET(client_, &writable);
                timeval timeout{0, static_cast<long>(left)};
                if (select(0, nullptr, &writable, nullptr, &timeout) <= 0) return true;
                continue;
            }
            log_line(stdout, "INFO: OBS connection lost (send error %d)\n", WSAGetLastError());
            Disconnect();
            return false;
        }
        return true;
    }

    void Disconnect() {
        if (client_ == INVALID_SOCKET) return;
        closesocket(client_);
        client_ = INVALID_SOCKET;
    }

private:
    // Retried at most once a second on failure (port in use): the receiver
    // keeps streaming and never exits over OBS (R-ENG-ERR).
    bool Listen() {
        const auto now = std::chrono::steady_clock::now();
        if (now < next_listen_attempt_) return false;
        next_listen_attempt_ = now + std::chrono::seconds(1);
        const SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (listener == INVALID_SOCKET) return false;
        // Another process may not take the port over while we listen.
        const BOOL exclusive = TRUE;
        setsockopt(listener, SOL_SOCKET, SO_EXCLUSIVEADDRUSE,
                   reinterpret_cast<const char*>(&exclusive), sizeof(exclusive));
        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_port = htons(kPort);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        u_long nonBlocking = 1;
        if (bind(listener, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) != 0 ||
            listen(listener, 1) != 0 || ioctlsocket(listener, FIONBIO, &nonBlocking) != 0) {
            const bool first = !reported_listen_failure_;
            reported_listen_failure_ = true;
            if (first) {
                log_line(stderr, "ERROR: cannot listen on tcp://127.0.0.1:%u (error %d); retrying every second\n",
                         kPort, WSAGetLastError());
            }
            closesocket(listener);
            return false;
        }
        listener_ = listener;
        reported_listen_failure_ = false;
        log_line(stdout, "INFO: OBS relay listening; Media Source input=tcp://127.0.0.1:%u format=mpegts\n",
                 kPort);
        return true;
    }

    SOCKET listener_ = INVALID_SOCKET;
    SOCKET client_ = INVALID_SOCKET;
    bool reported_listen_failure_ = false;
    std::chrono::steady_clock::time_point next_listen_attempt_{};
};

// OBS Media Source officially accepts MPEG-TS over UDP.  This relay keeps
// iPhone HEVC compressed until it reaches OBS; no frame is mapped or copied on
// the CPU.  OBS owns the hardware decode on the selected Radeon adapter.
// UseTcp() switches the sink to ObsTcpEndpoint (T2.6, --obs-tcp).
class ObsUdpRelay final {
public:
    static constexpr const char* kUrl = "udp://127.0.0.1:12346?pkt_size=1316";
    // The flow control keeps the TCP queue to about one keyframe plus 100 ms.
    // This cap only guards memory if that ever fails; the client is dropped.
    static constexpr size_t kMaxTcpQueueBytes = 16u * 1024u * 1024u;
    static constexpr int kTcpIoBufferBytes = 64 * 1024;
    // Bounded: the phone receive loop runs on this thread (16.7 ms per frame).
    static constexpr int64_t kTcpSendWaitUs = 4'000;

    ObsUdpRelay() = default;
    ObsUdpRelay(const ObsUdpRelay&) = delete;             // owns FFmpeg contexts
    ObsUdpRelay& operator=(const ObsUdpRelay&) = delete;

    ~ObsUdpRelay() {
        Close();
        av_packet_free(&out_packet_);
    }

    // The first Open failed: keep running (R-ENG-ERR) and let the recovery
    // gate reopen the muxer on the next decoder-join AU.
    void ArmRecovery() {
        recovery_gate_.OnReopenFailure();
        next_reopen_attempt_ = std::chrono::steady_clock::now();
    }

    // T2.6: write MPEG-TS to the OBS TCP client instead of UDP. Call before Open.
    void UseTcp() { tcp_ = true; }
    bool IsTcp() const { return tcp_; }

    bool Open(bool isRecovery) {
        // Every open starts from a fully released FFmpeg context. This also
        // makes a failed recovery attempt safe to retry on a later IDR.
        Close(false);
        int status = avformat_alloc_output_context2(&context_, nullptr, "mpegts", tcp_ ? nullptr : kUrl);
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
        if (tcp_) tcp_endpoint_.EnsureListening();
        status = tcp_ ? OpenTcpIo() : avio_open2(&context_->pb, kUrl, AVIO_FLAG_WRITE, nullptr, nullptr);
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
        if (!tcp_) {
            log_line(stdout, "INFO: OBS relay ready; Media Source input=%s format=mpegts tb=%d/%d\n",
                   kUrl, muxer_time_base_.num, muxer_time_base_.den);
        }
        return true;
    }

    // `arrivalUs` is the PC steady clock when the frame finished arriving; it
    // sets the OBS timeline (G5). The phone timestamp is only diagnostics.
    RelayWriteResult Write(const AVPacket& source, uint64_t arrivalUs,
                           const HevcAccessUnitInfo& accessUnit) {
        if (tcp_ && !AdmitTcpFrame(arrivalUs, accessUnit.IsDecoderJoinPoint())) {
            return RelayWriteResult::GateDrop;
        }
        bool reopenedForThisWrite = false;
        // The stream size can change between sessions (quality presets). Re-read
        // it from the SPS only at join points (about every 1 s, G3): no allocation,
        // and a log line only when the size actually changes.
        if (accessUnit.IsDecoderJoinPoint()) {
            int w = 0;
            int h = 0;
            if (HevcAccessUnitDimensions(source.data, static_cast<size_t>(source.size), &w, &h) &&
                (w != width_ || h != height_)) {
                width_ = w;
                height_ = h;
                log_line(stdout, "INFO: stream size %dx%d\n", w, h);
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
        uint64_t relativeUs = arrival_clock_.Stamp(arrivalUs);
        // TCP: no forward jump over frames dropped while OBS was not reading.
        if (tcp_) relativeUs = tcp_flow_.MapTimelineUs(relativeUs, kNominalFrameDurationUs);
        // One packet reused for every write: av_interleaved_write_frame takes
        // the reference and leaves the packet blank, so nothing is allocated per frame.
        if (!out_packet_) out_packet_ = av_packet_alloc();
        AVPacket* packet = out_packet_;
        if (!packet || av_packet_ref(packet, &source) < 0) {
            if (packet) av_packet_unref(packet);
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
        packet->duration = av_rescale_q(static_cast<int64_t>(kNominalFrameDurationUs),
                                        AVRational{1, 1'000'000}, muxer_time_base_);
        if (accessUnit.hasIdr) packet->flags |= AV_PKT_FLAG_KEY;
        const int status = av_interleaved_write_frame(context_, packet);
        av_packet_unref(packet);
        if (tcp_) SendTcp();  // now, not on the next frame: every ms is latency
        if (status >= 0) {
            recovery_gate_.OnWriteSuccess();
            if (reopenedForThisWrite) {
                log_line(stdout, "INFO: OBS relay recovered on fresh HEVC decoder-join AU\n");
            }
            return RelayWriteResult::Written;
        }
        if (reopenedForThisWrite) {
            next_reopen_attempt_ = std::chrono::steady_clock::now() + std::chrono::seconds(1);
        }
        if (recovery_gate_.OnWriteFailure()) {
            log_line(stderr,
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
    // T2.6: decides, before muxing, whether this AU goes to the OBS TCP client.
    // A new client gets a fresh muxer (PAT/PMT first) at the next join point.
    // When OBS stops reading, queued frames are dropped instead of delivered
    // late, and the relay resumes on a join point once OBS reads again.
    bool AdmitTcpFrame(uint64_t arrivalUs, bool joinPoint) {
        // Reset before flushing: bytes muxed for an earlier client (or before
        // any client) end mid-stream and must never reach a new one.
        if (tcp_endpoint_.Poll()) ResetTcpClient();
        if (tcp_endpoint_.Connected() && !tcp_endpoint_.Flush(tcp_queue_)) ResetTcpClient();
        const bool backlogged = tcp_queue_.IsBacklogged(arrivalUs, ObsTcpFlowControl::kMaxBacklogUs);
        const bool wasStalled = tcp_flow_.Stalled();
        const uint64_t droppedBefore = tcp_flow_.DroppedFrames();
        const ObsTcpAction action = tcp_flow_.OnFrame(tcp_endpoint_.Connected(), backlogged, joinPoint);
        if (backlogged) tcp_queue_.DropUnsentFrames();
        if (!wasStalled && tcp_flow_.Stalled()) {
            stall_dropped_base_ = droppedBefore;
            log_line(stderr, "WARN: OBS stopped reading (source hidden or busy); dropping frames "
                             "instead of queueing them\n");
        } else if (wasStalled && !tcp_flow_.Stalled() && action == ObsTcpAction::Write) {
            log_line(stdout, "INFO: OBS reading again; resumed live at an HEVC keyframe after %llu dropped frames\n",
                     static_cast<unsigned long long>(tcp_flow_.DroppedFrames() - stall_dropped_base_));
        }
        if (action == ObsTcpAction::Drop) return false;
        tcp_queue_.BeginFrame(arrivalUs);
        return true;
    }

    // The client attached, changed, or failed: the next written AU is a join
    // point muxed by a fresh muxer, so the client starts with PAT/PMT.
    void ResetTcpClient() {
        Close(false);
        tcp_queue_.Clear();  // after Close: its flush lands in the queue
        tcp_flow_.OnClientChanged();
        // The recovery gate reopens the muxer on the next join point.
        recovery_gate_.OnReopenFailure();
        next_reopen_attempt_ = std::chrono::steady_clock::now();
    }

    void SendTcp() {
        // Wait for room only while OBS reads; a stalled OBS costs nothing.
        const int64_t waitUs = tcp_flow_.Stalled() ? 0 : kTcpSendWaitUs;
        if (!tcp_endpoint_.Flush(tcp_queue_, waitUs)) {
            // Flush closed the client: frames now drop before muxing until
            // Poll accepts a new one, which resets the muxer.
            tcp_queue_.Clear();
            return;
        }
        if (tcp_queue_.Size() > kMaxTcpQueueBytes) {
            log_line(stderr, "WARN: OBS TCP queue over %zu bytes; dropping the client\n", kMaxTcpQueueBytes);
            tcp_endpoint_.Disconnect();
            tcp_queue_.Clear();
        }
    }

    // A custom AVIO whose bytes land in tcp_queue_. FFmpeg owns the buffer
    // after this call; Close frees both.
    int OpenTcpIo() {
        auto* buffer = static_cast<unsigned char*>(av_malloc(kTcpIoBufferBytes));
        if (!buffer) return AVERROR(ENOMEM);
        context_->pb = avio_alloc_context(buffer, kTcpIoBufferBytes, 1, this, nullptr,
                                          &ObsUdpRelay::OnTcpMuxBytes, nullptr);
        if (!context_->pb) {
            av_free(buffer);
            return AVERROR(ENOMEM);
        }
        return 0;
    }

    static int OnTcpMuxBytes(void* opaque, const uint8_t* data, int size) {
        if (size > 0) static_cast<ObsUdpRelay*>(opaque)->tcp_queue_.Append(data, static_cast<size_t>(size));
        return size;
    }

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
        log_line(stderr, "ERROR: OBS relay %s failed: %s (%d)\n", operation, text, status);
        return false;
    }

    void Close(bool writeTrailer = true) noexcept {
        if (!context_) return;
        if (writeTrailer && header_written_ && context_->pb) {
            av_write_trailer(context_);
        }
        if (context_->pb) {
            if (tcp_) {
                avio_flush(context_->pb);
                av_freep(&context_->pb->buffer);
                avio_context_free(&context_->pb);
            } else {
                avio_closep(&context_->pb);
            }
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
    ArrivalTimestampClock arrival_clock_{};
    RelayRecoveryGate recovery_gate_{};
    int64_t last_mux_pts_ = AV_NOPTS_VALUE;
    AVPacket* out_packet_ = nullptr;
    std::chrono::steady_clock::time_point next_write_error_log_{};
    std::chrono::steady_clock::time_point next_reopen_attempt_{};
    // T2.6 TCP sink. Close() in the destructor writes the trailer into
    // tcp_queue_; members outlive the destructor body, so that is safe.
    bool tcp_ = false;
    ObsTcpSendQueue tcp_queue_{};
    ObsTcpFlowControl tcp_flow_{};
    ObsTcpEndpoint tcp_endpoint_{};
    uint64_t stall_dropped_base_ = 0;
};

static AVPixelFormat select_d3d11_format(AVCodecContext*, const AVPixelFormat* formats) {
    for (const AVPixelFormat* format = formats; *format != AV_PIX_FMT_NONE; ++format) {
        if (*format == AV_PIX_FMT_D3D11) return *format;
    }
    log_line(stderr, "WARN: HEVC decoder did not offer D3D11 output; using software decode\n");
    return formats[0];
}

// IPv4 adapters with their gateways, in `storage`. Returns nullptr on failure.
// The list can grow between calls, so retry a few times on ERROR_BUFFER_OVERFLOW.
static IP_ADAPTER_ADDRESSES* read_ipv4_adapters(std::vector<uint8_t>& storage) {
    ULONG bytes = 16 * 1024;
    for (int attempt = 0; attempt < 3; ++attempt) {
        storage.resize(bytes);
        auto* adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data());
        const ULONG status = GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_GATEWAYS,
                                                  nullptr, adapters, &bytes);
        if (status == NO_ERROR) return adapters;
        if (status != ERROR_BUFFER_OVERFLOW) return nullptr;
    }
    return nullptr;
}

// The iPhone USB network adapter (Apple Mobile Device Ethernet).
static bool is_apple_adapter(const IP_ADAPTER_ADDRESSES* adapter) {
    const wchar_t* name = adapter->FriendlyName ? adapter->FriendlyName : L"";
    const wchar_t* description = adapter->Description ? adapter->Description : L"";
    return wcsstr(name, L"Apple") || wcsstr(description, L"Apple");
}

// Windows can prefer an unrelated Wi-Fi default route when both Wi-Fi and the
// iPhone USB-tether adapter have the same metric. Bind explicitly to the IPv4
// address on the Apple adapter whose gateway is the requested iPhone host.
static bool bind_iphone_usb_interface(SOCKET socket, const char* host) {
    IN_ADDR requestedHost{};
    if (InetPtonA(AF_INET, host, &requestedHost) != 1) return false;

    std::vector<uint8_t> storage;
    IP_ADAPTER_ADDRESSES* adapters = read_ipv4_adapters(storage);
    if (!adapters) return false;

    for (auto* adapter = adapters; adapter; adapter = adapter->Next) {
        if (!is_apple_adapter(adapter)) continue;

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
                log_line(stdout, "INFO: bound iPhone USB network source=%s\n", address);
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

static SOCKET connect_tcp(const char* host, bool requireUsbInterface, unsigned portNumber = DEVICE_PORT) {
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char port[6]{};
    std::snprintf(port, sizeof(port), "%u", portNumber);
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
            log_line(stdout, "INFO: connected to iPhone USB network at %s:%u\n", host, portNumber);
        } else {
            log_line(stdout, "INFO: connected to iPhone at %s:%u (direct TCP)\n", host, portNumber);
        }
    }
    return socket;
}

static std::string discover_iphone_usb_host() {
    std::vector<uint8_t> storage;
    IP_ADAPTER_ADDRESSES* adapters = read_ipv4_adapters(storage);
    if (!adapters) return {};

    for (auto* adapter = adapters; adapter; adapter = adapter->Next) {
        if (!is_apple_adapter(adapter)) continue;
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
        if (*host == '\0') return INVALID_SOCKET;  // Wi-Fi discovery found nothing
        const SOCKET direct = connect_tcp(host, false);
        if (direct == INVALID_SOCKET) {
            log_line(stderr, "WARN: direct TCP connect to %s:%u failed\n", host, DEVICE_PORT);
        }
        return direct;
    }
    // Native Apple Mobile Device Service/usbmux is the preferred USB path.
    // It does not rely on iPhone Personal Hotspot exposing an inbound port.
    usbmuxd_device_info_t *list = nullptr;
    const int count = usbmuxd_get_device_list(&list);
    // With several Apple devices on USB, IPHONE_CAMERA_UDID picks one; without
    // it the first USB device is used and the others are listed once.
    const char* wantedUdid = std::getenv("IPHONE_CAMERA_UDID");
    if (wantedUdid && *wantedUdid == '\0') wantedUdid = nullptr;
    const usbmuxd_device_info_t* usbDevice = nullptr;
    int usbDeviceCount = 0;
    for (int index = 0; index < count; ++index) {
        if (list[index].conn_type != CONNECTION_TYPE_USB) continue;
        ++usbDeviceCount;
        const bool wanted = wantedUdid ? std::strcmp(list[index].udid, wantedUdid) == 0 : usbDevice == nullptr;
        if (wanted && usbDevice == nullptr) usbDevice = &list[index];
    }
    static bool listedDevices = false;
    if (usbDeviceCount > 1 && !wantedUdid && !listedDevices) {
        listedDevices = true;
        for (int index = 0; index < count; ++index) {
            if (list[index].conn_type == CONNECTION_TYPE_USB) {
                log_line(stdout, "INFO: USB Apple device udid=%s\n", list[index].udid);
            }
        }
        log_line(stdout, "INFO: %d Apple devices on USB; using the first. Set IPHONE_CAMERA_UDID to choose.\n",
               usbDeviceCount);
    }
    static bool warnedMissingUdid = false;  // once, not on every 1 s retry
    if (wantedUdid && usbDevice == nullptr && usbDeviceCount > 0 && !warnedMissingUdid) {
        warnedMissingUdid = true;
        log_line(stderr, "WARN: no USB device with IPHONE_CAMERA_UDID=%s\n", wantedUdid);
    }
    if (usbDevice != nullptr) {
        const int device_handle = static_cast<int>(usbDevice->handle);
        log_line(stdout, "INFO: device_handle=%d udid=%s\n", device_handle, usbDevice->udid);
        int fd = usbmuxd_connect(device_handle, DEVICE_PORT);
        if (list != nullptr) usbmuxd_device_list_free(&list);
        if (fd >= 0) {
            log_line(stdout, "INFO: connected fd=%d\n", fd);
            // libusbmuxd exposes a legacy int descriptor. Preserve the full-width
            // SOCKET type for all Winsock calls after this compatibility boundary.
            return static_cast<SOCKET>(fd);
        }
        log_line(stderr, "WARN: usbmuxd_connect failed; trying USB network fallback\n");
    } else if (list != nullptr) {
        usbmuxd_device_list_free(&list);
    }

    // Personal Hotspot over USB remains a useful fallback when AMDS has not
    // enumerated the device yet.
    const SOCKET tcpSocket = connect_tcp(host, true);
    if (tcpSocket != INVALID_SOCKET) return tcpSocket;
    log_line(stderr, "ERROR: no iPhone USB transport available (AMDS/usbmux or USB network)\n");
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
        // Wait before each read instead of imposing a short receive timeout
        // option on the socket. A 4K HEVC packet can be large, and a brief USB scheduling
        // stall must not be treated as a broken iPhone connection.
        fd_set readable{};
        FD_SET(fd, &readable);
        const auto now = std::chrono::steady_clock::now();
        if (now >= deadline) {
            log_line(stderr, "WARN: timed out waiting for %s\n", part);
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
            log_line(stderr, "ERROR: select %s failed: WSA=%d\n", part, WSAGetLastError());
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
                log_line(stderr, "ERROR: iPhone closed connection while reading %s (%zu/%zu bytes)\n", part, got, n);
            } else {
                log_line(stderr, "ERROR: recv %s failed: WSA=%d\n", part, socketError);
            }
            return false;
        }
        got += static_cast<size_t>(r);
    }
    return true;
}

static AVCodecContext *init_decoder(DecodeTelemetry &telemetry) {
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_HEVC);
    if (!codec) { log_line(stderr, "ERROR: HEVC decoder not found\n"); return nullptr; }
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) { log_line(stderr, "ERROR: avcodec_alloc_context3 failed\n"); return nullptr; }

    // D3D11VA hardware acceleration.
    AVBufferRef *hw = nullptr;
    if (av_hwdevice_ctx_create(&hw, AV_HWDEVICE_TYPE_D3D11VA, nullptr, nullptr, 0) == 0) {
        telemetry.d3d11_requested = true;
        ctx->hw_device_ctx = av_buffer_ref(hw);
        ctx->get_format = select_d3d11_format;
        av_buffer_unref(&hw);
        log_line(stdout, "INFO: D3D11VA requested\n");
    } else {
        log_line(stdout, "WARN: D3D11VA unavailable, falling back to software\n");
    }

    if (avcodec_open2(ctx, codec, nullptr) < 0) {
        log_line(stderr, "ERROR: avcodec_open2 failed\n");
        avcodec_free_context(&ctx);
        return nullptr;
    }
    log_line(stdout, "INFO: HEVC decoder ready\n");
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
                    log_line(stdout, "INFO: verified GPU decode: D3D11 NV12 surface %dx%d\n",
                           frame->width, frame->height);
                }
                const uint64_t timestamp_us = frame->best_effort_timestamp == AV_NOPTS_VALUE
                    ? fallback_timestamp_us : static_cast<uint64_t>(frame->best_effort_timestamp);
                const HRESULT publish_hr = publisher.Publish(frame, timestamp_us);
                if (publish_hr == S_FALSE) {
                    ++telemetry.gpu_backpressure_drops;
                } else if (FAILED(publish_hr)) {
                    log_line(stderr, "ERROR: GPU frame publish failed: 0x%08lX\n",
                            static_cast<unsigned long>(publish_hr));
                }
            } else {
                ++telemetry.software_frames;
                if (!telemetry.first_frame_reported) {
                    telemetry.first_frame_reported = true;
                    log_line(stderr, "ERROR: decoder returned %s, not a D3D11 surface\n",
                            av_get_pix_fmt_name(static_cast<AVPixelFormat>(frame->format)));
                }
            }
            av_frame_unref(frame);
            continue;
        }
        if (status == AVERROR(EAGAIN) || status == AVERROR_EOF) return 0;
        log_line(stderr, "ERROR: avcodec_receive_frame failed: %d\n", status);
        return status;
    }
}

static void receive_session(SOCKET fd, ObsUdpRelay* relay) {
    const bool obsUdpRelay = relay != nullptr;
    DecodeTelemetry decodeTelemetry{};
    GpuFramePublisher gpuPublisher{};
    AVCodecContext *dec = obsUdpRelay ? nullptr : init_decoder(decodeTelemetry);
    StreamTimingStats timing;
    timing.BeginSession();
    AVPacket *packet = av_packet_alloc();
    AVFrame *decodedFrame = av_frame_alloc();
    if (!packet || !decodedFrame) {
        log_line(stderr, "ERROR: FFmpeg packet/frame allocation failed\n");
        av_packet_free(&packet);
        av_frame_free(&decodedFrame);
        if (dec) avcodec_free_context(&dec);
        return;
    }

    std::vector<uint8_t> hdr(STREAM_HEADER_SIZE);
    uint64_t frames = 0, decoded = 0;
    uint64_t skippedUntilRandomAccess = 0, relayWriteFailures = 0, relayGateDrops = 0;
    bool waitingForRandomAccess = true;
    uint64_t previousTimestampUs = 0;
    SourceGapCounter sourceGapFrames;
    // STAT rates cover the frames since the previous STAT line, so a problem
    // in hour three of a long stream is not averaged away.
    auto windowStart = std::chrono::steady_clock::now();
    uint64_t windowStartFrame = 0, windowStartSourceUs = 0;
    log_line(stdout, "INFO: waiting for first HEVC frame from iPhone\n");

    while (true) {
        if (!read_exact(fd, hdr.data(), STREAM_HEADER_SIZE, "stream header", kHeaderIdleTimeoutMs)) break;
        stream_header_t h = {};
        if (!stream_header_read(hdr.data(), &h) || !stream_header_is_valid(&h)) {
            log_line(stderr, "ERROR: invalid stream header, stream desync\n");
            break;
        }
        if (h.codec != STREAM_CODEC_HEVC) {
            log_line(stderr, "ERROR: unsupported stream codec %u\n", static_cast<unsigned>(h.codec));
            break;
        }
        // av_new_packet supplies AV_INPUT_BUFFER_PADDING_SIZE zero bytes, which
        // optimized FFmpeg bitstream readers are allowed to read past payload.
        if (av_new_packet(packet, static_cast<int>(h.frame_size)) < 0) {
            log_line(stderr, "ERROR: av_new_packet failed for %u bytes\n", h.frame_size);
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
                    log_line(stderr,
                            "INFO: waiting for HEVC VPS/SPS/PPS+IDR join AU; "
                            "skipped %llu frames\n",
                            static_cast<unsigned long long>(skippedUntilRandomAccess));
                }
                av_packet_unref(packet);
                continue;
            }
            if (dec) avcodec_flush_buffers(dec);
            waitingForRandomAccess = false;
            log_line(stdout, "INFO: HEVC decoder-join AU received after %llu skipped frames\n",
                   static_cast<unsigned long long>(skippedUntilRandomAccess));
        }

        if (frames == 0) {
            log_line(stdout, "INFO: first HEVC packet=%u bytes frame=%u\n",
                   h.frame_size, h.frame_number);
            windowStart = std::chrono::steady_clock::now();
            windowStartFrame = 1;
            windowStartSourceUs = h.timestamp_us;
        }
        // Learns the 60 or 30 fps cadence, so Cinematic frames are not gaps.
        sourceGapFrames.OnTimestamp(h.timestamp_us);
        previousTimestampUs = h.timestamp_us;

        frames++;

        if (obsUdpRelay) {
            const RelayWriteResult written = relay->Write(*packet, arrivalUs, accessUnit);
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
                log_line(stderr, "ERROR: avcodec_send_packet failed: %d\n", status);
            } else {
                drain_decoder(dec, decodedFrame, decoded, decodeTelemetry, gpuPublisher,
                              h.timestamp_us);
            }
        }
        av_packet_unref(packet);

        if (frames % 120 == 0) {
            const auto now = std::chrono::steady_clock::now();
            const double windowSeconds = std::chrono::duration<double>(now - windowStart).count();
            const double windowIntervals = static_cast<double>(frames - windowStartFrame);
            const double recvFps = windowSeconds > 0 ? windowIntervals / windowSeconds : 0.0;
            const double sourceSeconds = previousTimestampUs > windowStartSourceUs
                ? static_cast<double>(previousTimestampUs - windowStartSourceUs) / 1'000'000.0 : 0.0;
            const double sourceFps = sourceSeconds > 0 ? windowIntervals / sourceSeconds : 0.0;
            log_line(stdout, "STAT: recv=%.1f fps sourcePTS=%.1f gaps=%llu relayDrop=%llu relayGateDrop=%llu decode=%llu gpu=%llu cpu=%llu ringDrop=%llu "
                   "extraDelayMs=%.1f maxExtraMs=%.1f maxGapMs=%.1f burst=%u skewMs=%.1f mode=%s frames\n",
                   recvFps, sourceFps,
                   static_cast<unsigned long long>(sourceGapFrames.GapFrames()),
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
                   obsUdpRelay ? (relay->IsTcp() ? "OBS_TCP_HEVC" : "OBS_UDP_HEVC") : "GPU_RING");
            timing.ResetWindow();
            windowStart = now;
            windowStartFrame = frames;
            windowStartSourceUs = previousTimestampUs;
        }
    }

    av_packet_free(&packet);
    av_frame_free(&decodedFrame);
    if (dec) avcodec_free_context(&dec);
    log_line(stdout, "INFO: done, received %llu frames\n",
           static_cast<unsigned long long>(frames));
}

// T3.3: find the phone on the LAN through Bonjour (_ipcamstream._tcp) with the
// Windows DNS-SD API. Everything announced on the LAN is untrusted: the pure
// validators in wifi_discovery.h decide what we will connect to.
namespace {
struct WifiDiscoveryState {
    std::mutex mutex;
    uintptr_t generation = 0;  // callbacks from an older attempt are ignored
    std::string instance;      // validated service instance name
    std::string host;          // validated dotted IPv4 address
    HANDLE event = nullptr;    // signalled when the current step has a result
};
WifiDiscoveryState g_wifi;

// ASCII-only narrowing: anything else is rejected by the validator.
std::string narrow_ascii(const wchar_t* wide) {
    std::string out;
    if (wide == nullptr) return out;
    for (; *wide != L'\0' && out.size() <= wifi_discovery::kMaxNameBytes; ++wide) {
        out.push_back(*wide < 0x80 ? static_cast<char>(*wide) : '\x7F');
    }
    return out;
}

VOID WINAPI on_wifi_browse(DWORD status, PVOID context, PDNS_RECORD records) {
    if (records == nullptr) return;
    if (status == ERROR_SUCCESS) {
        std::lock_guard<std::mutex> lock(g_wifi.mutex);
        if (reinterpret_cast<uintptr_t>(context) == g_wifi.generation && g_wifi.instance.empty()) {
            for (auto* record = reinterpret_cast<PDNS_RECORDW>(records); record != nullptr;
                 record = record->pNext) {
                // TTL 0 is a goodbye: the service went away.
                if (record->wType != DNS_TYPE_PTR || record->dwTtl == 0) continue;
                const std::string name = narrow_ascii(record->Data.PTR.pNameHost);
                if (!wifi_discovery::IsServiceInstanceName(name)) continue;
                g_wifi.instance = name;
                SetEvent(g_wifi.event);
                break;
            }
        }
    }
    DnsRecordListFree(records, DnsFreeRecordList);
}

VOID WINAPI on_wifi_resolve(DWORD status, PVOID context, PDNS_SERVICE_INSTANCE instance) {
    if (instance == nullptr) return;
    if (status == ERROR_SUCCESS && instance->ip4Address != nullptr) {
        uint8_t octets[4];
        std::memcpy(octets, instance->ip4Address, sizeof(octets));  // network order
        const auto host = wifi_discovery::FormatEndpoint(octets, instance->wPort, DEVICE_PORT);
        std::lock_guard<std::mutex> lock(g_wifi.mutex);
        if (reinterpret_cast<uintptr_t>(context) == g_wifi.generation && host) {
            g_wifi.host = *host;
            SetEvent(g_wifi.event);
        }
    }
    DnsServiceFreeInstance(instance);
}

// Waits in short slices so a stop request is noticed quickly.
bool wait_wifi_step(int timeoutMs) {
    for (int waited = 0; waited < timeoutMs && !g_stopRequested.load(); waited += 100) {
        if (WaitForSingleObject(g_wifi.event, 100) == WAIT_OBJECT_0) return true;
    }
    return false;
}
}  // namespace

// Returns the phone's IPv4 address, or an empty string when none was found.
// Never fatal: the caller retries on the next connection attempt.
static std::string discover_iphone_wifi_host() {
    constexpr int kStepTimeoutMs = 3000;
    if (g_wifi.event == nullptr) g_wifi.event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (g_wifi.event == nullptr) return std::string();

    uintptr_t generation;
    {
        std::lock_guard<std::mutex> lock(g_wifi.mutex);
        generation = ++g_wifi.generation;
        g_wifi.instance.clear();
        g_wifi.host.clear();
        ResetEvent(g_wifi.event);
    }
    DNS_SERVICE_CANCEL browseCancel{};
    DNS_SERVICE_BROWSE_REQUEST browse{};
    browse.Version = DNS_QUERY_REQUEST_VERSION1;
    browse.QueryName = L"_ipcamstream._tcp.local";
    browse.pBrowseCallback = on_wifi_browse;
    browse.pQueryContext = reinterpret_cast<PVOID>(generation);
    if (DnsServiceBrowse(&browse, &browseCancel) != DNS_REQUEST_PENDING) {
        log_line(stderr, "WARN: Wi-Fi discovery could not start\n");
        return std::string();
    }
    const bool browsed = wait_wifi_step(kStepTimeoutMs);
    DnsServiceBrowseCancel(&browseCancel);
    std::string instance;
    {
        std::lock_guard<std::mutex> lock(g_wifi.mutex);
        instance = g_wifi.instance;
        generation = ++g_wifi.generation;  // late browse callbacks are now ignored
        ResetEvent(g_wifi.event);
    }
    if (!browsed || instance.empty()) return std::string();
    log_line(stdout, "INFO: Wi-Fi discovery: found service %s; resolving its address\n", instance.c_str());

    std::wstring query(instance.begin(), instance.end());
    DNS_SERVICE_CANCEL resolveCancel{};
    DNS_SERVICE_RESOLVE_REQUEST resolve{};
    resolve.Version = DNS_QUERY_REQUEST_VERSION1;
    resolve.QueryName = query.data();
    resolve.pResolveCompletionCallback = on_wifi_resolve;
    resolve.pQueryContext = reinterpret_cast<PVOID>(generation);
    if (DnsServiceResolve(&resolve, &resolveCancel) != DNS_REQUEST_PENDING) {
        log_line(stderr, "WARN: Wi-Fi discovery could not resolve %s\n", instance.c_str());
        return std::string();
    }
    const bool resolved = wait_wifi_step(kStepTimeoutMs);
    DnsServiceResolveCancel(&resolveCancel);
    std::string host;
    {
        std::lock_guard<std::mutex> lock(g_wifi.mutex);
        host = g_wifi.host;
        ++g_wifi.generation;
    }
    if (!resolved || host.empty()) {
        log_line(stderr, "WARN: Wi-Fi discovery: %s did not resolve to a usable IPv4 address\n", instance.c_str());
        return std::string();
    }
    log_line(stdout, "INFO: Wi-Fi discovery found %s at %s\n", instance.c_str(), host.c_str());
    return host;
}

static constexpr int kReconnectDelayMs = 250;    // after a session ends
static constexpr int kNoDeviceRetryMs = 1'000;   // while no phone answers

// Sleeps in 50 ms slices so a stop request is not delayed.
static void sleep_unless_stopped(int totalMs) {
    for (int waited = 0; waited < totalMs && !g_stopRequested.load(); waited += 50) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
}

// T6.1: after a session starts, ask the phone for a pending crash report once.
// The phone listens on a separate port only while it holds an undelivered
// report, so normally this is one refused connection. It runs on its own short
// thread with bounded timeouts and never touches the video path.
static std::atomic<bool> g_crashFetchBusy{false};

static SOCKET connect_crash_port(const std::string& host, bool directTcp) {
    const unsigned port = crash_report::kPort;
    if (directTcp) {
        return host.empty() ? INVALID_SOCKET : connect_tcp(host.c_str(), false, port);
    }
    // Same device choice as connect_to_device: IPHONE_CAMERA_UDID, else the
    // first USB device, so the report comes from the phone that streams.
    const char* wantedUdid = std::getenv("IPHONE_CAMERA_UDID");
    if (wantedUdid && *wantedUdid == '\0') wantedUdid = nullptr;
    usbmuxd_device_info_t* list = nullptr;
    const int count = usbmuxd_get_device_list(&list);
    int handle = -1;
    for (int index = 0; index < count; ++index) {
        if (list[index].conn_type != CONNECTION_TYPE_USB) continue;
        if (wantedUdid && std::strcmp(list[index].udid, wantedUdid) != 0) continue;
        handle = static_cast<int>(list[index].handle);
        break;
    }
    if (list != nullptr) usbmuxd_device_list_free(&list);
    if (handle >= 0) {
        const int fd = usbmuxd_connect(handle, port);
        if (fd >= 0) return static_cast<SOCKET>(fd);
    }
    return connect_tcp(host.c_str(), true, port);  // Personal Hotspot fallback
}

// Wide (UTF-16) paths throughout: the ANSI APIs turn a non-ASCII folder name
// (for example a user name outside the ANSI code page) into '?' and fail.
static std::wstring crash_report_directory() {
    std::vector<wchar_t> path(MAX_PATH);
    DWORD length = 0;
    // Long-path aware: grow the buffer while the module path is truncated.
    for (int attempt = 0; attempt < 4; ++attempt) {
        length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
        if (length < path.size()) break;
        path.resize(path.size() * 2);
        length = 0;
    }
    std::wstring directory(path.data(), length);
    const size_t slash = directory.find_last_of(L"\\/");
    directory = slash == std::wstring::npos ? std::wstring(L".") : directory.substr(0, slash);
    return directory + L"\\crash-reports";
}

// The file name is ASCII by construction (crash_report::FileName).
static std::wstring widen_ascii(const std::string& text) {
    return std::wstring(text.begin(), text.end());
}

// UTF-8 for the log line; a failed conversion logs an empty path, not garbage.
static std::string utf8_path(const std::wstring& path) {
    const int bytes = WideCharToMultiByte(CP_UTF8, 0, path.c_str(), static_cast<int>(path.size()),
                                          nullptr, 0, nullptr, nullptr);
    if (bytes <= 0) return std::string();
    std::string out(static_cast<size_t>(bytes), '\0');
    WideCharToMultiByte(CP_UTF8, 0, path.c_str(), static_cast<int>(path.size()),
                        out.data(), bytes, nullptr, nullptr);
    return out;
}

static void fetch_crash_report(std::string host, bool directTcp) {
    const SOCKET fd = connect_crash_port(host, directTcp);
    if (fd != INVALID_SOCKET) {
        uint8_t header[crash_report::kHeaderSize];
        const bool gotHeader = read_exact(fd, header, sizeof(header), "crash report header", 5'000);
        const auto length = gotHeader ? crash_report::ParseHeader(header) : std::nullopt;
        if (gotHeader && !length) {
            log_line(stderr, "WARN: ignoring an invalid crash report header from the phone\n");
        } else if (length) {
            std::vector<uint8_t> payload(*length);
            if (read_exact(fd, payload.data(), payload.size(), "crash report", 10'000)) {
                const std::wstring directory = crash_report_directory();
                CreateDirectoryW(directory.c_str(), nullptr);  // fine if it already exists
                SYSTEMTIME now{};
                GetLocalTime(&now);
                const std::wstring widePath = directory + L"\\" + widen_ascii(
                    crash_report::FileName(now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond));
                const std::string path = utf8_path(widePath);
                FILE* file = _wfopen(widePath.c_str(), L"wb");
                const bool saved = file != nullptr &&
                    std::fwrite(payload.data(), 1, payload.size(), file) == payload.size();
                if (file != nullptr) std::fclose(file);
                if (saved) {
                    const char ack = static_cast<char>(crash_report::kAck);
                    send(fd, &ack, 1, 0);  // only now may the phone delete its copy
                    log_line(stdout, "INFO: iPhone crash report saved to %s (%zu bytes)\n", path.c_str(), payload.size());
                } else {
                    log_line(stderr, "WARN: could not save the iPhone crash report to %s\n", path.c_str());
                }
            }
        }
        closesocket(fd);
    }
    g_crashFetchBusy.store(false);
}

static void start_crash_report_fetch(const std::string& host, bool directTcp) {
    bool expected = false;
    if (!g_crashFetchBusy.compare_exchange_strong(expected, true)) return;
    std::thread(fetch_crash_report, host, directTcp).detach();
}

static int run_receiver(bool obsUdpRelay, bool obsTcp, const std::string& usbNetworkHost,
                        bool directTcp, bool wifiDiscover) {
    // Keep one MPEG-TS muxer alive across phone reconnects. This preserves its
    // transport-stream continuity counters and the OBS-facing timestamp domain.
    // This helper also guarantees the relay closes while Winsock is still live.
    ObsUdpRelay relay;
    if (obsUdpRelay && obsTcp) relay.UseTcp();
    if (obsUdpRelay && !relay.Open(false)) {
        // Never exit on an OBS-side failure (R-ENG-ERR): keep receiving and
        // reopen the relay on the first decoder-join AU.
        log_line(stderr, "WARN: OBS relay could not open; retrying on the next HEVC keyframe\n");
        relay.ArmRecovery();
    }

    while (!g_stopRequested.load()) {
        // Wi-Fi mode looks the phone up on every attempt: a DHCP lease may have
        // moved it. No result is a normal retry, never an exit (R-ENG-ERR).
        std::string target = usbNetworkHost;
        if (wifiDiscover) target = discover_iphone_wifi_host();
        if (wifiDiscover && target.empty() && !g_stopRequested.load()) {
            log_line(stderr, "INFO: no iPhone found on Wi-Fi (is Wi-Fi mode on in the app?)\n");
        }
        const SOCKET fd = connect_to_device(target.c_str(), directTcp || wifiDiscover);
        if (fd != INVALID_SOCKET) {
            // Keep Windows from sleeping while a phone streams: OBS blocks
            // sleep only while it records or streams, not while it previews.
            // The display may still turn off.
            SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);
            start_crash_report_fetch(target, directTcp || wifiDiscover);
            receive_session(fd, obsUdpRelay ? &relay : nullptr);
            SetThreadExecutionState(ES_CONTINUOUS);
            closesocket(fd);
            if (g_stopRequested.load()) break;
            // The phone is usually still there (app relaunch, preset change,
            // a timed-out frame): reconnect quickly so OBS freezes briefly.
            log_line(stderr, "WARN: stream ended; reconnecting in 250 ms\n");
            sleep_unless_stopped(kReconnectDelayMs);
        } else {
            log_line(stderr, "INFO: retrying iPhone connection in 1 second\n");
            sleep_unless_stopped(kNoDeviceRetryMs);
        }
    }
    log_line(stdout, "INFO: stop requested; closing OBS relay\n");
    return 0;
}

// Ctrl+C, Ctrl+Break and closing the console window all request a clean stop.
// The relay then writes its MPEG-TS trailer and closes before WSACleanup.
// The handler runs on its own thread.
static BOOL WINAPI console_control_handler(DWORD event) {
    switch (event) {
        case CTRL_C_EVENT:
        case CTRL_BREAK_EVENT:
            g_stopRequested.store(true);
            return TRUE;
        case CTRL_CLOSE_EVENT:
            g_stopRequested.store(true);
            // Windows terminates the process as soon as this handler returns
            // (and after about 5 s regardless). Wait for main to finish the
            // clean shutdown; every wait in the receiver is sliced at <= 250 ms.
            if (g_stoppedEvent) WaitForSingleObject(g_stoppedEvent, kCloseWaitMs);
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
    // Our lines bypass the CRT buffers (log_line). Redirected to a file, stdout
    // would otherwise be fully buffered, so keep any library output on it
    // unbuffered too: in order with stderr, and not lost if the process dies.
    setvbuf(stdout, nullptr, _IONBF, 0);
    WSADATA winsock{};
    if (WSAStartup(MAKEWORD(2, 2), &winsock) != 0) {
        log_line(stderr, "ERROR: WSAStartup failed\n");
        return 1;
    }
    disable_console_quick_edit();
    g_stoppedEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    SetConsoleCtrlHandler(console_control_handler, TRUE);

    // Keep running across app restarts, lock/unlock recovery, and USB reconnects.
    // A double-clicked receiver must wait for the iPhone instead of flashing away.
    const char* environmentHost = std::getenv("IPHONE_CAMERA_HOST");
    // OBS relay is the production path.  Make it the double-click/default
    // behavior so users do not have to remember a command-line switch.
    bool obsUdpRelay = true;
    bool obsTcp = false;  // T2.6: opt-in until validated on the device (DC)
    const char* explicitHost = nullptr;
    const char* directHost = nullptr;
    bool wifiDiscover = false;
    for (int index = 1; index < argc; ++index) {
        if (std::strcmp(argv[index], "--obs-udp") == 0) {
            obsUdpRelay = true;
            obsTcp = false;
        } else if (std::strcmp(argv[index], "--obs-tcp") == 0) {
            obsUdpRelay = true;
            obsTcp = true;
        } else if (std::strcmp(argv[index], "--gpu-ring") == 0) {
            // Retain the old diagnostic publisher only for development.
            obsUdpRelay = false;
        } else if (std::strcmp(argv[index], "--wifi") == 0) {
            wifiDiscover = true;
        } else if (std::strcmp(argv[index], "--host") == 0) {
            if (index + 1 >= argc) {
                log_line(stderr, "Usage: receiver.exe [--obs-udp|--obs-tcp|--gpu-ring] [--wifi | --host <iPhone address>] [iPhone USB host]\n");
                return 2;
            }
            directHost = argv[++index];
        } else if (!explicitHost) {
            explicitHost = argv[index];
        } else {
            log_line(stderr, "Usage: receiver.exe [--obs-udp|--obs-tcp|--gpu-ring] [--wifi | --host <iPhone address>] [iPhone USB host]\n");
            return 2;
        }
    }
    // An explicit --host wins over discovery. A positional USB host is a USB
    // setting and makes no sense together with Wi-Fi discovery.
    if (directHost != nullptr) wifiDiscover = false;
    if (wifiDiscover && explicitHost != nullptr) {
        log_line(stderr, "ERROR: --wifi cannot be combined with a USB host argument\n");
        return 2;
    }
    const bool directTcp = directHost != nullptr;
    const std::string discoveredHost = (directTcp || wifiDiscover) ? std::string() : discover_iphone_usb_host();
    const std::string usbNetworkHost = directTcp ? directHost : explicitHost ? explicitHost :
        (environmentHost && *environmentHost ? environmentHost :
         (discoveredHost.empty() ? kPersonalHotspotGateway : discoveredHost));
    log_line(stdout, "INFO: iPhone Camera USB receiver build=%s\n",
           !obsUdpRelay ? "GPU_RING_DIAGNOSTICS_V2" : obsTcp ? "OBS_TCP_HEVC_RELAY_V1" : "OBS_UDP_HEVC_RELAY_V1");
    if (wifiDiscover) {
        log_line(stdout, "INFO: iPhone Camera receiver started; Wi-Fi discovery (_ipcamstream._tcp) port=%u\n",
               DEVICE_PORT);
    } else if (directTcp) {
        log_line(stdout, "INFO: iPhone Camera receiver started; direct TCP host=%s port=%u\n",
               usbNetworkHost.c_str(), DEVICE_PORT);
    } else {
        log_line(stdout, "INFO: iPhone Camera USB receiver started; USB-network host=%s port=%u\n",
               usbNetworkHost.c_str(), DEVICE_PORT);
    }
    const int receiverStatus = run_receiver(obsUdpRelay, obsTcp, usbNetworkHost, directTcp, wifiDiscover);
    WSACleanup();
    if (g_wifi.event) CloseHandle(g_wifi.event);
    // Let a waiting close-window handler return now that shutdown is complete.
    // The handle stays open: the handler thread may still be waiting on it.
    if (g_stoppedEvent) SetEvent(g_stoppedEvent);
    return receiverStatus;
}
