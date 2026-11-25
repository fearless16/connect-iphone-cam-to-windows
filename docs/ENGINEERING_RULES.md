# Engineering Rules

Single source of truth for repository rules. `CLAUDE.md` is the map, the
`.claude/skills/` files are workflows, and this file holds the rules. Cite rules
by ID (`R-ARCH-3`) instead of restating them.

Rules marked **(observed)** codify what the code already does. Rules marked
**(proposed)** are new standards introduced with the AI-native tooling. Follow
both kinds.

## Enforcement categories

| Category | Mechanism | Covers |
|---|---|---|
| Automatic | `sh scripts/check.sh` locally; `.github/workflows/build.yml` in CI | Boundaries R-ARCH-1..7, protocol parity, test registry, source contracts, unit tests, receiver link, iOS build |
| Architecture review | `architecture-alignment` skill, before and after the change | Module ownership, dependency direction, contracts, coupling, recovery semantics |
| Human judgment | Stop and ask the user (see the list at the end) | Product trade-offs, wire-format changes, new dependencies, network exposure |

A check that could not run, such as a missing compiler, is **unverified**, not
passed. Report it.

## Architecture rules (R-ARCH)

| ID | Rule | Enforced by |
|---|---|---|
| R-ARCH-1 | `protocol/stream_protocol.h` owns the wire format. It stays dependency-free C (`<stdint.h>` only, `extern "C"`). Product code never includes `tests/`. **(observed)** | `architecture_boundary_contract.sh`, `protocol_selftest.cpp` |
| R-ARCH-2 | `shared/StreamHeader.swift` is the only Swift mirror of the protocol. It is Foundation-only and must match the C header in magic, size, codec IDs, and byte layout. The TCP port (12345) must match between `StreamSender.port` and `DEVICE_PORT`. **(observed; enforcement proposed)** | `protocol_parity_contract.sh`, golden vector in `protocol_selftest.cpp` + `stream_header_test.swift` |
| R-ARCH-3 | iOS layering: `AppDelegate` → `CameraViewController` → `CameraStreamer` → `StreamSender` → `StreamHeader`. The UI never references the transport. Only `StreamSender` frames packets. `StreamSender` imports only Foundation and Network. **(observed)** | `architecture_boundary_contract.sh` |
| R-ARCH-4 | Pure logic lives in standalone units that compile without the app or SDKs: `ios/LengthPrefixedHEVC.swift` (Foundation/CoreMedia), and `windows/relay_timestamp.h`, `relay_recovery.h`, `hevc_access_unit.h`, `hevc_sps.h`, `stream_timing.h` (C++ standard headers only). New pure logic goes into a unit like these, with a runtime test. **(observed)** | `architecture_boundary_contract.sh`, runtime tests |
| R-ARCH-5 | The supported Windows product is `receiver.exe` (`receiver.cpp` + `gpu_frame_publisher.*`). It must not depend on archived prototype code. The sole exception is `mf_virtual_camera/gpu_frame_transport.h` (debt D1). **(observed)** | `architecture_boundary_contract.sh` |
| R-ARCH-6 | Archived prototypes are not built by default, not run in CI, and not extended: `windows/virtual_camera.cpp`, `directshow_compat*.h`, `frame_store.h`, `iphonecamera.def`, `windows/mf_virtual_camera/`. **(observed)** | `architecture_boundary_contract.sh`, `windows_ci_contract.sh` |
| R-ARCH-7 | `third_party/VCamSample/` is vendored reference material. Never edit it, and never reference it from a build. **(observed)** | `architecture_boundary_contract.sh` (references only; edits need review) |

## Engineering rules (R-ENG)

**R-ENG-ERR: Error handling** (observed)
- C++: no exceptions. Return `bool`, `SOCKET`, or an FFmpeg status. Log with the prefixes
  `ERROR:`, `WARN:`, `INFO:`, `STAT:` via `printf`/`fprintf(stderr, …)`.
- A broken session ends `receive_session`, and `run_receiver` reconnects. The receiver
  never exits on a phone, USB, or OBS failure.
- Recoverable relay failures are counted (`relayWriteFailures` → `relayDrop`), not fatal.
- Swift: report through `report(_:)`, which logs and hops to the main queue for `onStatus`. Failures
  schedule recovery (`scheduleRecovery`, `scheduleRestart`) with backoff. They never crash.

**R-ENG-CONC: Concurrency, iOS** (observed)
- Each piece of mutable state is confined to one `DispatchQueue` (assert with
  `dispatchPrecondition`) or guarded by a dedicated `NSLock`.
- Async callbacks capture `[weak self]`. Stale completions are discarded with generation
  counters (`sendGeneration`, `encoderGeneration`, `healthRevision`).
- UI updates happen on the main queue only.

**R-ENG-RECOVER: Discontinuity handling** (observed)
After any discontinuity (connect, reconnect, transport wait, send-queue overflow, encoder rebuild, relay reopen),
delta frames are dropped until a decoder join point arrives: an HEVC AU containing VPS+SPS+PPS+IDR.
- Sender: `waitingForKeyFrame`; `resetForDiscontinuity` for media-only discontinuities. Encoder: forced keyframe on `onClientConnected`.
- Receiver: `waitingForRandomAccess`. Relay: `RelayRecoveryGate`.

Never weaken one side without the other.

**R-ENG-INPUT: Untrusted input** (observed)
Treat every byte from the network as untrusted.
- Decode headers with `stream_header_read` and check `stream_header_is_valid` before any allocation.
- Never cast network buffers to the packed struct.
- `STREAM_MAX_FRAME_SIZE` (16 MiB) bounds allocation.
- Use `av_new_packet` (padding) for FFmpeg input.

**R-ENG-TIME: Timestamps** (observed)
Never subtract unsigned source timestamps directly. The relay timeline goes through
`RelayTimestampClock`, and mux PTS stays strictly increasing.

**R-ENG-PERF: 4K60 hot path** (observed)
Applies to per-frame paths:
- No disk writes (the receiver has none; `saveEncodedStream` stays `false`).
- No per-frame logging: statistics are rate-limited (`frames % 120`).
- No unbounded queues: the sender is capped at `maxQueuedPackets = 8` and drops when full.
- No CPU pixel copies on the GPU path.

**R-ENG-STYLE: Conventions** (observed; no formatter is configured)
- C++20 with 4-space indent.
- Free functions are `static snake_case` in `receiver.cpp`. Classes are `final PascalCase` with `PascalCase()` methods.
- Members take a trailing underscore (`last_mux_pts_`), constants `kName`, and protocol macros `STREAM_*`.
- Swift 5 with 4-space indent. Use `final class`, `private` by default, and Swift API naming.
- Match the surrounding code. Don't reformat untouched lines.

**R-ENG-TEST: Tests** (observed pattern; registry proposed)
- A behavior change in a pure unit (R-ARCH-4) needs a runtime test in `tests/*_test.{cpp,swift}`.
- A behavior change in platform-bound code needs an assertion in a source contract,
  `tests/*_contract.sh`. This covers AVFoundation, VideoToolbox, Network.framework, FFmpeg I/O, and Winsock.
- Source contracts pin identifiers. If a change renames a pinned identifier, update the
  contract in the same change and say why.
- Delete an assertion only when the behavior it guards is intentionally removed.
- Every test file must run in CI **and** in `scripts/check.sh`, unless it is nested or archived (`test_registry_contract.sh`).
- Shell tests start with `#!/usr/bin/env sh` and `set -eu`, take file paths as arguments with
  defaults, and strip `\r` before parsing, because Windows checkouts are CRLF.
- Never compile tests with `NDEBUG`.

**R-ENG-DOCS: User-facing docs** (observed)
Update the user-facing docs in the same change when you change any of these:
- CLI flags, ports, or OBS settings
- setup steps
- the supported/archived status of a component

The user-facing docs are `README.md`, `docs/QUICKSTART.md`, `OBS-SETUP.md`, `docs/BACKDOOR.md`, and `docs/architecture.md`.

**R-ENG-DEPS: Dependencies** (observed)
Runtime dependencies are system frameworks, FFmpeg, and libusbmuxd only. Adding any other
dependency is a human-judgment decision.

**R-ENG-SEC: Network exposure** (proposed)
Do not widen network exposure:
- The receiver binds to the iPhone USB interface (`bind_iphone_usb_interface`).
- The OBS relay targets `127.0.0.1` only.

New listeners or non-loopback outputs need human approval. Debt D4 is the existing exception.

## Human-judgment decisions (stop and ask)

- Any wire-format change: header fields, magic, size, codecs, or port. Old app builds break silently (D3).
- Reviving, building, or extending an archived prototype (R-ARCH-6), or editing `third_party/`.
- New dependencies, toolchains, CI platforms, or formatters/linters that reformat existing code.
- Changing the 4K60/HEVC target, bitrate, or default receiver mode, or starting roadmap items 6–7
  (segmentation/blur). These are gated on the 30-minute soak test in `README.md`.
- Anything that changes network exposure (R-ENG-SEC) or fixes D4.

## Known technical debt

Do not copy these patterns. Fix them only when that is the task.

| ID | Debt | Smallest correction |
|---|---|---|
| D1 | `windows/gpu_frame_publisher.h` includes `mf_virtual_camera/gpu_frame_transport.h`, so the supported code depends on the archived directory | Move the header to `windows/` and repoint both users (needs approval: it touches archived code) |
| D2 | `ios/CameraStreamer.swift` (~1,250 lines) owns capture, encode, recovery, telemetry, health, and the watchdog | Add no new responsibilities. Extract pure logic into R-ARCH-4 units when touched |
| D3 | The wire header has no version field | Human decision. A version needs a coordinated app + receiver release |
| D4 | iOS `NWListener` accepts on every interface, unauthenticated, and the newest connection replaces the current one | Human decision. For example, require the wired interface |
| D5 | ~~The sender accepted frames up to `UInt32.max`, but the receiver rejects anything over 16 MiB~~ | Fixed by T1.7: `StreamSender.send` guards `StreamHeader.maxFrameSize` and requests a keyframe |
| D6 | Source contracts are grep-based: they pin names and strings, not behavior | Prefer runtime tests for logic you can extract |
| D7 | `scripts/build_*.sh` contain placeholder paths and are not used by CI | Use `scripts/build_receiver_msys2.sh` (mirrors CI) |
| D8 | `receiver.cpp` mixes discovery, transport, relay, and decode | Extract `ObsUdpRelay` only when changing it |
| D9 | No clang-format, SwiftLint, or `-Wall` in CI. Style is review-enforced | Human decision (reformat churn) |
| D10 | `gpu_frame_transport_contract_test.cpp` is archived, but `--gpu-ring` writes that layout | Wire it into CI if `--gpu-ring` gains support |
