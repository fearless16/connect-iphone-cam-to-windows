#!/bin/sh
# Build receiver.exe and run the portable C++ tests exactly like CI
# (.github/workflows/build.yml). Run from the MSYS2 UCRT64 shell (as CI does)
# or the MINGW64 shell; both ship the FFmpeg and libusbmuxd packages.
# Keep the g++ lines identical to build.yml; only output paths differ.
set -eu

case "${MSYSTEM:-}" in
    UCRT64|MINGW64) ;;
    *)
        echo "Run this from the MSYS2 UCRT64 or MINGW64 shell (MSYSTEM=${MSYSTEM:-unset})." >&2
        exit 1
        ;;
esac

cd "$(dirname "$0")/.."
root=$(pwd)
mkdir -p build/windows-binaries

g++ -std=c++20 -O2 \
  -I"$root/protocol" \
  "$root/tests/protocol_selftest.cpp" \
  -o build/protocol_selftest.exe
./build/protocol_selftest.exe
g++ -std=c++20 -O2 \
  -I"$root/windows" \
  "$root/tests/relay_timestamp_clock_test.cpp" \
  -o build/relay_timestamp_clock_test.exe
./build/relay_timestamp_clock_test.exe
g++ -std=c++20 -O2 \
  -I"$root/windows" \
  "$root/tests/relay_recovery_gate_test.cpp" \
  -o build/relay_recovery_gate_test.exe
./build/relay_recovery_gate_test.exe
g++ -std=c++20 -O2 \
  -I"$root/windows" \
  "$root/tests/hevc_access_unit_test.cpp" \
  -o build/hevc_access_unit_test.exe
./build/hevc_access_unit_test.exe
g++ -std=c++20 -O2 \
  -I"$root/windows" \
  "$root/tests/hevc_sps_test.cpp" \
  -o build/hevc_sps_test.exe
./build/hevc_sps_test.exe
g++ -std=c++20 -O2 \
  -I"$root/windows" \
  "$root/tests/stream_timing_test.cpp" \
  -o build/stream_timing_test.exe
./build/stream_timing_test.exe
g++ -std=c++20 -O2 \
  -I"$root/windows" \
  "$root/tests/wifi_discovery_test.cpp" \
  -o build/wifi_discovery_test.exe
./build/wifi_discovery_test.exe
g++ -std=c++20 -O2 \
  -I"$root/windows" \
  "$root/tests/crash_report_test.cpp" \
  -o build/crash_report_test.exe
./build/crash_report_test.exe
g++ -std=c++20 -O2   -I"$root/windows"   "$root/tests/obs_tcp_flow_test.cpp"   -o build/obs_tcp_flow_test.exe
./build/obs_tcp_flow_test.exe
g++ -std=c++20 -O2 \
  -I"$root/protocol" \
  "$root/windows/receiver.cpp" \
  "$root/windows/gpu_frame_publisher.cpp" \
  -o build/windows-binaries/receiver.exe \
  $(pkg-config --libs libavcodec libavformat libavutil) \
  $(pkg-config --libs libusbmuxd-2.0) -liphlpapi -lws2_32 -ldnsapi -ld3d11 -ldxgi -lmfplat -ladvapi32
ls -lh build/windows-binaries/receiver.exe
# Copy every DLL that comes from this MSYS2 environment (/ucrt64/bin in CI),
# so receiver.exe also starts outside the MSYS2 shell.
dll_prefix="${MSYSTEM_PREFIX:-/ucrt64}/bin/"
ldd build/windows-binaries/receiver.exe | awk -v prefix="$dll_prefix" 'index($3, prefix) == 1 { print $3 }' | sort -u | xargs -r -I{} cp "{}" build/windows-binaries/
dll_count=$(ls build/windows-binaries/*.dll 2>/dev/null | wc -l)
[ "$dll_count" -gt 0 ] || { echo "no runtime DLLs were copied next to receiver.exe" >&2; exit 1; }
echo "copied $dll_count runtime DLLs"
