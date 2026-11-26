#!/usr/bin/env bash
# Build the supported Windows receiver for the OBS UDP relay.
# Set these to your library locations before running.
set -euo pipefail

FFMPEG_INC="C:/libs/ffmpeg/include"
FFMPEG_LIB="C:/libs/ffmpeg/lib"
USBMUXD_INC="C:/libs/libusbmuxd/include"
USBMUXD_LIB="C:/libs/libusbmuxd/lib"
PROTO_INC="../protocol"

echo "==> receiver.exe"
cl /std:c++20 /EHsc \
  /I"$FFMPEG_INC" /I"$USBMUXD_INC" /I"$PROTO_INC" \
  ../windows/receiver.cpp ../windows/gpu_frame_publisher.cpp \
  /link "$FFMPEG_LIB/avcodec.lib" "$FFMPEG_LIB/avformat.lib" "$FFMPEG_LIB/avutil.lib" \
        "$USBMUXD_LIB/usbmuxd.lib" ws2_32.lib iphlpapi.lib dnsapi.lib d3d11.lib dxgi.lib mfplat.lib advapi32.lib \
  /OUT:receiver.exe

echo "Built receiver.exe"
echo "In OBS, add a Media Source with udp://127.0.0.1:12346 (mpegts)."
echo "The legacy virtual-camera prototype is disabled and unsupported."
