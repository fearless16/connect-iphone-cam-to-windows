# CLAUDE.md

Entry point for AI agents. Read this first. Load skills and rules only when the
task needs them.

## Purpose

This repo streams an iPhone's rear camera at **4K60 HEVC over USB** to Windows.
`receiver.exe` relays the stream to **OBS** over loopback UDP. The product is
one supported path. Everything else is archived research code.

```
iPhone app (ios/)                                   Windows (windows/receiver.cpp)
AVCaptureSession ─► VideoToolbox HEVC ─► StreamSender ══TCP :12345 over USB══► validate header
 CameraStreamer      Annex-B (LengthPrefixedHEVC)    (StreamHeader framing)    ─► HEVC join gate
                                                                               ─► ObsUdpRelay (MPEG-TS)
                                                                               ─► udp://127.0.0.1:12346 ─► OBS
```

Wire format is a 21-byte little-endian header plus one Annex-B access unit
(`protocol/stream_protocol.h`).

## Active work plan

Current work is planned task by task in
[`docs/plan/EXECUTION_PLAN.md`](docs/plan/EXECUTION_PLAN.md). If you were given a
task ID (for example `T1.2`), read that file's section 0 and your task section,
and check the status tracker and gates before starting. Then follow the Mandatory
workflow below.

## Module map

| Path | Owns | May depend on | Status |
|---|---|---|---|
| `protocol/stream_protocol.h` | Wire format (source of truth) | `<stdint.h>` only | Supported |
| `shared/StreamHeader.swift` | Swift mirror of the wire header | Foundation | Supported |
| `ios/AppDelegate.swift`, `CameraViewController.swift` | App lifecycle, preview, status UI, orientation control | `CameraStreamer` | Supported |
| `ios/CameraStreamer.swift` | Capture, 4K60 format, HEVC encoder, recovery, telemetry | `StreamSender`, `LengthPrefixedHEVC` | Supported (oversized, D2) |
| `ios/StreamSender.swift` | TCP listener, packet framing, bounded send queue, keyframe gating | `StreamHeader`, Network | Supported |
| `ios/LengthPrefixedHEVC.swift` | AVCC→Annex-B conversion, IDR detection (pure) | Foundation, CoreMedia | Supported |
| `windows/receiver.cpp` | USB host discovery, TCP, header validation, OBS relay, `--gpu-ring` diagnostics | protocol, `relay_*.h`, `hevc_access_unit.h`, FFmpeg, usbmuxd, Winsock | Supported |
| `windows/relay_timestamp.h`, `relay_recovery.h`, `hevc_access_unit.h`, `hevc_sps.h`, `stream_timing.h` | Pure relay logic (clock, recovery gate, join-point detection, arrival timing stats) | C++ std only | Supported |
| `windows/gpu_frame_publisher.*` | D3D11 GPU ring producer (`--gpu-ring` only) | `mf_virtual_camera/gpu_frame_transport.h` (D1) | Diagnostics |
| `windows/virtual_camera.cpp`, `directshow_compat*.h`, `frame_store.h`, `iphonecamera.def`, `windows/mf_virtual_camera/` | DirectShow / Media Foundation virtual camera | — | **Archived: do not build or extend** |
| `third_party/VCamSample/` | Vendored reference sample | — | **Never edit** |
| `tests/` | `*_test.{cpp,swift}` runtime tests; `*_contract.sh` source contracts | product sources | — |
| `.github/workflows/build.yml` | CI: unsigned IPA (macOS) + `receiver.exe` (MSYS2) | — | Authoritative build |

Dependencies point down the "May depend on" column and never back up. These
boundaries are machine-checked (`tests/architecture_boundary_contract.sh`).
Rules and IDs are in [`docs/ENGINEERING_RULES.md`](docs/ENGINEERING_RULES.md).

## Where new functionality belongs

| You are adding… | Put it in… |
|---|---|
| A wire-format field or constant | Stop. It is a human decision (R-ARCH-2, D3). If approved: C header, Swift mirror, golden vectors, parity contract, and both sides, all in one change |
| Pure, testable logic (parsing, state machine, timing) | A new standalone unit (R-ARCH-4) with a runtime test in `tests/` |
| Capture, encoder, or iOS recovery behavior | `ios/CameraStreamer.swift`, with an assertion in a source contract |
| iOS transport, queueing, or connection lifecycle | `ios/StreamSender.swift` |
| Visible status or controls on the phone | `ios/CameraViewController.swift`, via `CameraStreamer` callbacks |
| Receiver I/O, relay, or CLI | `windows/receiver.cpp`. Extract pure parts into `windows/*.h` |
| A new test | `tests/`, wired into **both** `build.yml` and `scripts/check.sh` |

## Commands

```sh
sh scripts/check.sh      # the local quality gate; mirrors CI; prints PASS/FAIL/SKIP
sh -x tests/<name>.sh …  # shows the exact failing assertion of a contract
```

Without g++/clang++, the C++ tests are SKIPped. Without Xcode, the Swift tests
are too. Linking `receiver.exe` and running `xcodebuild` happen **only in CI**.
A SKIP is an unverified check: report it, and never call it a pass.

## Mandatory workflow

Every code change follows the `implement-change` skill:

1. **Understand.** Use `repo-exploration` to find the owning module and existing patterns.
2. **Specify.** Use `acceptance-criteria` to state behavior, what must be preserved, edge cases, and done.
3. **Align (before).** Use `architecture-alignment` to confirm placement and dependency direction.
4. **Implement** the smallest complete change. Follow the conventions. Stay in scope.
5. **Validate.** Use `quality-gates`: `sh scripts/check.sh`, plus tests for the new behavior.
6. **Review.** Run `change-review` on the diff, and `architecture-alignment` again (after).
7. **Report.** Cover criteria met, checks run, checks skipped, and any risks.

Merge only after CI is green on the branch (`gh workflow run build.yml --ref <branch>`; the workflow
does not run on branch pushes), then `--no-ff` into `main` and confirm the `main` run is green.
Writing the code does not make the task complete.

## Skills (`.claude/skills/`)

| Skill | Load when |
|---|---|
| `implement-change` | Any task that modifies product code, tests, CI, or build files. It orchestrates the others |
| `repo-exploration` | You need to find where something lives or what depends on it |
| `acceptance-criteria` | Before implementing a feature or fix, or when a requirement is ambiguous |
| `architecture-alignment` | Before and after any non-trivial change; for new files, moved code, or new dependencies |
| `change-review` | Before declaring completion, or when asked to review a diff or PR |
| `quality-gates` | Running checks, interpreting failures, or adding or changing tests and gates |

Docs-only or question-only tasks don't need the full workflow. Still cite evidence.

## Invariants (never break; see the rule IDs)

- Wire format, magic, header size, codec IDs, and port 12345 match on both sides (R-ARCH-2).
- After any discontinuity, wait for a VPS+SPS+PPS+IDR join point before sending or relaying delta frames (R-ENG-RECOVER).
- The receiver validates every header before allocating, and never exits on stream failure (R-ENG-INPUT, R-ENG-ERR).
- No per-frame disk I/O, per-frame logging, or unbounded queues on the 4K60 path (R-ENG-PERF).
- The OBS relay is loopback-only; no new network exposure (R-ENG-SEC).
- Archived code and `third_party/` are untouched (R-ARCH-6, R-ARCH-7).
- Never weaken or delete a contract assertion just to make a check pass (R-ENG-TEST).

## Working efficiently

- Read this file, then only the skill for the current step. Don't preload all skills.
- `CameraStreamer.swift` (~1,250 lines) and `receiver.cpp` (~700 lines) are large. Grep for the
  symbol, then read a bounded range. Don't read them whole.
- Skip `third_party/`, `assets/`, `*.xcassets`, `project.pbxproj` (unless you are adding files to Xcode), and archived code.
- Reuse context you already gathered. Don't re-read files you just edited.
