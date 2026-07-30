#!/usr/bin/env sh
set -eu

source="$1"

grep -q 'CVPixelBufferGetWidth' "$source"
grep -q 'VTCompressionSessionPrepareToEncodeFrames' "$source"
grep -q 'kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange' "$source"
