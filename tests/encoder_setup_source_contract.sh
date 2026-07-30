#!/usr/bin/env sh
set -eu

source="$1"

grep -q 'CVPixelBufferGetWidth' "$source"
grep -q 'VTCompressionSessionPrepareToEncodeFrames' "$source"
grep -q 'kVTInvalidSessionErr' "$source"
grep -q 'resumeAfterForeground' "$source"
grep -q 'AVCaptureSessionRuntimeError' "$source"
grep -q 'mediaServicesWereReset' "$source"
grep -q 'SENSOR %.1f' "$source"
grep -q 'HEVC %.1f' "$source"
grep -q 'USB %.1f fps' "$source"
grep -q 'didDrop sampleBuffer' "$source"
grep -q 'alwaysDiscardsLateVideoFrames = true' "$source"
grep -q 'session.sessionPreset = .inputPriority' "$source"
grep -q 'refreshActiveFormatTelemetry(device)' "$source"
grep -q 'kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange' "$source"
