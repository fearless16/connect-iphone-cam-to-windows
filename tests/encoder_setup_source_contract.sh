#!/usr/bin/env sh
set -eu

source="$1"

grep -q 'CVPixelBufferGetWidth' "$source"
grep -q 'VTCompressionSessionPrepareToEncodeFrames' "$source"
grep -q 'kVTInvalidSessionErr' "$source"
grep -q 'resumeAfterForeground' "$source"
grep -q 'AVCaptureSessionRuntimeError' "$source"
grep -q 'AVCaptureSessionDidStopRunning' "$source"
grep -q 'mediaServicesWereReset' "$source"
grep -q 'SENSOR %.1f' "$source"
grep -q 'HEVC %.1f' "$source"
grep -q 'USB %.1f fps' "$source"
grep -q 'didDrop sampleBuffer' "$source"
grep -q 'alwaysDiscardsLateVideoFrames = true' "$source"
grep -q 'session.sessionPreset = .inputPriority' "$source"
grep -q 'refreshActiveFormatTelemetry(device)' "$source"
grep -q 'private let sessionQueue' "$source"
# T5.4: the format helper is generic over the preset.
grep -q 'private func applyFormat' "$source"
grep -q 'private func recoverSession' "$source"
grep -q 'private func scheduleRecovery' "$source"
grep -q 'private func scheduleRecoveryOnSessionQueue' "$source"
grep -q 'recoveryScheduled' "$source"
grep -q 'recoveryAttempt' "$source"
grep -q 'appIsActive' "$source"
grep -q 'handleSessionStopped' "$source"
grep -q 'sender.restartListening' "$source"
# T1.5: a healthy session is not rebuilt on foreground resume.
grep -q 'session.isInterrupted' "$source"
# T1.3: camera recovery keeps the PC connection (orientation still reconnects).
recover_body=$(awk '
  /private func recoverSession\(reason:/ { in_r = 1 }
  /private func scheduleRecovery\(reason:/ { in_r = 0 }
  in_r { print }
' "$source")
printf '%s
' "$recover_body" | grep -q 'resetForDiscontinuity'
if printf '%s
' "$recover_body" | grep -q 'restartListening'; then
  echo "recoverSession must not restartListening" >&2
  exit 1
fi
grep -q 'Encoder recovery' "$source"
grep -q 'HEVC encoder setup recovery' "$source"
# VideoToolbox may report an asynchronous output failure after EncodeFrame
# itself succeeded. That callback must not fail silently or invalidate the
# session from VideoToolbox's callback thread.
! grep -q 'guard let sb = sampleBuffer, status == noErr else { return }' "$source"
grep -q 'handleEncoderOutputFailure' "$source"
grep -q 'CAMERA encoder error • recovering' "$source"
grep -q 'Encoder callback recovery' "$source"
# A nil sample carrying VideoToolbox's documented frameDropped flag is normal
# pressure telemetry, not proof that the encoder session is broken.
grep -q 'if status == noErr,' "$source"
grep -q 'guard status == noErr, let sb = sampleBuffer else' "$source"
grep -q 'infoFlags.contains(.frameDropped)' "$source"
grep -q 'recordEncoderDrop' "$source"
grep -q 'encoderDropCount' "$source"
grep -q 'HEVC %llu' "$source"
awk '
  /outputCallback:/ { in_callback = 1 }
  in_callback && /infoFlags\.contains\(\.frameDropped\)/ { dropped_line = NR }
  in_callback && /handleEncoderOutputFailure/ { failure_line = NR }
  in_callback && /refcon: refcon/ {
    exit !(dropped_line && failure_line && dropped_line < failure_line)
  }
' "$source"
# The callback synchronously claims and quarantines one failed generation. A
# burst of delayed callbacks can therefore neither emit frames nor enqueue
# duplicate recoveries while VideoToolbox invalidation stays off its thread.
grep -q 'claimEncoderOutputFailure' "$source"
awk '
  /private func claimEncoderOutputFailure/ { in_claim = 1 }
  in_claim && /encoderStateLock\.lock\(\)/ { lock_line = NR }
  in_claim && /encoderGeneration == generation/ { generation_line = NR }
  in_claim && /encoder = nil/ { quarantine_line = NR }
  in_claim && /encoderGeneration &\+= 1/ { advance_line = NR }
  in_claim && /encoderSetupFailed = true/ { failed_line = NR }
  /private func handleEncoderOutputFailure/ {
    exit !(lock_line && generation_line && quarantine_line && advance_line && failed_line &&
           lock_line < generation_line && generation_line < quarantine_line &&
           quarantine_line < advance_line && advance_line < failed_line)
  }
' "$source"
awk '
  /private func handleEncoderOutputFailure/ { in_handler = 1 }
  in_handler && /claimEncoderOutputFailure\(generation:/ { claim_line = NR }
  in_handler && /sessionQueue\.async/ { async_line = NR }
  in_handler && /VTCompressionSessionInvalidate\(failedEncoder\)/ { invalidate_line = NR }
  in_handler && /scheduleRecoveryOnSessionQueue/ { recovery_line = NR }
  /private func isEncoderSetupFailed/ {
    exit !(claim_line && async_line && invalidate_line && recovery_line &&
           claim_line < async_line && async_line < invalidate_line &&
           invalidate_line < recovery_line)
  }
' "$source"
# Backoff resets only after the first successful output of a generation. It
# must not reset merely because recoverSession restarted capture, and the
# per-generation marker prevents dispatching one reset block per 60fps frame.
grep -q 'markEncoderOutputSuccessful' "$source"
grep -q 'recoveryBackoffResetGeneration' "$source"
awk '
  /private func recoverSession\(reason:/ { in_recover = 1 }
  in_recover && /recoveryAttempt = 0/ { premature_reset = 1 }
  /private func scheduleRecovery\(reason:/ { exit premature_reset ? 1 : 0 }
' "$source"
awk '
  /private func markEncoderOutputSuccessful/ { in_success = 1 }
  in_success && /encoderStateLock\.lock\(\)/ { lock_line = NR }
  in_success && /recoveryBackoffResetGeneration != generation/ { once_line = NR }
  in_success && /guard shouldResetBackoff else/ { guard_line = NR }
  in_success && /sessionQueue\.async/ { async_line = NR }
  in_success && /isCurrentEncoderGeneration\(generation\)/ { current_line = NR }
  in_success && /recoveryAttempt = 0/ { reset_line = NR }
  /private func claimEncoderOutputFailure/ {
    exit !(lock_line && once_line && guard_line && async_line && current_line && reset_line &&
           lock_line < once_line && once_line < guard_line && guard_line < async_line &&
           async_line < current_line && current_line < reset_line)
  }
' "$source"
grep -q 'automaticallyAdjustsVideoHDREnabled = false' "$source"
grep -q 'isVideoHDREnabled = false' "$source"
# T5.4: renamed from matching4K60Formats.
grep -q 'let matchingFormats = device.formats.filter' "$source"
grep -q 'matchingFormats.first(where:' "$source"
grep -q 'kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange' "$source"
auto_hdr_line=$(grep -n 'automaticallyAdjustsVideoHDREnabled = false' "$source" | head -n1 | cut -d: -f1)
format_line=$(grep -n 'device.activeFormat = format' "$source" | head -n1 | cut -d: -f1)
hdr_line=$(grep -n 'device.isVideoHDREnabled = false' "$source" | head -n1 | cut -d: -f1)
[ "$auto_hdr_line" -lt "$format_line" ]
[ "$format_line" -lt "$hdr_line" ]
# T5.4: the rate comes from the preset and transport; 4K over USB keeps the
# previous 40 Mbps average and 10 MB/s limit.
grep -q 'AverageBitRate, value: NSNumber(value: target)' "$source"
grep -q 'case .p2160: return (usb: 40_000_000, wifi: 25_000_000)' "$source"
grep -q '\[NSNumber(value: target / 4), NSNumber(value: 1)\] as CFArray' "$source"
# T5.4: the other G8 prime rates and the 60 fps presets.
grep -q 'case .p720: return (usb: 10_000_000, wifi: 8_000_000)' "$source"
grep -q 'case .p1080: return (usb: 20_000_000, wifi: 15_000_000)' "$source"
grep -q 'var frameRate: Int { 60 }' "$source"
# T5.4: switching presets keeps the PC connection: setPreset never rebinds
# the listener and always asks for a new join point.
set_preset_body=$(tr -d '\r' < "$source" | awk '
  /func setPreset\(/ { in_f = 1 }
  in_f { print }
  in_f && /^    }$/ { exit }
')
printf '%s\n' "$set_preset_body" | grep -q 'applyFormat(preset, to: device)'
printf '%s\n' "$set_preset_body" | grep -q 'resetForDiscontinuity'
if printf '%s\n' "$set_preset_body" | grep -q 'restartListening'; then
  echo "setPreset must not restart the listener" >&2
  exit 1
fi
# T5.4: the bit rate follows the transport the PC connected over.
grep -q 'sender.onClientTransport' "$source"
grep -q 'DataRateLimits, value: rateLimit' "$source"
grep -q 'MaxKeyFrameInterval, value: NSNumber(value: 120)' "$source"
grep -q 'setIdleTimerDisabled(true)' "$source"
grep -q 'setIdleTimerDisabled(false)' "$source"
grep -q 'isIdleTimerDisabled' "$source"
grep -q 'thermalStateDidChangeNotification' "$source"
grep -q 'systemPressureState' "$source"
grep -q 'thermalTelemetry' "$source"
grep -q 'pressureTelemetry' "$source"

# T2.2: phone latency telemetry (encode and queue latency).
grep -q 'LATENCY encode' "$source"
grep -q 'synchronizationClock' "$source"
grep -q 'CMClockGetHostTimeClock' "$source"
grep -q 'onQueueLatency' "$source"
