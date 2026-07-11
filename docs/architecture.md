# iPhone Camera Stream → Windows OBS Virtual Camera

Stream the iPhone rear camera at **4K60** over **USB** (usbmuxd) and expose it to
OBS on Windows as a **DirectShow** device named `iPhone Camera`. No UI, no settings.

## Build order (do NOT skip ahead)
1. iOS: 4K60 capture + VideoToolbox HEVC encode → file  ✅ steps 1-4
2. iOS: TCP send over usbmuxd                         ✅ step 5
3. Windows: usbmuxd receive + FFmpeg D3D11VA decode   ✅ steps 6-7
4. Windows: DirectShow virtual camera                  ✅ step 8 (skeleton)
5. Stability test: 30+ min continuous stream
6. Vision person segmentation (step 9)
7. Metal background blur / replace (step 10)

Background blur is intentionally **deferred** until the transport is stable.

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
