#!/usr/bin/env sh
# Local quality gate. Mirrors .github/workflows/build.yml for everything this
# machine can run, and prints SKIP (never a silent PASS) for everything else.
#
#   sh scripts/check.sh            # from any directory
#
# Exit status is 0 only when nothing FAILed. Report every SKIP line to the
# user: a skipped check is an unverified check. tests/test_registry_contract.sh
# fails if a test in tests/ is missing from this file or from CI.
set -u

cd "$(dirname "$0")/.."
pass=0
fail=0
skip=0
tmp=$(mktemp -d 2>/dev/null || mktemp -d -t check)
trap 'rm -rf "$tmp"' EXIT

run() {
  label="$1"; shift
  if "$@" >"$tmp/out" 2>&1; then
    pass=$((pass + 1)); echo "PASS  $label"
  else
    fail=$((fail + 1)); echo "FAIL  $label"
    echo "      rerun: $*   (add 'sh -x' to see the failing assertion)"
    tail -n 20 "$tmp/out" | sed 's/^/      | /'
  fi
}
skip() { skip=$((skip + 1)); echo "SKIP  $1 -- $2"; }
have() { command -v "$1" >/dev/null 2>&1; }

echo "== Repository contracts"
run "architecture boundaries" sh tests/architecture_boundary_contract.sh
run "protocol parity" sh tests/protocol_parity_contract.sh
run "test registry" sh tests/test_registry_contract.sh
run "windows CI contract" sh tests/windows_ci_contract.sh .github/workflows/build.yml
run "iOS CI contract" sh tests/ios_ci_contract.sh .github/workflows/build.yml

echo "== iOS source contracts"
run "length-prefixed HEVC" sh tests/length_prefixed_hevc_source_contract.sh
run "CMBlockBuffer HEVC" sh tests/cmblockbuffer_hevc_source_contract.sh
run "iOS preview" sh tests/ios_preview_source_contract.sh \
  ios/AppDelegate.swift ios/CameraViewController.swift \
  ios/iPhoneCameraStream.xcodeproj/project.pbxproj
run "stream sender" sh tests/stream_sender_source_contract.sh ios/StreamSender.swift
run "crash report" sh tests/crash_report_source_contract.sh ios/CrashReportService.swift ios/CameraStreamer.swift windows/receiver.cpp
run "encoder setup" sh tests/encoder_setup_source_contract.sh ios/CameraStreamer.swift
run "HEVC join" sh tests/hevc_join_source_contract.sh ios/CameraStreamer.swift ios/StreamSender.swift
run "orientation/timestamp" sh tests/camera_orientation_timestamp_contract.sh \
  ios/CameraStreamer.swift ios/CameraViewController.swift \
  ios/Assets.xcassets/AppIcon.appiconset \
  ios/iPhoneCameraStream.xcodeproj/project.pbxproj windows/receiver.cpp
run "camera feedback" sh tests/camera_feedback_source_contract.sh \
  ios/CameraStreamer.swift ios/StreamSender.swift ios/CameraViewController.swift
if have plutil; then
  run "Info.plist local-network usage" plutil -extract NSLocalNetworkUsageDescription raw ios/Info.plist
else
  run "Info.plist local-network usage (grep fallback)" grep -q NSLocalNetworkUsageDescription ios/Info.plist
fi

echo "== Windows source contracts"
run "receiver + OBS relay" sh tests/receiver_source_contract.sh windows/receiver.cpp

echo "== App icon"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    if have pwsh; then
      run "app icon" pwsh -NoProfile -File tests/app_icon_contract.ps1 \
        -IconPath ios/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
    else
      skip "tests/app_icon_contract.ps1" "pwsh not on PATH (CI windows job runs it)"
    fi ;;
  *) skip "tests/app_icon_contract.ps1" "needs Windows System.Drawing (CI windows job runs it)" ;;
esac

echo "== C++ runtime tests"
cxx=""
for candidate in "${CXX:-}" g++ clang++; do
  if [ -n "$candidate" ] && have "$candidate"; then cxx="$candidate"; break; fi
done
cpp_test() { # SOURCE INCLUDE_DIR
  name=$(basename "$1" .cpp)
  if [ -z "$cxx" ]; then
    skip "$1" "no g++/clang++ on PATH (CI windows job runs it)"
    return
  fi
  run "$1" sh -c "\"$cxx\" -std=c++20 -O2 -I\"$2\" \"$1\" -o \"$tmp/$name\" && \"$tmp/$name\""
}
cpp_test tests/protocol_selftest.cpp protocol
cpp_test tests/relay_timestamp_clock_test.cpp windows
cpp_test tests/relay_recovery_gate_test.cpp windows
cpp_test tests/hevc_access_unit_test.cpp windows
cpp_test tests/hevc_sps_test.cpp windows
cpp_test tests/stream_timing_test.cpp windows
cpp_test tests/wifi_discovery_test.cpp windows
cpp_test tests/crash_report_test.cpp windows

echo "== Swift runtime tests"
swift_test() { # TEST_SOURCE PRODUCT_SOURCE [extra swiftc flags...]
  test_source="$1"; product="$2"; shift 2
  name=$(basename "$test_source" .swift)
  if ! have xcrun; then
    skip "$test_source" "needs macOS + Xcode (CI ios job runs it)"
    return
  fi
  # Top-level test code is only legal in a file named main.swift; @main tests are not.
  src="$test_source"
  if ! grep -q '^@main' "$test_source"; then
    mkdir -p "$tmp/$name.src"
    cp "$test_source" "$tmp/$name.src/main.swift"
    src="$tmp/$name.src/main.swift"
  fi
  run "$test_source" sh -c "xcrun swiftc -swift-version 5 \"$product\" \"$src\" $* -o \"$tmp/$name\" && \"$tmp/$name\""
}
swift_test tests/length_prefixed_hevc_test.swift ios/LengthPrefixedHEVC.swift
swift_test tests/cmblockbuffer_hevc_test.swift ios/LengthPrefixedHEVC.swift -framework CoreMedia
swift_test tests/stream_header_test.swift shared/StreamHeader.swift
swift_test tests/quality_advisor_test.swift ios/QualityAdvisor.swift
swift_test tests/crash_report_store_test.swift ios/CrashReportStore.swift
swift_test tests/stream_sender_test.swift ios/StreamSender.swift shared/StreamHeader.swift

echo "== CI-only builds"
skip "receiver.exe link" "needs MSYS2 FFmpeg + libusbmuxd (CI windows job)"
skip "xcodebuild iPhoneCameraStream" "needs Xcode; unsigned build runs in CI ios job"

echo
echo "check.sh: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
