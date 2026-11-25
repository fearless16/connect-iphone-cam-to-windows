# iPhone Camera Stream → Windows OBS

This project streams an iPhone rear camera at **4K60 over USB** to Windows.
The supported single-user path is the iOS encoder plus `receiver.exe`, which
relays HEVC to OBS over loopback UDP. In OBS, add a Media Source with
`udp://127.0.0.1:12346` and input format `mpegts`.

The archived DirectShow and virtual-camera sources are disabled research code;
they are not built, registered, or supported.

## Repo layout
```
ios/        Swift app — capture + HEVC encode + TCP over USB network
windows/    C++ receiver + OBS UDP relay; legacy prototype is source-only
shared/     StreamHeader.swift (mirrors the C protocol)
protocol/   stream_protocol.h (single source of truth for the wire format)
docs/       architecture.md, QUICKSTART.md, ENGINEERING_RULES.md
scripts/    build helpers; check.sh runs every local quality gate
tests/      runtime tests and source contracts (all wired into CI)
```

Contributors and AI agents: start with `CLAUDE.md`, and run `sh scripts/check.sh`
before submitting a change.

## How to build (full beginner steps)
Read **`docs/QUICKSTART.md`** — it lists every click and command for both Mac and Windows.

## Order of work (transport first, blur last)
1. ✅ 4K60 capture + HEVC encode (iOS)
2. ✅ USB-network send through iPhone Personal Hotspot (iOS)
3. ✅ Receive + decode (Windows)
4. ✅ `receiver.exe` relays USB HEVC to OBS over UDP (Media Source)
5. ⏳ Stability test: 30+ min continuous stream
6. ⏳ Vision person segmentation
7. ⏳ Metal background blur / replace

Background blur is intentionally deferred until the transport is stable.
