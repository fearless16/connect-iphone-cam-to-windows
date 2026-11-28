#!/usr/bin/env sh
# Focused static contract for ObsUdpRelay. The CI SDK builds the production
# receiver; this test keeps lifecycle and timestamp invariants checkable even
# where FFmpeg headers/libraries are unavailable to the local test runner.
set -eu
# A bare "! grep" never fails under set -e (POSIX); forbid() does.
forbid() { if grep "$@"; then echo "forbidden pattern present: $*" >&2; exit 1; fi; }

receiver="$1"

awk '
  /status = avformat_write_header\(context_, &options\);/ { header_call = NR }
  /Report\("avformat_write_header", status\);/ { header_check = NR }
  /header_written_ = true;/ { header_mark = NR }
  /if \(writeTrailer && header_written_ && context_->pb\) \{/ { trailer_guard = NR }
  /av_write_trailer\(context_\);/ { trailer = NR }
  /if \(context_->pb\) \{/ { io_guard = NR }
  /avio_closep\(&context_->pb\);/ { io_close = NR }
  /header_written_ = false;/ { header_reset = NR }
  END {
    if (!(header_call && header_call < header_check && header_check < header_mark)) {
      print "header_written_ must be marked only after a successful avformat_write_header" > "/dev/stderr"; exit 1
    }
    if (!(trailer_guard && trailer_guard < trailer && trailer < io_guard && io_guard < io_close && io_close < header_reset)) {
      print "relay Close must trailer only after header success, then always close opened IO" > "/dev/stderr"; exit 1
    }
  }
' "$receiver"

# Rescale into MPEG-TS's usual 90 kHz time base without unsigned subtraction.
# An earlier or repeated arrival must still advance PTS instead of producing a
# giant value or a non-monotonic DTS.
[ $((16667 * 90000 / 1000000)) -eq 1500 ]
# G5: relay timeline follows PC arrival time
grep -q 'ArrivalTimestampClock' "$receiver"
grep -q 'arrival_clock_.Stamp(arrivalUs)' "$receiver"
grep -q 'relay->Write(\*packet, arrivalUs, accessUnit)' "$receiver"
grep -q "av_rescale_q(static_cast<int64_t>(relativeUs)" "$receiver"
grep -q 'std::max(candidatePts, last_mux_pts_ + 1)' "$receiver"
forbid -q 'timestampUs - first_timestamp_us_' "$receiver"

# The UDP muxer and timestamp clock must outlive individual iPhone TCP
# sessions. Reopening them per session resets both MPEG-TS continuity counters
# and OBS-facing timestamps.
grep -q 'static void receive_session(SOCKET fd, ObsUdpRelay\* relay)' "$receiver"
# G5: arrival time is one continuous PC clock, so nothing restarts the relay
# timeline per phone session (the per-session BeginSession rebase is gone).
forbid -q 'relay->BeginSession()' "$receiver"
forbid -q 'arrival_clock_ = ' "$receiver"
[ "$(grep -c 'ObsUdpRelay relay;' "$receiver")" -eq 1 ]
grep -q 'receive_session(fd, obsUdpRelay ? &relay : nullptr)' "$receiver"

# Winsock must remain initialized while ObsUdpRelay's destructor closes FFmpeg
# UDP AVIO. A helper scope guarantees relay destruction before WSACleanup on
# every return path, including an Open() failure.
grep -q 'static int run_receiver(' "$receiver"
awk '
  /const int receiverStatus = run_receiver\(/ { run_line = NR }
  /WSACleanup\(\);/ { cleanup_line = NR }
  /return receiverStatus;/ { return_line = NR }
  END { exit !(run_line && run_line < cleanup_line && cleanup_line < return_line) }
' "$receiver"

# Persistent mux writes must self-heal without exiting the receiver. Recovery
# closes the broken AVIO without trying another trailer write, drops delta
# frames, rate-limits reopen attempts, and reopens only on a fresh decoder-join AU.
grep -q '#include "relay_recovery.h"' "$receiver"
grep -q 'recovery_gate_.OnWriteFailure()' "$receiver"
grep -q 'Close(false);' "$receiver"
grep -q 'RelayRecoveryAction::Drop' "$receiver"
grep -q 'RelayRecoveryAction::ReopenAndWrite' "$receiver"
grep -q 'next_reopen_attempt_ = now + std::chrono::seconds(1)' "$receiver"
grep -q '#include "hevc_access_unit.h"' "$receiver"
grep -q 'InspectHevcAccessUnit(packet->data, h.frame_size)' "$receiver"
grep -q 'accessUnit.IsDecoderJoinPoint()' "$receiver"
forbid -q 'contains_hevc_idr' "$receiver"
forbid -q 'exit(.*OBS relay' "$receiver"

# A reopened MPEG-TS transport resets continuity counters. Tell OBS about that
# discontinuity only on recovery; the initial muxer must remain a normal start.
grep -q 'bool Open(bool isRecovery)' "$receiver"
grep -q 'av_dict_set(&options, "mpegts_flags", "+initial_discontinuity", 0)' "$receiver"
grep -q 'if (!Open(true))' "$receiver"
grep -q 'if (obsUdpRelay && !relay.Open(false))' "$receiver"

# Reopening AVIO is not recovery until the decoder-join AU itself is written.
# If that first write fails, throttle the next IDR reopen attempt too.
grep -q 'bool reopenedForThisWrite = false' "$receiver"
grep -q 'reopenedForThisWrite = true' "$receiver"
grep -q 'OBS relay recovered on fresh HEVC decoder-join AU' "$receiver"
grep -q 'next_reopen_attempt_ = std::chrono::steady_clock::now() + std::chrono::seconds(1)' "$receiver"
awk '
  /reopenedForThisWrite = true/ { reopened = NR }
  /const int status = av_interleaved_write_frame/ { write_call = NR }
  /if \(status >= 0\)/ { success = NR }
  /OBS relay recovered on fresh HEVC decoder-join AU/ { recovered_log = NR }
  END { exit !(reopened && reopened < write_call && write_call < success && success < recovered_log) }
' "$receiver"

# T2.6 (G6): --obs-tcp. The receiver listens for OBS on loopback only, never
# blocks on it, and drops frames instead of queueing them when OBS stops
# reading. The flow control lives in the pure, runtime-tested obs_tcp_flow.h.
grep -q '#include "obs_tcp_flow.h"' "$receiver"
grep -q 'address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);' "$receiver"
forbid -q 'INADDR_ANY' "$receiver"
grep -q 'SO_EXCLUSIVEADDRUSE' "$receiver"
grep -q 'listen(listener, 1)' "$receiver"
grep -q 'ioctlsocket(accepted, FIONBIO, &nonBlocking)' "$receiver"
grep -q 'WSAGetLastError() == WSAEWOULDBLOCK) {' "$receiver"
grep -q 'if (left <= 0) return true;' "$receiver"
forbid -q 'send(client_.*MSG_WAITALL' "$receiver"
grep -q 'std::strcmp(argv\[index\], "--obs-tcp") == 0' "$receiver"
grep -q 'if (obsUdpRelay && obsTcp) relay.UseTcp();' "$receiver"
# UDP stays the default until the TCP relay is validated on the device.
grep -q 'bool obsTcp = false;' "$receiver"
# Every AU passes the flow control before it is muxed.
grep -q 'if (tcp_ && !AdmitTcpFrame(arrivalUs, accessUnit.IsDecoderJoinPoint()))' "$receiver"
grep -q 'tcp_queue_.IsBacklogged(arrivalUs, ObsTcpFlowControl::kMaxBacklogUs)' "$receiver"
grep -q 'if (backlogged) tcp_queue_.DropUnsentFrames();' "$receiver"
# No forward PTS jump over the dropped frames (OBS would hold it as delay).
grep -q 'relativeUs = tcp_flow_.MapTimelineUs(relativeUs, kNominalFrameDurationUs);' "$receiver"
# A client change resets the muxer before anything is flushed to the new client.
awk '
  /bool AdmitTcpFrame\(/ { inside = 1 }
  inside && /if \(tcp_endpoint_.Poll\(\)\) ResetTcpClient\(\);/ { reset = NR }
  inside && /tcp_endpoint_.Flush\(tcp_queue_\)/ && !flush { flush = NR }
  inside && /^    }/ { inside = 0 }
  END { exit !(reset && flush && reset < flush) }
' "$receiver"
# Memory guard if flow control ever fails: drop the client, never grow.
grep -q 'tcp_queue_.Size() > kMaxTcpQueueBytes' "$receiver"
# The post-mux send may wait for socket room, bounded, and never while stalled.
grep -q 'static constexpr int64_t kTcpSendWaitUs = 4'"'"'000;' "$receiver"
grep -q 'const int64_t waitUs = tcp_flow_.Stalled() ? 0 : kTcpSendWaitUs;' "$receiver"
# OBS may open its input before the phone streams: listen when the relay opens.
grep -q 'if (tcp_) tcp_endpoint_.EnsureListening();' "$receiver"
