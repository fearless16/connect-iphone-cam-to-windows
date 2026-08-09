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

# MPEG-TS's usual 90 kHz time base: rebasing protects the muxer from an
# arbitrary device uptime while preserving frame spacing.
[ $(((1000000 - 1000000) * 90000 / 1000000)) -eq 0 ]
[ $(((1016667 - 1000000) * 90000 / 1000000)) -eq 1500 ]
[ $(((2000000 - 1000000) * 90000 / 1000000)) -eq 90000 ]

grep -q "av_rescale_q(relativeUs, AVRational{1, 1'000'000}, muxer_time_base_)" "$receiver"
