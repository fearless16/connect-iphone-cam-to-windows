#!/usr/bin/env sh
# Architecture boundary contract. Every check names the rule it enforces in
# docs/ENGINEERING_RULES.md, so a failure says which boundary was crossed.
# Usage: sh tests/architecture_boundary_contract.sh [repo-root]
set -eu

cd "${1:-.}"

fail() {
  echo "BOUNDARY VIOLATION [$1]: $2" >&2
  exit 1
}

# Windows checkouts use CRLF; strip CR before parsing.
includes() {
  tr -d '\r' < "$1" | sed -n 's/^[[:space:]]*#[[:space:]]*include[[:space:]]*\([<"][^>"]*[>"]\).*/\1/p'
}
imports() {
  tr -d '\r' < "$1" | sed -n 's/^[[:space:]]*import[[:space:]][[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\).*/\1/p'
}

# only_imports RULE FILE ALLOWED_MODULE...
only_imports() {
  rule="$1"; file="$2"; shift 2
  for module in $(imports "$file"); do
    allowed=false
    for ok in "$@"; do
      if [ "$module" = "$ok" ]; then allowed=true; fi
    done
    $allowed || fail "$rule" "$file imports $module; allowed: $*"
  done
}

# R-ARCH-1: the wire protocol header is dependency-free C shared by every side.
for inc in $(includes protocol/stream_protocol.h); do
  [ "$inc" = "<stdint.h>" ] ||
    fail R-ARCH-1 "protocol/stream_protocol.h includes $inc; it may include only <stdint.h>"
done
grep -q 'extern "C"' protocol/stream_protocol.h ||
  fail R-ARCH-1 "protocol/stream_protocol.h must stay C-compatible (extern \"C\")"

# R-ARCH-2: the Swift protocol mirror stays Foundation-only.
only_imports R-ARCH-2 shared/StreamHeader.swift Foundation

# R-ARCH-3: iOS layering. UI never reaches the transport; only StreamSender
# frames wire packets; the transport has no UI or capture dependencies.
only_imports R-ARCH-3 ios/StreamSender.swift Foundation Network
for ui in ios/AppDelegate.swift ios/SceneDelegate.swift ios/CameraViewController.swift ios/CapabilityReport.swift; do
  if tr -d '\r' < "$ui" | grep -Eq 'StreamSender|NWConnection|NWListener|StreamHeader'; then
    fail R-ARCH-3 "$ui references the transport layer; route through CameraStreamer"
  fi
done
for swift in ios/*.swift; do
  [ "$swift" = ios/StreamSender.swift ] && continue
  if grep -q 'StreamHeader(' "$swift"; then
    fail R-ARCH-3 "$swift constructs StreamHeader; only ios/StreamSender.swift frames packets"
  fi
done

# R-ARCH-4: pure logic units compile standalone in tests.
only_imports R-ARCH-4 ios/LengthPrefixedHEVC.swift Foundation CoreMedia
only_imports R-ARCH-4 ios/QualityAdvisor.swift Foundation
for header in windows/relay_timestamp.h windows/relay_recovery.h windows/hevc_access_unit.h windows/hevc_sps.h windows/stream_timing.h windows/wifi_discovery.h; do
  for inc in $(includes "$header"); do
    case "$inc" in
      \<*.h\>|\"*) fail R-ARCH-4 "$header includes $inc; portable relay logic may include only C++ standard headers" ;;
      \<*\>) ;;
      *) fail R-ARCH-4 "$header has an unrecognized include $inc" ;;
    esac
  done
done

# R-ARCH-5: the supported receiver does not depend on archived prototypes.
# gpu_frame_transport.h is the single, documented exception (technical debt).
for source in windows/receiver.cpp windows/gpu_frame_publisher.cpp windows/gpu_frame_publisher.h; do
  for inc in $(includes "$source"); do
    case "$inc" in
      *directshow_compat*|*frame_store.h*|*streams.h*|*camera_contract.h*|*gpu_frame_consumer.h*)
        fail R-ARCH-5 "$source includes archived prototype header $inc" ;;
      \"mf_virtual_camera/gpu_frame_transport.h\") ;;
      *mf_virtual_camera/*)
        fail R-ARCH-5 "$source includes $inc; only mf_virtual_camera/gpu_frame_transport.h is allowed" ;;
    esac
  done
done

# R-ARCH-6: archived prototypes are not built by default or in CI.
tr -d '\r' < windows/CMakeLists.txt | grep -q 'option(BUILD_DIRECTSHOW_PROTOTYPE .* OFF)' ||
  fail R-ARCH-6 "windows/CMakeLists.txt must keep BUILD_DIRECTSHOW_PROTOTYPE defaulted OFF"
for legacy in windows/virtual_camera.cpp windows/mf_virtual_camera/controller.cpp \
              windows/mf_virtual_camera/gpu_frame_consumer.cpp; do
  if grep -q "$legacy" .github/workflows/build.yml; then
    fail R-ARCH-6 "CI builds archived prototype source $legacy"
  fi
done

# R-ARCH-7: third_party/ is vendored reference material, never part of a build.
referrers=$(grep -rIl 'third_party' ios windows protocol shared scripts tests .github 2>/dev/null |
  grep -v 'tests/architecture_boundary_contract.sh' || true)
[ -z "$referrers" ] ||
  fail R-ARCH-7 "third_party/ is referenced by: $referrers"

# Product code never includes test code.
if grep -rIlq '#include ".*tests/' windows protocol 2>/dev/null; then
  fail R-ARCH-1 "product code under windows/ or protocol/ includes a file from tests/"
fi

echo "architecture boundaries: OK"
