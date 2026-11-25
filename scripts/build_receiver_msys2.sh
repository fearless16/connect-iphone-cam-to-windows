#!/bin/sh
# Build receiver.exe and run the portable C++ tests exactly like CI
# (.github/workflows/build.yml). Run from the MSYS2 UCRT64 shell.
# Keep the g++ lines identical to build.yml; only output paths differ.
set -eu

if [ "${MSYSTEM:-}" != "UCRT64" ]; then
    echo "Run this from the MSYS2 UCRT64 shell (MSYSTEM=${MSYSTEM:-unset})." >&2
    exit 1
fi

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
  -I"$root/protocol" \
  "$root/windows/receiver.cpp" \
  "$root/windows/gpu_frame_publisher.cpp" \
  -o build/windows-binaries/receiver.exe \
  $(pkg-config --libs libavcodec libavformat libavutil libswscale) \
  $(pkg-config --libs libusbmuxd-2.0) -liphlpapi -lws2_32 -ld3d11 -ldxgi -lmfplat -ladvapi32
ls -lh build/windows-binaries/receiver.exe
ldd build/windows-binaries/receiver.exe | awk '/\/mingw64\/bin\// { print $3 }' | sort -u | xargs -r -I{} cp "{}" build/windows-binaries/
