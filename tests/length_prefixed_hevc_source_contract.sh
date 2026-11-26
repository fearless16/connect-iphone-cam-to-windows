#!/usr/bin/env sh
set -eu
# A bare "! grep" never fails under set -e (POSIX); forbid() does.
forbid() { if grep "$@"; then echo "forbidden pattern present: $*" >&2; exit 1; fi; }

converter="${1:-ios/LengthPrefixedHEVC.swift}"
camera="${2:-ios/CameraStreamer.swift}"
project="${3:-ios/iPhoneCameraStream.xcodeproj/project.pbxproj}"
workflow="${4:-.github/workflows/build.yml}"

test -f "$converter"
grep -q 'enum LengthPrefixedHEVCConversionError' "$converter"
grep -q 'case nalTooShort' "$converter"
grep -q 'static func convert' "$converter"
grep -q 'static func containsIDR' "$converter"
grep -q 'guard nalLength >= 2' "$converter"
grep -q 'LengthPrefixedHEVC.convert' "$camera"
grep -q 'let metadataMarksKeyframe' "$camera"
grep -q 'if let metadataMarksKeyframe,' "$camera"
forbid -q 'as? Bool ?? false' "$camera"
grep -q 'LengthPrefixedHEVC.containsIDR(encodedAccessUnit)' "$camera"
grep -q 'HEVC IDR marked NotSync' "$camera"
grep -q 'Metadata keyframe lacks HEVC IDR' "$camera"
grep -q 'isKeyframe: containsRandomAccessPicture' "$camera"
forbid -q 'isKeyframe: metadataMarksKeyframe' "$camera"
grep -q 'recordMalformedAccessUnitDrop' "$camera"
forbid -q 'guard nalLen > 0.*else { break }' "$camera"
awk '
  /func writeAnnexB\(sampleBuffer:/ { in_writer = 1 }
  in_writer && /LengthPrefixedHEVC\.convert/ { convert_line = NR }
  in_writer && /catch let error as LengthPrefixedHEVCConversionError/ { catch_line = NR }
  catch_line && /recordMalformedAccessUnitDrop/ && !drop_line { drop_line = NR }
  drop_line && /return/ && !return_line { return_line = NR }
  in_writer && /sender\.send/ { send_line = NR; exit }
  END {
    exit !(convert_line && catch_line && drop_line && return_line && send_line &&
           convert_line < catch_line && catch_line < drop_line &&
           drop_line < return_line && return_line < send_line)
  }
' "$camera"
awk '
  /func writeAnnexB\(sampleBuffer:/ { in_writer = 1 }
  in_writer && /LengthPrefixedHEVC\.convert/ { convert_line = NR }
  in_writer && /LengthPrefixedHEVC\.containsIDR\(encodedAccessUnit\)/ { idr_line = NR }
  in_writer && /if containsRandomAccessPicture \{/ { parameter_guard_line = NR }
  parameter_guard_line && /for index in 0\.\.<parameterSetCount/ { parameter_line = NR }
  in_writer && /isKeyframe: containsRandomAccessPicture/ { admission_line = NR; exit }
  END {
    exit !(convert_line && idr_line && parameter_guard_line && parameter_line && admission_line &&
           convert_line < idr_line && idr_line < parameter_guard_line &&
           parameter_guard_line < parameter_line && parameter_line < admission_line)
  }
' "$camera"
awk '
  /^[[:space:]]*let metadataMarksKeyframe/ { declaration_line = NR }
  /if let metadataMarksKeyframe,/ { optional_line = NR }
  optional_line && /metadataMarksKeyframe != containsRandomAccessPicture/ { compare_line = NR }
  compare_line && /report\(containsRandomAccessPicture/ { report_line = NR; exit }
  END {
    exit !(declaration_line && optional_line && compare_line && report_line &&
           declaration_line < optional_line && optional_line <= compare_line &&
           compare_line < report_line)
  }
' "$camera"
grep -q 'LengthPrefixedHEVC.swift in Sources' "$project"
grep -q 'length_prefixed_hevc_test.swift' "$workflow"

echo "length_prefixed_hevc_source_contract: PASS"
