# iPhone Camera Stream → Windows OBS relay

Stream the iPhone rear camera at **4K60** over USB to `receiver.exe`, which relays
the HEVC bitstream to OBS over local UDP. In OBS, use a Media Source at
`udp://127.0.0.1:12346` with input format `mpegts`.

## Build order (do NOT skip ahead)
1. iOS: 4K60 capture + VideoToolbox HEVC encode → file  ✅ steps 1-4
2. iOS: TCP send over usbmuxd                         ✅ step 5
3. Windows: USB-network receive + UDP/MPEG-TS relay   ✅
4. OBS: Media Source with hardware HEVC decode         ✅
5. Stability test: 30+ min continuous stream
6. Vision person segmentation (future)
7. Metal background blur / replace (future)

Background blur is intentionally **deferred** until the transport is stable.

## Current 4K60 status

The iOS sender is configured for native 8-bit 420v capture when available and
hardware HEVC at 3840x2160/60. The receiver rejects corrupt or oversized
packets and emits MPEG-TS over loopback UDP. End-to-end 4K60 still requires a
30-minute phone/OBS soak test before it can be called reliable.

**Receiver CLI:** `receiver.exe [--obs-udp|--gpu-ring] [--host <iPhone address>] [iPhone USB host]`. `--host` connects straight to `<address>:12345` and skips usbmux and the Apple-adapter bind.

## Legacy virtual camera

The old virtual-camera and DirectShow sources remain in the repository only as
disabled research code. They are not built, registered, or supported. Do not
use them for this single-user setup.

## Protocol (see protocol/stream_protocol.h)
21-byte little-endian header, then one Annex-B encoded frame:

| field         | type     | size |
|---------------|----------|------|
| magic "IPCM"  | uint32   | 4    |
| frame_number  | uint32   | 4    |
| timestamp_us  | uint64   | 8    |
| codec         | uint8    | 1    |
| frame_size    | uint32   | 4    |

No JSON, no protobuf.

## Requirements
- iOS 17+, Developer Mode on, physical device (no simulator camera).
- Windows: Apple Devices, FFmpeg dev libs, libusbmuxd, and OBS.
