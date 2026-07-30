# iPhone Camera Stream → Windows OBS

This project is developing an iPhone rear-camera **4K60-over-USB** transport for
Windows. The iOS encoder and `receiver.exe` transport path are the current
validation target. The archived DirectShow BaseClasses require their documented
MSVC build pipeline, so `iphonecamera.ax` is not shipped as a working artifact.

## Repo layout
```
ios/        Swift app — capture + HEVC encode + TCP over USB network
windows/    C++ receiver; legacy DirectShow prototype is source-only
shared/     StreamHeader.swift (mirrors the C protocol)
protocol/   stream_protocol.h (single source of truth for the wire format)
docs/       architecture.md, QUICKSTART.md
scripts/    build helpers
```

## How to build (full beginner steps)
Read **`docs/QUICKSTART.md`** — it lists every click and command for both Mac and Windows.

## Order of work (transport first, blur last)
1. ✅ 4K60 capture + HEVC encode (iOS)
2. ✅ USB-network send through iPhone Personal Hotspot (iOS)
3. ✅ Receive + decode (Windows)
4. `receiver.exe` is the shipped USB/HEVC transport validator, not a virtual camera
5. ⏳ Stability test: 30+ min continuous stream
6. ⏳ Vision person segmentation
7. ⏳ Metal background blur / replace

Background blur is intentionally deferred until the transport is stable.
