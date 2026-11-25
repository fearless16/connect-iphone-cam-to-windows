#!/usr/bin/env sh
set -eu

workflow="$1"

for test_name in protocol_selftest relay_timestamp_clock_test relay_recovery_gate_test hevc_access_unit_test; do
  grep -q "tests/${test_name}.cpp" "$workflow"
  grep -q -- "-o ${test_name}.exe" "$workflow"
  grep -q "./${test_name}.exe" "$workflow"
done

for source_contract in \
  length_prefixed_hevc_source_contract.sh \
  cmblockbuffer_hevc_source_contract.sh \
  ios_preview_source_contract.sh \
  stream_sender_source_contract.sh \
  encoder_setup_source_contract.sh \
  hevc_join_source_contract.sh \
  camera_orientation_timestamp_contract.sh \
  camera_feedback_source_contract.sh \
  receiver_source_contract.sh; do
  grep -q "tests/${source_contract}" "$workflow"
done

for runtime_test in length_prefixed_hevc_test cmblockbuffer_hevc_test stream_sender_test; do
  grep -q "tests/${runtime_test}.swift" "$workflow"
  grep -q "/tmp/${runtime_test}" "$workflow"
done

grep -q 'tests/app_icon_contract.ps1' "$workflow"
grep -q 'name: iPhoneCameraStream-ipa' "$workflow"
grep -q 'name: windows-binaries' "$workflow"

# The only supported single-user Windows path is receiver.exe -> OBS UDP.
# Archived DirectShow and Media Foundation prototypes must not consume normal CI
# time or imply that a virtual-camera artifact is supported.
! grep -q 'tests/virtual_camera_source_contract.sh' "$workflow"
! grep -q 'tests/virtual_camera_contract_test.cpp' "$workflow"
! grep -q '^  windows-virtual-camera:' "$workflow"
! grep -q 'name: windows-virtual-camera' "$workflow"
