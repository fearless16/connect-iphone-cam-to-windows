#!/usr/bin/env bash
# Build the Windows receiver + the self-contained virtual camera DLL.
# Set these to your library locations before running.
set -euo pipefail

FFMPEG_INC="C:/libs/ffmpeg/include"
FFMPEG_LIB="C:/libs/ffmpeg/lib"
USBMUXD_INC="C:/libs/libusbmuxd/include"
USBMUXD_LIB="C:/libs/libusbmuxd/lib"
DSHOW_INC="C:/libs/BaseClasses"   # DirectShow BaseClasses
PROTO_INC="../protocol"

echo "==> receiver.exe"
cl /std:c++20 /EHsc \
  /I"$FFMPEG_INC" /I"$USBMUXD_INC" /I"$PROTO_INC" \
  ../windows/receiver.cpp \
  /link "$FFMPEG_LIB/avcodec.lib" "$FFMPEG_LIB/avutil.lib" \
        "$USBMUXD_LIB/usbmuxd.lib" ws2_32.lib \
  /OUT:receiver.exe

echo "==> iphonecamera.ax (DirectShow filter DLL)"
cl /std:c++20 /EHsc /LD \
  /I"$FFMPEG_INC" /I"$USBMUXD_INC" /I"$DSHOW_INC" /I"$PROTO_INC" \
  ../windows/virtual_camera.cpp \
  /link "$FFMPEG_LIB/avcodec.lib" "$FFMPEG_LIB/avutil.lib" "$FFMPEG_LIB/swscale.lib" \
        "$USBMUXD_LIB/usbmuxd.lib" ws2_32.lib d3d11.lib strmiids.lib strmbase.lib \
  /OUT:iphonecamera.ax

echo "Built receiver.exe and iphonecamera.ax"
echo "Register: regsvr32 iphonecamera.ax  (run OBS as admin)"
