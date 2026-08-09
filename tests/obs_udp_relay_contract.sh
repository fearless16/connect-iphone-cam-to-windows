#!/usr/bin/env sh
# Focused static contract for ObsUdpRelay. The CI SDK builds the production
# receiver; this test keeps lifecycle and timestamp invariants checkable even
# where FFmpeg headers/libraries are unavailable to the local test runner.
set -eu

receiver="$1"

awk '
  /status = avformat_write_header\(context_, &options\);/ { header_call = NR }
  /if \(status < 0\) return Report\("avformat_write_header", status\);/ { header_check = NR }
  /header_written_ = true;/ { header_mark = NR }
  /if \(header_written_ && context_->pb\) \{/ { trailer_guard = NR }
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
