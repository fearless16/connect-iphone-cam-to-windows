#!/usr/bin/env sh
# Focused static contract for ObsUdpRelay. The CI SDK builds the production
# receiver; this test keeps lifecycle and timestamp invariants checkable even
# where FFmpeg headers/libraries are unavailable to the local test runner.
set -eu

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

# Rebase into MPEG-TS's usual 90 kHz time base without unsigned subtraction.
# A backwards source timestamp must advance by one 60fps frame instead of
# producing a giant PTS value or a non-monotonic DTS.
[ $((16667 * 90000 / 1000000)) -eq 1500 ]
grep -q 'RelayTimestampClock' "$receiver"
grep -q 'timestamp_clock_.Rebase(timestampUs)' "$receiver"
grep -q "av_rescale_q(static_cast<int64_t>(relativeUs)" "$receiver"
grep -q 'std::max(candidatePts, last_mux_pts_ + 1)' "$receiver"
! grep -q 'timestampUs - first_timestamp_us_' "$receiver"

# The UDP muxer and timestamp clock must outlive individual iPhone TCP
# sessions. Reopening them per session resets both MPEG-TS continuity counters
# and OBS-facing timestamps.
grep -q 'static void receive_session(SOCKET fd, ObsUdpRelay\* relay)' "$receiver"
grep -q 'if (relay) relay->BeginSession();' "$receiver"
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
! grep -q 'contains_hevc_idr' "$receiver"
! grep -q 'exit(.*OBS relay' "$receiver"

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
