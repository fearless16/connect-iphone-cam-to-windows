#!/usr/bin/env sh
set -eu
# A bare "! grep" never fails under set -e (POSIX); forbid() does.
forbid() { if grep "$@"; then echo "forbidden pattern present: $*" >&2; exit 1; fi; }

receiver="$1"

# The receiver must be a durable USB-network bridge, not a console program
# that exits before the user opens the iPhone app.
grep -q 'WSAStartup' "$receiver"
# T1.9: a click in the console must not freeze the relay.
grep -q 'ENABLE_QUICK_EDIT_MODE' "$receiver"
grep -q 'discover_iphone_usb_host' "$receiver"
grep -q 'bind_iphone_usb_interface' "$receiver"
grep -q 'IPHONE_CAMERA_HOST' "$receiver"
grep -q 'connect_tcp' "$receiver"
grep -q 'USB network' "$receiver"
grep -q 'select_d3d11_format' "$receiver"
grep -q 'AV_PIX_FMT_D3D11' "$receiver"
grep -q 'verified GPU decode' "$receiver"
grep -q 'WSAEWOULDBLOCK' "$receiver"
forbid -q 'SO_RCVTIMEO' "$receiver"
grep -q 'select(0' "$receiver"
grep -q 'waiting for first HEVC frame' "$receiver"
grep -q 'first HEVC packet' "$receiver"
grep -q 'sourcePTS' "$receiver"
# Long streams: STAT rates are per window (not session averages), and Windows
# must not sleep while a phone session is active.
grep -q 'windowIntervals / windowSeconds' "$receiver"
grep -q 'SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)' "$receiver"
grep -q 'sourceGapFrames' "$receiver"
# Gaps follow the learned 60/30 fps cadence, not a fixed 60 fps frame.
grep -q 'sourceGapFrames.OnTimestamp(h.timestamp_us)' "$receiver"
grep -q 'sourceGapFrames.GapFrames()' "$receiver"
grep -q 'av_new_packet' "$receiver"
grep -q 'AV_INPUT_BUFFER_PADDING_SIZE' "$receiver"
grep -q 'drain_decoder' "$receiver"
grep -q 'for (;;)' "$receiver"
grep -q 'static SOCKET connect_tcp' "$receiver"
grep -q 'loopbackForward' "$receiver"
grep -q 'FIONBIO' "$receiver"
grep -q 'SO_ERROR' "$receiver"
grep -q 'kConnectTimeoutMs' "$receiver"
grep -q 'static SOCKET connect_to_device' "$receiver"
grep -q 'CONNECTION_TYPE_USB' "$receiver"
grep -q 'usbmuxd_device_list_free' "$receiver"
grep -q 'static bool read_exact(SOCKET fd' "$receiver"
grep -q 'const SOCKET fd = connect_to_device' "$receiver"
grep -q -- '--obs-udp' "$receiver"
grep -q -- '--gpu-ring' "$receiver"
grep -q 'bool obsUdpRelay = true' "$receiver"
grep -q 'avformat_alloc_output_context2' "$receiver"
grep -q 'av_interleaved_write_frame' "$receiver"
# G5: relay timeline follows PC arrival time
grep -q 'ArrivalTimestampClock' "$receiver"
grep -q 'arrival_clock_.Stamp(arrivalUs)' "$receiver"
grep -q 'relay->Write(\*packet, arrivalUs, accessUnit)' "$receiver"
grep -q 'std::max(candidatePts, last_mux_pts_ + 1)' "$receiver"
forbid -q 'timestampUs - first_timestamp_us_' "$receiver"
grep -q 'muxer_time_base_ = stream_->time_base' "$receiver"
grep -q 'relayWriteFailures' "$receiver"
forbid -q 'if (obsUdpRelay && !relay.Write' "$receiver"
grep -q 'ReportWriteFailure' "$receiver"
grep -q 'std::chrono::seconds(5)' "$receiver"
forbid -q 'return status >= 0 || Report("av_interleaved_write_frame", status)' "$receiver"
grep -q -- '--host' "$receiver"
grep -q 'requireUsbInterface' "$receiver"
grep -q 'direct TCP' "$receiver"
sh "$(dirname "$0")/obs_udp_relay_contract.sh" "$receiver"

# T2.1: arrival-timing stats and gate drops counted apart from write failures.
grep -q '#include "stream_timing.h"' "$receiver"
# T3.3: Wi-Fi discovery uses the Windows DNS-SD API; the pure validators gate what we connect to.
grep -q '#include "wifi_discovery.h"' "$receiver"
grep -q 'DnsServiceBrowse(' "$receiver"
grep -q 'DnsServiceResolve(' "$receiver"
grep -q '"--wifi"' "$receiver"
grep -q 'wifi_discovery::IsServiceInstanceName' "$receiver"
grep -q 'wifi_discovery::FormatEndpoint' "$receiver"
grep -q 'if (directHost != nullptr) wifiDiscover = false;' "$receiver"
grep -q 'timing.BeginSession()' "$receiver"
grep -q 'timing.OnFrame(h.timestamp_us, arrivalUs)' "$receiver"
grep -q 'timing.ResetWindow()' "$receiver"
grep -q 'relayGateDrop=%llu' "$receiver"
grep -q 'extraDelayMs=%.1f maxExtraMs=%.1f maxGapMs=%.1f burst=%u skewMs=%.1f' "$receiver"
grep -q 'enum class RelayWriteResult' "$receiver"
grep -q 'RelayWriteResult::GateDrop' "$receiver"

# Review fixes (fix/review-findings).
# No disk I/O on the video path (R-ENG-PERF): the dead stream dump is gone. The
# only file the receiver writes is the T6.1 crash report, once per session on
# its own thread: exactly one open, inside fetch_crash_report, nowhere else.
forbid -q 'kSaveReceivedStream' "$receiver"
forbid -q 'received.h265' "$receiver"
outside_crash_fetch=$(awk '/^static void fetch_crash_report\(/{skip=1} !skip{print} skip && /^}/{skip=0}' "$receiver")
if printf '%s\n' "$outside_crash_fetch" | grep -q 'fopen\|CreateFile\|ofstream'; then
  echo "receiver.cpp opens a file outside fetch_crash_report (R-ENG-PERF)" >&2
  exit 1
fi
[ "$(grep -c 'fopen(' "$receiver")" -eq 1 ] || {
  echo "receiver.cpp must open exactly one file (the crash report)" >&2
  exit 1
}
# An idle phone must not be mistaken for a dead one: the wait for the next
# header has its own, longer limit than the wait for the rest of a packet.
grep -q 'kHeaderIdleTimeoutMs = 15' "$receiver"
grep -q 'kPayloadTimeoutMs = 5' "$receiver"
grep -q 'read_exact(fd, hdr.data(), STREAM_HEADER_SIZE, "stream header", kHeaderIdleTimeoutMs)' "$receiver"
grep -q 'read_exact(fd, packet->data, h.frame_size, "video frame", kPayloadTimeoutMs)' "$receiver"
# The wire accepts H264 in the header, but this receiver only relays HEVC.
grep -q 'h.codec != STREAM_CODEC_HEVC' "$receiver"
grep -q 'unsupported stream codec' "$receiver"
# Ctrl+C / console close request a clean stop so the relay writes its trailer
# and closes before WSACleanup. Waits are sliced so a stop is noticed quickly.
grep -q '#include <atomic>' "$receiver"
grep -q 'std::atomic<bool> g_stopRequested' "$receiver"
grep -q 'SetConsoleCtrlHandler' "$receiver"
grep -q 'g_stopRequested.load()' "$receiver"
grep -q 'kWaitSliceMs' "$receiver"
grep -q 'while (!g_stopRequested.load())' "$receiver"
# T5.5: the relay announces the size from the SPS, not a fixed 4K.
grep -q 'HevcAccessUnitDimensions' "$receiver"
if grep -q 'codecpar->width = 3840' "$receiver"; then echo "relay must use the SPS size" >&2; exit 1; fi
