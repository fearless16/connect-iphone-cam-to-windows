# iPhone Camera Stream → Windows OBS

This project is developing an iPhone rear-camera **4K60-over-USB** transport for
Windows. The iOS encoder and `receiver.exe` transport path are the current
validation target. `iphonecamera.ax` / OBS DirectShow support is experimental;
it is **not** a verified end-to-end 4K60 camera path yet.

## Repo layout
```
ios/        Swift app (Xcode project included) — capture + HEVC encode + USB send
windows/    C++ receiver + self-contained DirectShow virtual camera (CMake)
shared/     StreamHeader.swift (mirrors the C protocol)
protocol/   stream_protocol.h (single source of truth for the wire format)
docs/       architecture.md, QUICKSTART.md
scripts/    build helpers
```

## How to build (full beginner steps)
Read **`docs/QUICKSTART.md`** — it lists every click and command for both Mac and Windows.

## Order of work (transport first, blur last)
1. ✅ 4K60 capture + HEVC encode (iOS)
2. ✅ USB send over usbmuxd (iOS)
3. ✅ Receive + decode (Windows)
4. ⚠️ Experimental DirectShow virtual camera (not validated for 4K60)
5. ⏳ Stability test: 30+ min continuous stream
6. ⏳ Vision person segmentation
7. ⏳ Metal background blur / replace

Background blur is intentionally deferred until the transport is stable.
