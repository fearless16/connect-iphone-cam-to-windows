#!/usr/bin/env sh
set -eu

source="$1"

grep -q 'CVPixelBufferGetWidth' "$source"
grep -q 'VTCompressionSessionPrepareToEncodeFrames' "$source"
grep -q 'kVTInvalidSessionErr' "$source"
grep -q 'resumeAfterForeground' "$source"
grep -q 'AVCaptureSessionRuntimeError' "$source"
grep -q 'mediaServicesWereReset' "$source"
grep -q 'Camera %.1f fps' "$source"
grep -q 'USB %.1f fps' "$source"
grep -q 'kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange' "$source"
