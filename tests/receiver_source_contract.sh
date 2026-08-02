#!/usr/bin/env sh
set -eu

receiver="$1"

# The receiver must be a durable USB-network bridge, not a console program
# that exits before the user opens the iPhone app.
grep -q 'WSAStartup' "$receiver"
grep -q 'discover_iphone_usb_host' "$receiver"
grep -q 'IPHONE_CAMERA_HOST' "$receiver"
grep -q 'connect_tcp' "$receiver"
grep -q 'USB network' "$receiver"
grep -q 'select_d3d11_format' "$receiver"
grep -q 'AV_PIX_FMT_D3D11' "$receiver"
grep -q 'verified GPU decode' "$receiver"
grep -q 'WSAEWOULDBLOCK' "$receiver"
grep -q 'select(0' "$receiver"
grep -q 'waiting for first HEVC frame' "$receiver"
grep -q 'first HEVC packet' "$receiver"
grep -q 'sourcePTS' "$receiver"
grep -q 'sourceGapFrames' "$receiver"
grep -q 'av_new_packet' "$receiver"
grep -q 'AV_INPUT_BUFFER_PADDING_SIZE' "$receiver"
grep -q 'drain_decoder' "$receiver"
grep -q 'for (;;)' "$receiver"
grep -q 'static SOCKET connect_tcp' "$receiver"
grep -q 'static SOCKET connect_to_device' "$receiver"
grep -q 'static bool read_exact(SOCKET fd' "$receiver"
grep -q 'const SOCKET fd = connect_to_device' "$receiver"
grep -q -- '--obs-udp' "$receiver"
grep -q -- '--gpu-ring' "$receiver"
grep -q 'bool obsUdpRelay = true' "$receiver"
grep -q 'avformat_alloc_output_context2' "$receiver"
grep -q 'av_interleaved_write_frame' "$receiver"
