#!/usr/bin/env sh
set -eu

streamer="$1"
view_controller="$2"
app_icon="$3"
project="$4"
receiver="$5"

# Protocol timestamps must come from one monotonic clock and never regress,
# even when VideoToolbox delivers a delayed callback after recovery.
grep -q 'func nextProtocolTimestampUs()' "$streamer"
grep -q 'lastProtocolTimestampUs' "$streamer"
grep -q 'max(monotonicUs(), lastProtocolTimestampUs + 1)' "$streamer"
grep -q 'timestampUs: nextProtocolTimestampUs()' "$streamer"
! grep -q 'timestampUs: presentationTimestampUs(sampleBuffer)' "$streamer"

# Portrait is an explicit persisted output choice; changing it only rotates the
# video-data connection and rebuilds the encoder for the new buffer dimensions.
grep -q 'enum OutputOrientation' "$streamer"
grep -q 'UserDefaults.standard' "$streamer"
grep -q 'func setOutputOrientation' "$streamer"
grep -q 'isVideoRotationAngleSupported' "$streamer"
grep -q 'videoRotationAngle' "$streamer"
grep -q 'applyInitialOutputOrientation' "$streamer"
grep -q 'falling back to Landscape' "$streamer"
grep -q 'invalidateEncoder(reason: nil)' "$streamer"
grep -q 'is4KFrame(width: width, height: height)' "$streamer"
grep -q 'encoderGeneration' "$streamer"
grep -q 'sourceFrameRefcon' "$streamer"
grep -q 'isCurrentEncoderGeneration' "$streamer"
[ "$(grep -c 'isCurrentEncoderGeneration(generation)' "$streamer")" -ge 2 ]
grep -q 'UISegmentedControl' "$view_controller"
grep -q 'Portrait' "$view_controller"
grep -q 'Landscape' "$view_controller"
grep -q 'onOutputOrientation' "$view_controller"
grep -q 'confirmedOutputOrientation' "$view_controller"

# Runtime preference/UI changes happen only after AVFoundation accepts the
# requested rotation. Unsupported portrait leaves the existing choice intact.
awk '
  /func setOutputOrientation\(_ orientation: OutputOrientation\)/ { in_setter = 1 }
  in_setter && /let applied = self\.applyOutputOrientation/ { apply_line = NR }
  in_setter && /UserDefaults\.standard\.set\(orientation\.rawValue/ { persist_line = NR }
  END { exit !(apply_line && persist_line && apply_line < persist_line) }
' "$streamer"

# Xcode compiles a single 1024px marketing icon into all required device sizes.
test -f "$app_icon/Contents.json"
test -f "$app_icon/AppIcon-1024.png"
grep -q 'AppIcon-1024.png' "$app_icon/Contents.json"
grep -q 'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon' "$project"

# A stale or recovered sender must never underflow unsigned arithmetic or make
# MPEG-TS packet timestamps regress.
grep -q 'RelayTimestampClock' "$receiver"
grep -q 'timestamp_clock_.Rebase(timestampUs)' "$receiver"
grep -q 'last_mux_pts_' "$receiver"
grep -q 'std::max(candidatePts, last_mux_pts_ + 1)' "$receiver"
! grep -q 'timestampUs - first_timestamp_us_' "$receiver"
