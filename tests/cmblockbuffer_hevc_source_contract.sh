#!/usr/bin/env sh
set -eu
# A bare "! grep" never fails under set -e (POSIX); forbid() does.
forbid() { if grep "$@"; then echo "forbidden pattern present: $*" >&2; exit 1; fi; }

converter="${1:-ios/LengthPrefixedHEVC.swift}"
camera="${2:-ios/CameraStreamer.swift}"
behavior_test="${3:-tests/cmblockbuffer_hevc_test.swift}"
workflow="${4:-.github/workflows/build.yml}"

test -f "$converter"
test -f "$camera"
test -f "$behavior_test"
test -f "$workflow"

# Never hand the converter a total-length view over only the first contiguous
# CMBlockBuffer segment. Fragmented buffers must be copied into owned storage.
grep -q '#if canImport(CoreMedia)' "$converter"
grep -q 'case blockBufferCopyFailed(OSStatus)' "$converter"
grep -q 'static func convert(_ blockBuffer: CMBlockBuffer' "$converter"
grep -q 'lengthAtOffset == totalLength' "$converter"
grep -q 'reportedTotalLength == totalLength' "$converter"
grep -q 'Data(count: totalLength)' "$converter"
grep -q 'CMBlockBufferCopyDataBytes' "$converter"
grep -q 'LengthPrefixedHEVC.convert(' "$camera"
grep -q 'encoded sample has no data buffer' "$camera"
grep -q 'recordMalformedAccessUnitDrop' "$camera"
forbid -q 'CMBlockBufferGetDataPointer' "$camera"
grep -q 'CMBlockBufferAppendBufferReference' "$behavior_test"
grep -q 'test fixture unexpectedly became contiguous' "$behavior_test"
grep -q 'fragmented truncated sample must be rejected' "$behavior_test"
grep -q 'tests/cmblockbuffer_hevc_test.swift' "$workflow"
grep -q '/tmp/cmblockbuffer_hevc_test' "$workflow"

awk '
  /static func convert\(_ blockBuffer: CMBlockBuffer/ { in_converter = 1 }
  in_converter && /CMBlockBufferGetDataPointer/ { pointer_line = NR }
  in_converter && /lengthAtOffset == totalLength/ { contiguous_line = NR }
  in_converter && /CMBlockBufferCopyDataBytes/ { copy_line = NR }
  in_converter && /return try convert\(copiedSample/ { convert_line = NR; exit }
  END {
    exit !(pointer_line && contiguous_line && copy_line && convert_line &&
           pointer_line < contiguous_line && contiguous_line < copy_line &&
           copy_line < convert_line)
  }
' "$converter"

awk '
  /func writeAnnexB\(sampleBuffer:/ { in_writer = 1 }
  in_writer && /guard let dataBuffer/ { buffer_line = NR }
  buffer_line && !nil_drop_line && /recordMalformedAccessUnitDrop/ { nil_drop_line = NR }
  in_writer && /LengthPrefixedHEVC\.convert/ { convert_line = NR }
  in_writer && /sender\.send/ { send_line = NR; exit }
  END {
    exit !(buffer_line && nil_drop_line && convert_line && send_line &&
           buffer_line < nil_drop_line && nil_drop_line < convert_line &&
           convert_line < send_line)
  }
' "$camera"

echo "cmblockbuffer_hevc_source_contract: PASS"
