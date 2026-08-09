#!/usr/bin/env sh
set -eu

workflow="$1"

for test_name in relay_timestamp_clock_test relay_recovery_gate_test hevc_access_unit_test; do
  grep -q "tests/${test_name}.cpp" "$workflow"
  grep -q -- "-o ${test_name}.exe" "$workflow"
  grep -q "./${test_name}.exe" "$workflow"
done
