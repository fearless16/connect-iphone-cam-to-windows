# iPhone Camera Stream → Windows OBS Virtual Camera

Stream the iPhone rear camera at **4K60** over **USB** (usbmuxd) and expose it to
OBS on Windows as a **DirectShow** device named `iPhone Camera`. No UI, no settings.

## Build order (do NOT skip ahead)
1. iOS: 4K60 capture + VideoToolbox HEVC encode → file  ✅ steps 1-4
2. iOS: TCP send over usbmuxd                         ✅ step 5
3. Windows: usbmuxd receive + FFmpeg D3D11VA decode   ✅ steps 6-7
4. Windows: DirectShow virtual camera                  ⚠️ experimental source filter
5. Stability test: 30+ min continuous stream
6. Vision person segmentation (step 9)
7. Metal background blur / replace (step 10)

Background blur is intentionally **deferred** until the transport is stable.

## Current 4K60 status

The iOS sender is configured for hardware HEVC at 3840x2160/60 and the wire
receiver rejects corrupt or oversized packets. End-to-end 4K60 is **not yet
validated**: the DirectShow prototype converts every decoded 4K frame to RGB on
the CPU. It uses an instance-owned DirectShow `CSource`/`CSourceStream`, a
latest-frame handoff, graph-lifetime receiver thread, and reconnect backoff;
these are correctness foundations, not performance validation. A GPU-backed
decode and texture path plus a 30-minute device/OBS soak test are required
before claiming reliable 4K60 output.

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
- Windows: Apple Mobile Device Support (usbmuxd), FFmpeg dev libs, DirectShow BaseClasses.
- OBS installed on Windows to consume the virtual camera.
