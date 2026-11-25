# Streamer features plan: Wi-Fi, 720p–4K at 60 fps, quality advice, constant sync, Cinematic, Portrait

| | |
|---|---|
| Status | PROPOSED. G11 (Cinematic) and G12 (Portrait only) approved by the owner on 2026-11-25; the other gates in section 4 are open |
| Owner device | **iPhone 14 Pro** (see section 1.1) |
| Created | 2026-11-25 (reviewed for executor clarity the same day) |
| Baseline | `main` at `2e7086b`. Every identifier quoted in this file was checked against that commit |
| Parent | [`EXECUTION_PLAN.md`](EXECUTION_PLAN.md). Its section 0 rules, section 2 global rules and section 9 status tracker apply unchanged. This file adds **Phase 5** and amends T3.1 and T3.3 |

**Executors: read section 0 of this file, then your task in section 5. Nothing else.**
Sections 1–4 explain the owner's decisions. You don't need them to do a task.

---

## 0. Executor quick start (read this, then only your task)

### 0.1 Before you write code

1. Read `CLAUDE.md`, then `EXECUTION_PLAN.md` section 0 (rules) and section 2 (global rules).
2. Find your task's row in `EXECUTION_PLAN.md` section 9.
   - Every entry in **Depends on** must be `DONE`. `SKIPPED` also counts as satisfied.
   - An owner checkpoint (`DC-…`) is satisfied when its row is `DONE` and its result is in
     section 10 of the parent plan.
   - If the task has a **Gate**, that gate must be `APPROVED` in parent section 4.
   - If any of these fails, **stop** and tell the user which one.
3. Make the branch named in your task, from the latest `main`.
4. Grep for every identifier your task quotes before you change it. If one is missing or
   looks different, **stop and report**. Don't guess a replacement.

### 0.2 How to read a task

Each task in section 5 has the same parts, in this order:

| Part | What it means for you |
|---|---|
| Header table | Branch, model tier (H = Haiku, S = Sonnet, O = Opus or a careful Sonnet), dependencies, gate, estimate |
| Why | Background only |
| Files | The only files you may change. Touching any other file is out of scope |
| Steps | Do them in order. Code in a box is the required shape; you may rename local variables, but never names that a contract greps for |
| Contract changes | The **only** contract edits allowed. Every other contract must pass unchanged |
| Tests | New tests to add and how to wire them in |
| AC | Acceptance criteria. Each one is tagged with who verifies it: **[local]** `sh scripts/check.sh`; **[CI]** the branch CI run; **[review]** you, by reading the diff; **[device]** the owner, later, on the phone. Device ACs don't block your merge. List them as "pending device check" in your report |
| Stop and report if | Situations where you must stop instead of improvising |

### 0.3 Recipes used by several tasks

**R1. Add a new Swift file to the iOS app.** The Xcode project lists files explicitly (it is
not a synchronized folder), so `xcodebuild` ignores a file you only create on disk. In
`ios/iPhoneCameraStream.xcodeproj/project.pbxproj`, copy the four lines that mention
`LengthPrefixedHEVC.swift` and change the name and IDs:
- the `PBXBuildFile` line (the `3A…` ID),
- the `PBXFileReference` line (the `2A…` ID),
- the group `children` entry,
- the `Sources` build-phase entry.
The next free IDs at `2e7086b` are `2A0000000000000000000009` (file reference) and
`3A0000000000000000000007` (build file). Grep first to make sure they are still free.

**R2. Add a new pure C++ header under `windows/`.**
- It may include only C++ standard headers.
- Add its path to the `for header in windows/relay_timestamp.h …` list in
  `tests/architecture_boundary_contract.sh` (the R-ARCH-4 loop). This is an allowed contract
  addition for every task that creates a header.

**R3. Add a new test file to `tests/`.**
- A `.sh` file must start with `#!/usr/bin/env sh` and have `set -eu` within its first 8 lines.
- Wire it into **both** `.github/workflows/build.yml` and `scripts/check.sh`, next to a test of
  the same kind:
  - C++: copy one `g++ -std=c++20 -O2 -I"${{ github.workspace }}/windows" …` block in the
    `windows` job, and add a `cpp_test tests/<name>.cpp windows` line in `check.sh`.
  - Swift: copy the `stream_header_test` block in the `ios` job, and add a
    `swift_test tests/<name>.swift <product file>` line in `check.sh`. Start the test with
    `@main` so it compiles next to a product file.
- `tests/test_registry_contract.sh` then passes on its own. **Don't edit it.**

**R4. Things that are already true (verified at `2e7086b`). Don't re-derive them.**
- `StreamSender` state lives on its serial `queue`. Its callbacks (`onClientConnected`,
  `onFrameRate`, `onQueueLatency`, …) are called **on that queue**.
- `CameraStreamer` state lives on `sessionQueue` or behind `encoderStateLock` / `telemetryLock`.
  The capture callback `captureOutput(_:didOutput:from:)` runs on the `"capture"` queue.
- `invalidateEncoder(reason:)` already sets `forceNextKeyFrame = true`, so the next encoder starts
  with an IDR. `sender.resetForDiscontinuity(reason:)` clears the send queue and waits for that
  IDR while it keeps the PC connection (P1).
- `sender.restartListening(reason:)` drops the PC connection. Phase 5 never calls it for a
  preset change.
- The receiver keeps **one** `ObsUdpRelay` alive across phone reconnects (`run_receiver`).
  `ObsUdpRelay::Open(true)` reopens the muxer with `+initial_discontinuity`.
- `OutputOrientation` (top of `ios/CameraStreamer.swift`) is the pattern for a persisted enum:
  `preferenceKey`, a `stored` static property, and `title`.

**R5. Switch the camera input (used by T5.9 and T5.10).** Whichever of the two tasks merges
first adds this `CameraStreamer` method. The second task reuses it. Grep for
`func switchCamera(to` first.
```swift
/// Replaces the session's camera input. Runs on sessionQueue inside begin/commitConfiguration.
/// Keeps the PC connection (P1): the caller must invalidate the encoder and call resetForDiscontinuity.
private func switchCamera(to device: AVCaptureDevice) -> Bool {
    dispatchPrecondition(condition: .onQueue(sessionQueue))
    guard let newInput = try? AVCaptureDeviceInput(device: device) else { return false }
    let oldInputs = session.inputs
    oldInputs.forEach { session.removeInput($0) }
    guard session.canAddInput(newInput) else {
        oldInputs.forEach { if session.canAddInput($0) { session.addInput($0) } }
        return false
    }
    session.addInput(newInput)
    videoDevice = device
    pressureObservation = device.observe(\.systemPressureState, options: [.new]) { [weak self] _, _ in
        self?.handleSystemPressureChange()
    }
    // A new input creates a new output connection: re-apply orientation on it.
    if let output = videoOutput { _ = applyOutputOrientation(activeOutputOrientation, to: output) }
    return true
}
```

### 0.4 Glossary

| Term | Meaning |
|---|---|
| IDR | A keyframe. A decoder can start from it |
| VPS / SPS / PPS | HEVC parameter sets. The SPS carries the picture width and height |
| Join point | One access unit holding VPS + SPS + PPS + IDR. After any break, nothing is sent or relayed until one arrives |
| P1 | A media change (camera, encoder, preset) is not a transport reset: keep the socket, wait for an IDR |
| Preset | One capture mode: resolution + frame rate (+ camera + effect) |
| Gate (Gxx) | An owner decision in parent section 4 |
| DC-x | An owner device checkpoint (manual test on the phone) |
| Glass-to-glass | Delay from a real event in front of the camera to the same event on the PC screen (method in T2.3 docs) |
| usbmux | Apple's USB tunnel. `receiver.exe` with no `--host` uses it |
| WMM | Wi-Fi traffic priority classes. `.interactiveVideo` maps to the video class |

---

## 1. What the owner asked for, and what is physically possible

| Request | Verdict | Why (evidence) |
|---|---|---|
| Stream over Wi-Fi as well as USB | **Yes** | The phone already listens on every interface (D4). `receiver.exe --host <ip>` exists (T0.4, merged). T3.1 adds the safe opt-in switch |
| Quality options 720p, 1080p, 4K, all at 60 fps | **Yes** | The code locks only 3840x2160@60 today (`apply4K60Format`, `is4KFrame`). iPhone back cameras expose native 1280x720, 1920x1080 and 3840x2160 formats at 60 fps. The receiver hard-codes 3840x2160 in the relay (`windows/receiver.cpp`, `stream_->codecpar->width = 3840`) and must follow the real size |
| "No frame drops, ever" | **Only as a policy, not a guarantee** | Over USB it is achievable. Over Wi-Fi no protocol can guarantee it: if the radio carries less than the bitrate, something must give. The order is: **1) lower the bitrate, 2) recommend a lower preset, 3) only then drop, and every drop waits for an IDR (T1.6) so the picture never smears.** Every drop is counted and shown |
| "Nothing goes out of sync" | **Yes, with a fixed latency per mode** | Video can't have zero delay. It can have a *constant* delay, which you cancel once with the mic's OBS Sync Offset. Over Wi-Fi this needs a fixed-delay playout buffer in the receiver (T5.6). Each mode (USB/Wi-Fi × preset × Cinematic) gets its own measured constant in the docs |
| Notification suggesting the best quality | **Yes** | An in-app banner on the phone (the camera app is always in the foreground while streaming, so a push notification adds nothing). It uses TCP RTT and retransmit stats (`NWConnection` data transfer reports), send-queue age, drops and thermal state |
| Cinematic mode | **Native, but 30 fps only** | iOS 26 added `AVCaptureDeviceInput.isCinematicVideoCaptureEnabled`. Apple's WWDC25 session 319 says the bokeh **is baked into `AVCaptureVideoDataOutput` frames**, so it fits our pipeline, and that *"both 1080p and 4K are supported at 30 frames per second"* on Dual Wide (rear) and TrueDepth (front) cameras only. **Approved as a 30 fps exception (G11)** |
| Background blur "like on the Mac" | **Native Portrait effect only, ≤1080p, approved (G12)** | On Windows nothing equivalent exists, so the phone must render it. iOS system video effects are opted into by the app and toggled by the **user** in Control Center. Apple's camera engineer: *"they only support video smaller than 1920 x 1440"*, so **never 4K**. The frame rate is capped per format (`videoFrameRateRangeForPortraitEffect`). Studio Light and Background Replacement are out of scope (owner choice) |
| Center Stage | **Not planned** | Mostly a front/ultra-wide feature. T5.2 reports it for information only |

Rejected on purpose:
- **Custom background removal (Vision segmentation, Core Image compositing).** Per-frame GPU work and latency on the 4K60 path (R-ENG-PERF), and not the system feature the owner asked for.
- **New transport protocols (QUIC, SRT, RIST, WebRTC).** Third-party stacks or big rewrites. Bitrate adaptation + a constant-latency buffer + the keyframe gate on one TCP stream is enough for 25 Mbps on a good 5/6 GHz network. The wire format stays frozen.
- **Phone audio.** The owner uses a separate mic.
- **Swift 6 language mode.** A separate repo-wide change. These tasks build with the iOS 26 SDK, keep `-swift-version 5`, and use only non-deprecated APIs.
- **1440p (G10).** No native 16:9 1440p format; it would need a per-frame GPU scale.

### 1.1 Owner device: iPhone 14 Pro

- **iOS 26 is supported** on iPhone 14 Pro. Cinematic needs the phone on iOS 26 or later (Settings → General → About).
- **Cinematic:** Apple's spec sheet lists Cinematic mode up to 4K HDR at 30 fps. The rear **Dual Wide** camera (wide + ultra wide) exists on the 14 Pro. Expected presets: **Cinematic 1080p30 and 4K30.** T5.2 confirms `isCinematicVideoCaptureSupported`.
- **Portrait effect:** native since iOS 15, toggled by the user. Only formats below 1920x1440, so **1080p at most**, fps capped (expected 30 or lower). **Unknown until T5.2 runs:** whether the *rear* camera supports it. The effect is built around the front TrueDepth camera, so T5.10 falls back to the front camera.
- **4K60, 1080p60, 720p60:** supported on the rear wide camera.

Toolchain: Xcode 26.x / iOS 26 SDK, deployment target stays iOS 17.0 behind `if #available` checks.
Windows: FFmpeg 8.x from MSYS2 UCRT64 (as today) and the system DNS-SD API for discovery.
**No new third-party packages anywhere.**

---

## 2. Target architecture after Phase 5

```
iPhone                                                                  Windows
Preset (720p60 | 1080p60 | 4K60 | Cinematic 30 | Portrait ≤30)          receiver.exe
  │                                                                       │
Capture ─► HEVC (VideoToolbox, live bitrate) ─► StreamSender ═ TCP :12345 ═► header check ─► join gate
  ▲               ▲                                │ USB (usbmux)          │   --host <ip> | --wifi (Bonjour)
  │               └─ adaptive bitrate ◄────────────┤ Wi-Fi (opt-in, WMM video)
  │                                                │                       ├─► SPS size follow (hevc_sps.h)
  └─ QualityAdvisor ◄─ RTT / retransmits / queue age / drops / thermal     ├─► constant-latency playout (relay_playout.h)
        └─► banner "1080p60 recommended" [Switch]                           └─► MPEG-TS ─► udp://127.0.0.1:12346 ─► OBS
Portrait effect (user, Control Center) ─► only on the Portrait 1080p preset
```

New pure units (R-ARCH-4), each with a runtime test:
- `ios/QualityAdvisor.swift` (Foundation only): link stats in, bitrate step and advice out.
- `windows/hevc_sps.h` (C++ std only): picture width and height from an HEVC SPS.
- `windows/relay_playout.h` (C++ std only): fixed-delay release times, late counter, skew-aware offset.

The wire format is **unchanged**. Resolution travels in the SPS. No D3 decision is needed.

---

## 3. Order, estimates, and critical path

Estimates are agent working time per task, including at least one CI run (about 20 min each).
"Owner" means hands-on time with the phone.

**Owner decisions that block work (decide these first):**
- **G7** blocks T3.1, which blocks T5.4, and T5.4 blocks T5.7–T5.10. Approve G7 option A to unblock most of Phase 5.
- **G8′** blocks T5.4. **G14** blocks T5.8. **G13** is decided after DC-5b.
- **G1** (test tooling) is still PENDING. Without it, T5.5 and T5.6 get unit tests only, and their e2e ACs stay open.

| Wave | Task | What | Model | Est. | Gate | Depends on |
|---|---|---|---|---|---|---|
| A | T5.0 | Real disconnect cause (POSIX code) + close failed connections | H | 2 h | — | — |
| A | T5.1 | CI builds with the Xcode 26 / iOS 26 SDK | H | 1–2 h | — | — |
| A | T5.2 | Device capability probe (formats, 60 fps, Cinematic, Portrait) | S | 4 h | — | T5.1 |
| A | T5.5 | Receiver follows resolution changes (SPS parse, relay reopen) | S | 1 day | — | — |
| A | DC-4 | **Owner:** run the probe, paste the report | — | 15 min | — | T5.2 |
| B | T3.1 | Wi-Fi mode, opt-in (amended: WMM video class) | S | 5 h | G7 | T1.4, T0.4 |
| B | DC-5a | **Owner:** USB vs Wi-Fi A/B at 4K60 ("is the problem USB?") | — | 30 min | — | T5.0, T3.1 |
| C | T5.4 | Quality presets 720p60 / 1080p60 / 4K60 (supersedes T3.2) | S | 1 day | G8′ | T3.1, T5.5 |
| C | T5.8 | Adaptive bitrate inside a preset | S | 0.5–1 day | G14 | T5.4 |
| C | T5.7 | Quality advisor + banner | S | 1 day | — | T5.8 |
| D | DC-5b | **Owner:** Wi-Fi presets, jitter, glass-to-glass per mode | — | 1–2 h | — | T5.4, T5.5, T5.7, T5.8 |
| D | T5.6 | Constant-latency playout buffer (receiver) | O | 1.5–2 days | G13 | T5.5, DC-5b |
| E | T5.9 | Cinematic 1080p30 / 4K30 | O | 1.5 days | G11 | T5.4, DC-4 |
| E | T5.10 | Portrait effect (rear, or front-camera fallback) | S | 1 day | G12 | T5.4, DC-4 |
| F | T3.3 | Bonjour discovery `receiver.exe --wifi` (mini-plan first) | O | 1–1.5 days | G7 | T3.1 |
| F | T5.11 | Docs: Wi-Fi setup, presets, per-mode sync table, effects | H | 3 h | — | T5.0–T5.10, T3.3 |
| F | DC-6 | **Owner:** final device pass + 30 min Wi-Fi soak | — | 1.5 h | — | T5.11 |

There is no T5.3; the number was retired during planning. T5.8 runs before T5.7 on purpose
(the advisor reads the bitrate state that T5.8 adds).

**Totals:** about **11 agent-days** (range 9–13), plus **4–6 h of owner time** over 4 checkpoints.
Calendar about **3–4 weeks** at one merged, CI-green task per day. The fastest answer to "is the
USB link the problem?" is T5.0 + T3.1 + DC-5a, about **1 day**.

Biggest schedule risks:
1. **OBS behavior on a resolution change** (T5.5). OBS's Media Source may need a source restart. The documented fallback is to re-activate the source. DC-5b decides.
2. **Wi-Fi quality at home.** On 2.4 GHz, or with the PC also on Wi-Fi, 4K60 may never be stable. Then "Wi-Fi = 1080p60" is the honest outcome, and the advisor says so.
3. **The CI runner's Xcode 26** (T5.1). If `macos-15` lacks it, the job moves to `macos-26`.

---

## 4. New and changed gates (decisions live in `EXECUTION_PLAN.md` section 4)

| Gate | Decision | Recommendation |
|---|---|---|
| G7 | (existing) Wi-Fi opt-in, unauthenticated, off by default | **Approve option A** |
| G8′ | **Replaces G8.** Average / peak Mbps: 720p60 USB 10/20, Wi-Fi 8/16 · 1080p60 USB 20/40, Wi-Fi 15/30 · 4K60 USB 40/80 (today), Wi-Fi 25/50. Cinematic and Portrait presets use the numbers of the 60 fps preset with the same resolution | Approve. Peak is set as `DataRateLimits` = average / 4 bytes per 1 s, the same ratio as today |
| G10 | 1440p60 preset scaled from 4K | **Reject for now** |
| G11 | Cinematic as an explicit 30 fps exception | **APPROVED 2026-11-25** |
| G12 | Portrait effect only, at the format's capped fps; rear camera, else front; never 4K | **APPROVED 2026-11-25**, conditional on DC-4 showing support on at least one camera |
| G13 | Receiver holds video at a fixed latency (default 0 ms USB, 80 ms Wi-Fi, `--latency-ms N`) | Approve if DC-5b shows Wi-Fi arrival jitter p99 > 17 ms (one frame) |
| G14 | Automatic bitrate down/up within the chosen preset (floor 50%). Resolution is never auto-switched | Approve |

---

## 5. Tasks

### T5.0 Real disconnect cause

| Branch | Model | Depends on | Gate | Est. |
|---|---|---|---|---|
| `diag/ios-nwerror-detail` | H | — | — | 2 h |

**Why:** `error.localizedDescription` on an `NWError` often prints only "NWError error N", so the
cause is lost. A connection that reaches `.failed` is also never cancelled.

**Files:** `ios/StreamSender.swift`, `tests/stream_sender_source_contract.sh`.

**Steps:**
1. Add this method inside `StreamSender`:
   ```swift
   private static func describe(_ error: NWError) -> String {
       switch error {
       case .posix(let code):
           return "POSIX \(code.rawValue) \(String(cString: strerror(code.rawValue)))"
       case .dns(let code):
           return "DNS \(code)"
       case .tls(let status):
           return "TLS \(status)"
       default:
           return String(describing: error)
       }
   }
   ```
   (`strerror` comes in through Foundation. Don't add an `import`: the boundary contract allows
   only Foundation and Network in this file.)
2. Replace **every** `error.localizedDescription` in `ios/StreamSender.swift` with
   `Self.describe(error)`. At `2e7086b` there are 8: the listener `.waiting` and `.failed` lines, the
   connection `.waiting` and `.failed` lines, and the two in the send-completion error branch.
3. In the connection `stateUpdateHandler`, `case .failed(let error):`, add `conn.cancel()` as the
   last line of the case (after `self.report(...)`). This is safe: the case already sets
   `self.connection = nil`, so the `.cancelled` that follows fails the
   `self.connection === conn` guard and is not reported a second time.

**Contract changes:** add to `tests/stream_sender_source_contract.sh`:
```sh
# T5.0: NWError causes are reported with their POSIX code.
grep -q 'private static func describe(_ error: NWError)' "$1"
if grep -q 'error.localizedDescription' "$1"; then
  echo "StreamSender must report NWError via describe(_:)" >&2
  exit 1
fi
```
(Use `if … exit 1` and not `! grep`: `set -e` ignores a failing `!` command, so a `! grep` line can
never fail the contract.)

**AC:**
- AC1 [local] `check.sh` 0 FAIL.
- AC2 [CI] `stream_sender_test.swift` and the IPA build pass.
- AC3 [review] `.failed` ends with `conn.cancel()`, and there's no other behavior change.
- AC4 [device] Killing `receiver.exe` shows `POSIX 54` or `POSIX 32` on the phone, once per drop.

**Stop and report if:** an error in the file isn't an `NWError` (then `describe` won't compile for it).

---

### T5.1 Xcode 26 SDK in CI

| Branch | Model | Depends on | Gate | Est. |
|---|---|---|---|---|
| `ci/xcode-26-sdk` | H | — | — | 1–2 h |

**Why:** the Cinematic APIs exist only in the iOS 26 SDK. The `ios` job runs on `macos-15` with no
Xcode pin.

**Files:** `.github/workflows/build.yml`, new `tests/ios_ci_contract.sh`, `scripts/check.sh`.

**Steps:**
1. In the `ios` job, right after `- uses: actions/checkout@v6`, add these three steps:
   ```yaml
         - name: Select newest Xcode 26
           run: |
             xc=$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1 || true)
             if [ -n "$xc" ]; then sudo xcode-select -s "$xc"; fi

         - name: Require iOS 26 SDK
           run: |
             xcodebuild -version
             sdk=$(xcrun --sdk iphoneos --show-sdk-version)
             echo "iphoneos SDK $sdk"
             [ "${sdk%%.*}" -ge 26 ] || { echo "iOS SDK $sdk is older than 26"; exit 1; }

         - name: Print camera API names from the SDK (used by T5.9 and T5.10)
           run: |
             h="$(xcrun --sdk iphoneos --show-sdk-path)/System/Library/Frameworks/AVFoundation.framework/Headers"
             grep -ho 'NSCamera[A-Za-z]*' "$h"/*.h | sort -u || true
             grep -hn 'Cinematic\|imulatedAperture\|PortraitEffect' "$h"/*.h | head -120 || true
   ```
2. Push the branch and run CI (`gh workflow run build.yml --ref ci/xcode-26-sdk`).
   - If "Require iOS 26 SDK" fails, change the `ios` job's `runs-on: macos-15` to
     `runs-on: macos-26` and run CI again.
3. Don't change `IPHONEOS_DEPLOYMENT_TARGET = 17.0` or `-swift-version 5`.
4. Create `tests/ios_ci_contract.sh`:
   ```sh
   #!/usr/bin/env sh
   # T5.1: the iOS job must build with the iOS 26 SDK (Cinematic APIs).
   set -eu
   workflow="${1:-.github/workflows/build.yml}"
   grep -q 'name: Require iOS 26 SDK' "$workflow"
   grep -q 'show-sdk-version' "$workflow"
   grep -q -- '-ge 26' "$workflow"
   ```
   Wire it in (R3): in `build.yml`, after the `sh tests/test_registry_contract.sh …` line, add
   `sh tests/ios_ci_contract.sh .github/workflows/build.yml`. In `check.sh`, after the
   `run "windows CI contract" …` line, add
   `run "iOS CI contract" sh tests/ios_ci_contract.sh .github/workflows/build.yml`.
5. Copy the output of the "Print camera API names" step into your PR or report. T5.9 and T5.10 take
   exact API names from it.

**Contract changes:** only the new `tests/ios_ci_contract.sh`.

**AC:**
- AC1 [local] `check.sh` shows "iOS CI contract" PASS.
- AC2 [CI] the log shows SDK 26.x, and the IPA still builds.
- AC3 [CI] the API-name step prints at least one `Cinematic` line.

**Stop and report if:** neither `macos-15` nor `macos-26` gives SDK 26.

---

### T5.2 Device capability probe

| Branch | Model | Depends on | Gate | Est. |
|---|---|---|---|---|
| `diag/ios-capability-probe` | S | T5.1 | — | 4 h |

**Why:** which features exist depends on the phone. This task measures them. It doesn't change
the streaming path.

**Files:** `ios/CameraStreamer.swift`, `ios/CameraViewController.swift`,
`tests/camera_feedback_source_contract.sh`.

**Steps:**
1. In `CameraStreamer`, add `func capabilityReport(completion: @escaping (String) -> Void)`. It runs
   the work on `sessionQueue`, only reads, and calls `completion` on the main queue.
2. Report header lines: device model identifier (from `uname`, field `machine`), iOS version
   (`UIDevice.current.systemVersion`), thermal state.
3. Enumerate cameras with
   `AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInDualWideCamera, .builtInTripleCamera, .builtInTrueDepthCamera], mediaType: .video, position: .unspecified).devices`.
   This includes the **front** cameras, which T5.10 may fall back to.
4. For each device and each format whose dimensions are 1280x720, 1920x1080, 1920x1440 or 3840x2160,
   and whose pixel subtype is `'420v'` or `'x420'`, print one line:
   ```
   <back|front> <deviceType> <W>x<H> <subtype> maxFps=<n> 60fps=<y|n> portrait=<y|n>@<maxFps> studio=<y|n> centerStage=<y|n> bg=<y|n> cinematic=<y|n>
   ```
   - `portrait`: `format.isPortraitEffectSupported` and
     `format.videoFrameRateRangeForPortraitEffect?.maxFrameRate`. Available on iOS 15, so no
     `#available` check is needed with the iOS 17 deployment target.
   - `studio`: `format.isStudioLightSupported` (iOS 16). `centerStage`: `format.isCenterStageSupported`.
   - `bg`: `format.isBackgroundReplacementSupported` inside `if #available(iOS 18, *)`, else `n/a`.
   - `cinematic`: `format.isCinematicVideoCaptureSupported` inside `if #available(iOS 26, *)`, else
     `n/a`. Use the exact name printed by T5.1.
   - Convert the subtype `FourCharCode` to text with a small helper. Don't print raw numbers.
5. In `CameraViewController`, add a small "Capabilities" `UIButton`. On tap it calls
   `streamer.capabilityReport` and presents a view controller with a read-only, monospaced
   `UITextView` and a **Copy** button (`UIPasteboard.general.string = text`). The view controller
   must not reference `StreamSender` (R-ARCH-3).
6. No per-frame work. The report runs only on a button press.

**Contract changes:** add to `tests/camera_feedback_source_contract.sh`:
`grep -q 'func capabilityReport(completion:' "$streamer"` (with a `# T5.2` comment line). Check the
variable name the contract uses for the streamer file first.

**AC:**
- AC1 [CI] the IPA builds; the boundary contract passes.
- AC2 [review] the report lists the 4K60 rear wide format the app already uses, and at least one front camera.
- AC3 [device] the owner can copy the report (DC-4).

---

### DC-4 Owner: capability report

1. Install the IPA from the CI run of `main` after T5.2 is merged.
2. Tap **Capabilities → Copy** and paste the text into section 10 of `EXECUTION_PLAN.md`.
3. Set DC-4 to `DONE` in section 9.

What the report decides:
- T5.9 goes ahead if a rear `builtInDualWideCamera` line shows `cinematic=y`.
- T5.10 uses the rear camera if a rear 1920x1080 line shows `portrait=y`, else the front
  camera if a front 1920x1080 line shows `portrait=y`. Otherwise T5.10 is `SKIPPED`.

---

### T3.1 Wi-Fi mode (amended)

Do T3.1 exactly as written in `EXECUTION_PLAN.md` section 6, plus one step:
- In `StreamSender.startOnQueue`, right after `let params = NWParameters(tls: nil, tcp: tcpOptions)`,
  add `params.serviceClass = .interactiveVideo` (the Wi-Fi WMM video class; harmless on USB).
- Contract addition in `tests/stream_sender_source_contract.sh`:
  `grep -q 'params.serviceClass = .interactiveVideo' "$1"`.

The estimate is unchanged (about 5 h). T3.2 is `SKIPPED` (superseded by T5.4 and T5.8): don't do it.

---

### DC-5a Owner: USB vs Wi-Fi A/B

Needs T5.0 and T3.1 merged.
1. Stream 4K60 for 10 min over USB (`receiver.exe`).
2. Turn on the Wi-Fi switch and stream 10 min over Wi-Fi (`receiver.exe --host <phone ip>`).
3. For each run, record the `LINK reconnects` count and the exact `last:` reasons (now with POSIX codes).

Reading the result: USB drops and Wi-Fi doesn't → the USB path (cable, hub, Apple Mobile Device
Service, USB selective suspend). Both drop → the app or the receiver.

---

### T5.5 Receiver follows the resolution

| Branch | Model | Depends on | Gate | Est. |
|---|---|---|---|---|
| `feat/receiver-resolution-follow` | S | — | — | 1 day |

**Why:** `ObsUdpRelay::Open` declares 3840x2160 forever (F13), so a 1080p or portrait stream is
announced with the wrong size.

**Files:** new `windows/hevc_sps.h`, `windows/receiver.cpp`, new `tests/hevc_sps_test.cpp`,
`tests/architecture_boundary_contract.sh` (R2), `tests/receiver_source_contract.sh`,
`.github/workflows/build.yml`, `scripts/check.sh`.

**Steps:**
1. Create `windows/hevc_sps.h` (C++ std headers only, R2) with two functions:
   ```cpp
   // Parses one SPS NAL unit (starting at its 2-byte NAL header, no start code).
   // Returns false on any malformed or truncated input. Never reads out of bounds.
   inline bool HevcSpsDimensions(const uint8_t* nal, size_t size, int* width, int* height);
   // Finds the first SPS (NAL type 33) in an Annex-B access unit and parses it.
   inline bool HevcAccessUnitDimensions(const uint8_t* au, size_t size, int* width, int* height);
   ```
   - **Bit reader:** reads bits MSB-first from `nal`. It removes emulation-prevention bytes
     while reading: keep a count of consecutive `0x00` bytes; when the count is ≥ 2 and the next
     byte is `0x03`, skip that byte and reset the count. No buffer copy, no allocation.
     `ue(v)`: count leading zero bits (fail if more than 31), then read that many bits.
   - **Field order** (H.265 section 7.3.2.2). Read and discard unless noted:
     1. NAL header: 16 bits.
     2. `sps_video_parameter_set_id` u(4).
     3. `sps_max_sub_layers_minus1` u(3) → `m`. Fail if `m > 6`.
     4. `sps_temporal_id_nesting_flag` u(1).
     5. `profile_tier_level`: 96 bits (88 general profile bits + 8-bit `general_level_idc`). Then
        for `i` in `0..<m`: read 2 flags, `profilePresent[i]` u(1) and `levelPresent[i]` u(1). If
        `m > 0`, read 2 bits for each `i` in `m..<8`. Then for `i` in `0..<m`: skip 88 bits if
        `profilePresent[i]`, and 8 bits if `levelPresent[i]`.
     6. `sps_seq_parameter_set_id` ue(v).
     7. `chroma_format_idc` ue(v); fail if > 3. If it equals 3, read `separate_colour_plane_flag` u(1).
     8. `pic_width_in_luma_samples` ue(v), `pic_height_in_luma_samples` ue(v).
     9. `conformance_window_flag` u(1). If 1, read left, right, top, bottom offsets, each ue(v).
   - **Crop:** `(SubWidthC, SubHeightC)` = (1,1) for chroma 0, (2,2) for 1, (2,1) for 2, (1,1)
     for 3. `width = pic_width − SubWidthC × (left + right)` and
     `height = pic_height − SubHeightC × (top + bottom)`. Use 64-bit math. Fail unless both
     end in `16..16384`.
   - `HevcAccessUnitDimensions` scans for 3- and 4-byte start codes the same way as
     `InspectHevcAccessUnit` in `hevc_access_unit.h`. The NAL type is `(byte >> 1) & 0x3f`. It
     passes the bytes up to the next start code (or the end) to `HevcSpsDimensions`.
2. Create `tests/hevc_sps_test.cpp` (R3, C++). Use these golden SPS NAL units. They were produced
   with `ffmpeg -f lavfi -i testsrc2=size=WxH:rate=60 -frames:v 1 -c:v libx265 -f hevc`, and
   checked by an independent parser:

   | Expected | Notes | SPS bytes (hex, NAL header first) |
   |---|---|---|
   | 1280x720 | | `420101016000000300900000030000030078a00280802d165959a4932bc05a020000030002000003007810` |
   | 1920x1080 | | `42010101600000030090000003000003007ba003c08010e596566924caf0168080000003008000001e04` |
   | 3840x2160 | | `420101016000000300900000030000030099a001e020021c596566924caf016808000003000800000301e040` |
   | 2160x3840 | portrait | `420101016000000300900000030000030099a0010e2003c0596566924caf016808000003000800000301e040` |
   | 1916x1076 | conformance window crop | `42010101600000030090000003000003007ba003c08010e77796566924caf0168080000003008000001e04` |
   | 1920x1080 | 2 temporal sub-layers (`m = 1`) | `42010201600000030090000003000003007b0000a003c08010e5965662b349265780b404000003000400000300f020` |

   Also test:
   - every vector truncated at each length from 0 to `size − 1` returns `false` and doesn't crash
   - an empty buffer
   - a null pointer
   - 64 bytes of `0xff`
   - `HevcAccessUnitDimensions` on `00 00 00 01` + VPS bytes + `00 00 01` + the 1080p SPS
3. Wire the test into `build.yml` and `check.sh` (R3). Add `windows/hevc_sps.h` to the boundary
   contract's header list (R2).
4. In `ObsUdpRelay` (`windows/receiver.cpp`):
   - Add members `int width_ = 3840; int height_ = 2160;`. In `Open`, use them instead of the
     literals `3840` and `2160`.
   - At the top of `Write`, before the recovery gate:
     ```cpp
     if (accessUnit.IsDecoderJoinPoint()) {
         int w = 0, h = 0;
         if (HevcAccessUnitDimensions(source.data, static_cast<size_t>(source.size), &w, &h) &&
             (w != width_ || h != height_)) {
             width_ = w;
             height_ = h;
             printf("INFO: stream size %dx%d\n", w, h);
             if (!Open(true)) {
                 width_ = 0;  // forces a retry at the next join point
                 height_ = 0;
                 return RelayWriteResult::Failed;
             }
         }
     }
     ```
     This runs only at join points (about once every 2 s), allocates nothing, and logs only when
     the size changes (R-ENG-PERF).
   - Add `#include "hevc_sps.h"` next to `#include "hevc_access_unit.h"`.
5. Don't touch `avg_frame_rate` (OBS paces by PTS).

**Contract changes:**
- `tests/receiver_source_contract.sh`: add these lines, with a `# T5.5` comment line. No existing
  assertion pins 3840 (checked at `2e7086b`).
  ```sh
  grep -q 'HevcAccessUnitDimensions' "$1"
  if grep -q 'codecpar->width = 3840' "$1"; then echo "relay must use the SPS size" >&2; exit 1; fi
  ```
- `tests/architecture_boundary_contract.sh`: add `windows/hevc_sps.h` to the R-ARCH-4 list (R2).

**AC:**
- AC1 [CI] `hevc_sps_test` passes, and the receiver links.
- AC2 [review] no allocation or log line per frame.
- AC3 [CI, needs G1] the e2e harness streams 1080p then 720p and ffprobe sees both sizes. Without G1, report it as open.
- AC4 [device, DC-5b] OBS follows a preset change without a manual restart, **or** T5.11 documents the one-click fallback.

**Stop and report if:** a golden vector doesn't parse to its expected size. Check your bit reader
against the field list; don't change the vectors.

---

### T5.4 Quality presets

| Branch | Model | Depends on | Gate | Est. |
|---|---|---|---|---|
| `feat/ios-quality-presets` | S | T3.1, T5.5 | G8′ | 1 day |

**Behavior:**
- A segmented control **720p · 1080p · 4K** (all 60 fps), persisted, default 4K.
- Switching keeps the PC connection (P1): the receiver sees a new VPS/SPS/PPS + IDR and follows
  the size (T5.5).
- The bitrate depends on preset and transport (USB or Wi-Fi), per G8′.

**Files:** `ios/CameraStreamer.swift`, `ios/StreamSender.swift`, `ios/CameraViewController.swift`,
`tests/encoder_setup_source_contract.sh`, `tests/camera_orientation_timestamp_contract.sh`,
`tests/camera_feedback_source_contract.sh`, `tests/stream_sender_source_contract.sh`.

**Steps:**
1. In `ios/CameraStreamer.swift`, below `OutputOrientation`, add this (keep the `return` lines
   exactly; contracts grep them):
   ```swift
   enum StreamPreset: String, CaseIterable {
       case p720 = "720p60"
       case p1080 = "1080p60"
       case p2160 = "4K60"

       static let preferenceKey = "stream.preset"
       static var stored: StreamPreset {
           guard let value = UserDefaults.standard.string(forKey: preferenceKey),
                 let preset = StreamPreset(rawValue: value) else { return .p2160 }
           return preset
       }

       var width: Int { switch self { case .p720: return 1280; case .p1080: return 1920; case .p2160: return 3840 } }
       var height: Int { switch self { case .p720: return 720; case .p1080: return 1080; case .p2160: return 2160 } }
       var frameRate: Int { 60 }
       var title: String { switch self { case .p720: return "720p"; case .p1080: return "1080p"; case .p2160: return "4K" } }

       /// Average bit rates in bits per second (gate G8′). Peak = average / 4 bytes per 1 s.
       var bitRates: (usb: Int, wifi: Int) {
           switch self {
           case .p720: return (usb: 10_000_000, wifi: 8_000_000)
           case .p1080: return (usb: 20_000_000, wifi: 15_000_000)
           case .p2160: return (usb: 40_000_000, wifi: 25_000_000)
           }
       }
   }
   ```
2. Add state guarded by `encoderStateLock`: `private var activePreset = StreamPreset.stored` and
   `private var linkIsWiFi = false`. Add helpers `currentPreset() -> StreamPreset` and
   `currentBitRate() -> Int` (returns `linkIsWiFi ? preset.bitRates.wifi : preset.bitRates.usb`),
   both taking the lock.
3. Rename and generalize. Each of these is a contract-pinned name; see Contract changes:
   - `apply4K60Format(to:)` → `applyFormat(_ preset: StreamPreset, to device: AVCaptureDevice) -> Bool`.
     Inside, `matching4K60Formats` → `matchingFormats`, filter on `preset.width`/`preset.height`
     and `preset.frameRate`, and use `CMTime(value: 1, timescale: CMTimeScale(preset.frameRate))`.
     Keep the 420v preference and the HDR-off order exactly. The failure text becomes
     `"This iPhone has no \(preset.rawValue) format"`.
   - Both callers: `configureSession` → `applyFormat(currentPreset(), to: device)`;
     `recoverSession` → the same.
   - `is4KFrame(width:height:)` → `isPresetFrame(width:height:)`: true when
     `(width, height)` equals `(p.width, p.height)` or `(p.height, p.width)` for `p = currentPreset()`.
   - In `captureOutput`, the one-time report text becomes
     `"Camera delivered \(width)x\(height), expected \(currentPreset().rawValue)"`.
   - `refreshActiveFormatTelemetry`: compare with the current preset's size and frame rate.
     The state text becomes `"VERIFIED \(preset.rawValue)"` or `"MISMATCH"`, and the request text
     uses `preset.frameRate`.
   - `"CAMERA active • first 4K frame received"` → `"CAMERA active • first frame received"`, and
     `"CAMERA running • waiting for first 4K frame"` → `"CAMERA running • waiting for first frame"`.
4. In `createEncoder(width:height:)`:
   - `let target = currentBitRate()` at the top.
   - `let rateLimit: CFArray = [NSNumber(value: target / 4), NSNumber(value: 1)] as CFArray`
   - `kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: target)`
   - `kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: currentPreset().frameRate)`
   - Leave `MaxKeyFrameInterval` at 120.
5. Transport detection in `StreamSender`:
   - Add `var onClientTransport: ((Bool) -> Void)?` (true = Wi-Fi).
   - In the connection `case .ready:`, just before `self.onClientConnected?()`, add
     `self.onClientTransport?(conn.currentPath?.usesInterfaceType(.wifi) ?? false)`.
6. In `CameraStreamer`, next to `sender.onClientConnected = …`:
   ```swift
   sender.onClientTransport = { [weak self] overWiFi in self?.setLinkIsWiFi(overWiFi) }
   ```
   `setLinkIsWiFi` stores the value under `encoderStateLock`. If it changed, it calls
   `applyLiveBitRate()`, which takes the current encoder under the lock and sets
   `AverageBitRate` and `DataRateLimits` with `VTSessionSetProperty`. A failure is reported once
   with `report(...)` and is not fatal.
7. Add `func setPreset(_ preset: StreamPreset)` that runs on `sessionQueue`:
   1. Guard `isConfigured`, `!stopped` and `let device = videoDevice`.
   2. `session.beginConfiguration()`, `let ok = applyFormat(preset, to: device)`,
      `session.commitConfiguration()`. If `!ok`, report the failure and keep the old preset.
   3. Set `activePreset = preset` under the lock, and save `preset.rawValue` under
      `StreamPreset.preferenceKey`.
   4. `invalidateEncoder(reason: nil)`, then
      `sender.resetForDiscontinuity(reason: "Preset \(preset.rawValue)")`, then
      `refreshActiveFormatTelemetry(device)`.
   5. Call `onPresetChanged?(preset)` on main.
   Never call `restartListening` here.
8. Availability: add `var onPresetAvailability: (([StreamPreset]) -> Void)?`. At the end of
   `configureSession`, compute the presets that have a matching format (the same filter as
   `applyFormat`, with no `lockForConfiguration`) and call the callback on main. Also add
   `var onPresetChanged: ((StreamPreset) -> Void)?`.
9. In `CameraViewController`, add `presetControl = UISegmentedControl(items: StreamPreset.allCases.map(\.title))`
   below `orientationControl`. Its selected index comes from `StreamPreset.stored`, and
   `.valueChanged` calls `streamer.setPreset(StreamPreset.allCases[index])`.
   `onPresetAvailability` disables missing segments with `setEnabled(false, forSegmentAt:)` and
   shows "<title> not supported on this iPhone" in the status text. `onPresetChanged` re-selects
   the segment.

**Contract changes (each edit gets a `# T5.4` comment line):**
- `tests/encoder_setup_source_contract.sh`:
  - `grep -q 'private func apply4K60Format'` → `grep -q 'private func applyFormat'`
  - `grep -q 'let matching4K60Formats = device.formats.filter'` → `grep -q 'let matchingFormats = device.formats.filter'`
  - `grep -q 'matching4K60Formats.first(where:'` → `grep -q 'matchingFormats.first(where:'`
  - `grep -q 'AverageBitRate, value: NSNumber(value: 40_000_000)'` → `grep -q 'AverageBitRate, value: NSNumber(value: target)'` **plus** `grep -q 'case .p2160: return (usb: 40_000_000, wifi: 25_000_000)'`
  - `grep -q '\[NSNumber(value: 10_000_000), NSNumber(value: 1)\] as CFArray'` → `grep -q '\[NSNumber(value: target / 4), NSNumber(value: 1)\] as CFArray'`
  - keep `grep -q 'DataRateLimits, value: rateLimit'` and `grep -q 'MaxKeyFrameInterval, value: NSNumber(value: 120)'` unchanged
- `tests/camera_orientation_timestamp_contract.sh`: `grep -q 'is4KFrame(width: width, height: height)'` → `grep -q 'isPresetFrame(width: width, height: height)'`
- `tests/camera_feedback_source_contract.sh`: `grep -q 'CAMERA active • first 4K frame received'` → `grep -q 'CAMERA active • first frame received'`
- `tests/stream_sender_source_contract.sh`: add `grep -q 'onClientTransport' "$1"`

All other assertions (HDR order, keyframe interval, encoder generation, recovery) must pass unchanged.

**AC:**
- AC1 [local] `check.sh` 0 FAIL.
- AC2 [CI] IPA build passes.
- AC3 [review] 4K over USB produces the same encoder settings as today: 40,000,000 average, 10,000,000 bytes/s limit, 60 fps, interval 120.
- AC4 [review] `setPreset` never calls `restartListening`.
- AC5 [device] each preset shows `VERIFIED <preset>` on the phone.
- AC6 [device] switching presets doesn't increase `LINK reconnects`.
- AC7 [device] OBS shows the new size within 2 s.

**Stop and report if:** a contract other than the four listed fails, or the change grows past
about 200 product lines.

---

### T5.8 Adaptive bitrate

| Branch | Model | Depends on | Gate | Est. |
|---|---|---|---|---|
| `feat/ios-adaptive-bitrate` | S | T5.4 | G14 | 0.5–1 day |

**Files:** new `ios/QualityAdvisor.swift`, `ios/StreamSender.swift`, `ios/CameraStreamer.swift`,
`ios/iPhoneCameraStream.xcodeproj/project.pbxproj` (R1), new `tests/quality_advisor_test.swift`,
`tests/architecture_boundary_contract.sh`, `tests/stream_sender_source_contract.sh`,
`.github/workflows/build.yml`, `scripts/check.sh`.

**Steps:**
1. Create `ios/QualityAdvisor.swift`. It imports **Foundation only**. Add it to the Xcode project (R1).
   ```swift
   struct LinkWindow {             // one 2-second window
       var drops: UInt64           // frames dropped by the sender in this window
       var maxQueueMs: Double      // window max of onQueueLatency
       var rttMs: Double
       var rttVarMs: Double
       var retransmitRatio: Double // retransmitted bytes / sent bytes, 0 if nothing sent
       var thermal: ProcessInfo.ThermalState
   }
   struct BitrateController {
       private(set) var goodWindows = 0
       /// Returns the next average bit rate, clamped to [presetTarget / 2, presetTarget].
       mutating func nextBitrate(current: Int, presetTarget: Int, window: LinkWindow) -> Int
   }
   ```
   Rules for `nextBitrate`:
   - **Bad window:** `maxQueueMs > 50` or `drops > 0` or `retransmitRatio > 0.02`. Return
     `current × 0.8`, and reset `goodWindows` to 0.
   - **Good window:** otherwise. Increment `goodWindows`. When it reaches 5 (10 s), return
     `current × 1.1` and reset it to 0.
   - Always clamp to `[presetTarget / 2, presetTarget]`.
2. In `StreamSender`, add link reports:
   - Add `struct LinkStats { var rttMs: Double; var rttVarMs: Double; var retransmitRatio: Double }`
     and `var onLinkStats: ((LinkStats) -> Void)?`.
   - In `start()`, create one repeating `DispatchSourceTimer` on `queue` (interval 2 s) and keep
     it in a property. It is never recreated.
   - Each tick: if `connection` is nil or `!connectionReady`, set `pendingTransferReport = nil` and
     return. Otherwise:
     ```swift
     let previous = pendingTransferReport
     pendingTransferReport = conn.startDataTransferReport()
     previous?.collect(queue: queue) { [weak self] report in
         guard let self, let path = report.pathReports.first else { return }
         let sent = Double(path.sentTransportByteCount)
         self.onLinkStats?(LinkStats(rttMs: path.transportSmoothedRTT * 1000,
                                     rttVarMs: path.transportRTTVariance * 1000,
                                     retransmitRatio: sent > 0 ? Double(path.transportRetransmittedByteCount) / sent : 0))
     }
     ```
     Also store which connection the pending report belongs to, and drop it if that connection
     is no longer current.
   - In `stop()`, cancel the timer.
3. In `CameraStreamer`:
   - Keep `lastQueueMs` (from `onQueueLatency`) and `lastDropTotal` (from `onFrameRate`'s cumulative
     drops) on `sessionQueue`.
   - In `sender.onLinkStats`, hop to `sessionQueue`, then:
     1. Build a `LinkWindow`, with drops = the cumulative total minus the value at the last window.
     2. Call `bitrateController.nextBitrate(...)` with the preset target from T5.4's `currentBitRate()`.
     3. If the result changed, store it as the live target and apply it with T5.4's `applyLiveBitRate()`.
   - Change `currentBitRate()` to return the live target when one is set. Reset the live target to
     the full preset target on every `setPreset`, on transport change, and in `createEncoder`
     after a recovery.
   - Add a health line: `String(format: "BITRATE %.1f/%.0f Mbps", live / 1e6, target / 1e6)`.
4. Create `tests/quality_advisor_test.swift` (R3, `@main`, compiled with `ios/QualityAdvisor.swift`).
   Cases:
   - one bad window → 80%
   - repeated bad windows → floor at 50%
   - 5 good windows → +10%
   - never above 100%
   - a good window after a bad one resets the counter
5. Add `only_imports R-ARCH-4 ios/QualityAdvisor.swift Foundation` to
   `tests/architecture_boundary_contract.sh`, next to the `LengthPrefixedHEVC.swift` line.

**Contract changes:** the boundary contract line above, and in
`tests/stream_sender_source_contract.sh` add `grep -q 'startDataTransferReport' "$1"`.

**AC:**
- AC1 [CI] `quality_advisor_test` passes, and the IPA builds.
- AC2 [review] no per-frame work. The timer runs every 2 s.
- AC3 [device, DC-5b] on a weak Wi-Fi link, queue age drops back below 50 ms before any frame is dropped.
- AC4 [device] USB at rest stays at 100%.

**Stop and report if:** `startDataTransferReport`, `pathReports` or the `PathReport` property
names don't compile with the iOS 26 SDK.

---

### T5.7 Quality advisor and banner

| Branch | Model | Depends on | Gate | Est. |
|---|---|---|---|---|
| `feat/ios-quality-advisor` | S | T5.8 | — | 1 day |

**Files:** `ios/QualityAdvisor.swift`, `ios/CameraStreamer.swift`, `ios/CameraViewController.swift`,
`tests/quality_advisor_test.swift`.

**Steps:**
1. In `QualityAdvisor.swift`, add:
   ```swift
   enum Advice: Equatable { case down(toIndex: Int, reason: String), up(toIndex: Int, reason: String) }
   struct PresetAdvisor {
       /// presetIndex: index into the 60 fps presets, ordered 720p, 1080p, 4K. `now` is seconds (injected for tests).
       mutating func advice(presetIndex: Int, presetCount: Int, overWiFi: Bool,
                            bitrateAtFloor: Bool, bitrateAtFull: Bool,
                            window: LinkWindow, now: TimeInterval) -> Advice?
   }
   ```
   (Index-based, so this file needs no `StreamPreset`. `CameraStreamer` maps indexes to presets.)
   `ProcessInfo.ThermalState` is not `Comparable`: compare `rawValue`s, for example
   `window.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue`.
   - **Down** (only if `presetIndex > 0`) when the bitrate has been at the floor for 3 windows in a
     row, **or** thermal is `.serious` or worse, **or** there were drops in 2 of the last 5 windows.
   - **Up** (only if `presetIndex < presetCount − 1`) after 30 s in a row at full bitrate, with
     `maxQueueMs < 15` and thermal `.fair` or better.
   - At most one advice per 60 s. Each reason is short, for example
     `"Wi-Fi retransmits 4% at 4K60"` or `"Phone is hot"`.
2. `CameraStreamer` calls the advisor in the same `onLinkStats` path as T5.8 and publishes
   `var onAdvice: ((StreamPreset, String) -> Void)?` on main. It does this only for the three
   60 fps presets.
3. `CameraViewController` shows a banner:
   *"<preset> recommended — <reason>. [Switch] [Dismiss]"*. **Switch** calls
   `streamer.setPreset(preset)`. The app never switches resolution by itself.
4. Extend `tests/quality_advisor_test.swift`:
   - no second advice within 60 s
   - no up-advice while thermal is `.serious`
   - no advice for steady good windows
   - down after 3 floor windows
   - no down from index 0, no up from the top

**Contract changes:** none.

**AC:**
- AC1 [CI] the tests pass.
- AC2 [device, DC-5b] walking away from the router gives a down-advice within 10 s, and sitting still gives none.

---

### DC-5b Owner: Wi-Fi presets and timing

Needs T5.4, T5.5, T5.7 and T5.8 merged. For each preset over Wi-Fi, and 4K60 over USB as the
reference, stream 5 min and record in section 10:
- drops
- the min and max of `BITRATE`
- the receiver STAT `maxGapMs`, `extraDelayMs` and `maxExtraMs` (read the highest values)
- glass-to-glass (the T2.3 method)
- whether OBS followed the preset change by itself

**This decides G13:** approve it if any Wi-Fi preset shows `maxExtraMs` above 17 ms in most
STAT windows.

---

### T5.6 Constant-latency playout

| Branch | Model | Depends on | Gate | Est. |
|---|---|---|---|---|
| `feat/receiver-constant-latency` | O | T5.5, DC-5b | G13 | 1.5–2 days |

**Why:** Wi-Fi arrival jitter becomes variable video delay, so a fixed mic offset drifts. Holding
every frame to the same end-to-end delay fixes that.

**Files:** new `windows/relay_playout.h`, `windows/receiver.cpp`, new `tests/relay_playout_test.cpp`,
`tests/architecture_boundary_contract.sh` (R2), `tests/receiver_source_contract.sh`,
`.github/workflows/build.yml`, `scripts/check.sh`.

**Steps:**
1. Create `windows/relay_playout.h` (R2):
   ```cpp
   class RelayPlayout final {
   public:
       explicit RelayPlayout(uint64_t delayUs);
       void BeginSession();                 // forget the offset
       struct Slot { uint64_t releaseUs; bool late; };
       // phoneUs: header timestamp. arrivalUs: steady_clock µs at arrival.
       Slot OnFrame(uint64_t phoneUs, uint64_t arrivalUs);
       uint64_t LateFrames() const;
       void ResetWindow();                  // clears the late counter for the next STAT window
   };
   ```
   - The offset is the minimum of `arrival − phone` over the last 5–10 s. Keep two 5 s buckets
     (current and previous minimum), and rotate them when the current bucket is 5 s old. Use the
     lower of the two. This follows clock drift with O(1) work and no allocation.
   - `releaseUs = phone + offset + delayUs`. If `arrivalUs > releaseUs`, return
     `{arrivalUs, true}` and count it as late. Late frames are never dropped.
   - Use signed 64-bit math with the same clamp as `StreamTimingStats` (R-ENG-TIME).
2. Create `tests/relay_playout_test.cpp` (R3). Cases:
   - output spacing stays constant under synthetic ±40 ms jitter
   - ±200 ppm clock drift over 10 min is tracked
   - late frames pass through and are counted
   - `BeginSession` resets
   - timestamps that go backwards don't underflow
3. In `receiver.cpp`:
   - Add a CLI option `--latency-ms N` (0–250, reject others with the usage line). The default is 0
     for usbmux and 80 for `--host` (and later `--wifi`).
   - **If N = 0, keep today's direct path unchanged.** The relay output must be byte-identical.
   - If N > 0, `receive_session` starts one relay thread per session:
     - A fixed ring of `ceil(N / 16.7) + 8` slots, each `{AVPacket* pkt; uint64_t releaseUs; HevcAccessUnitInfo au;}`.
       Allocate the `AVPacket*`s once with `av_packet_alloc` at session start.
     - The receive thread hands over a frame with `av_packet_move_ref(slot.pkt, packet)` (no copy),
       under a `std::mutex`, then calls `notify_one` on a `std::condition_variable`.
     - The relay thread waits with `wait_until(releaseUs)` for the oldest slot. It calls
       `relay->Write(*slot.pkt, slot.releaseUs, slot.au)`, so the PTS comes from the PC clock in
       this mode, then `av_packet_unref(slot.pkt)`.
     - **Ring full** (only after a clock jump): the relay thread writes all queued frames at once,
       in order, then `BeginSession()` resets the offset, and the receiver prints **one** `WARN`.
       The receive thread may wait on the condition variable only in this case.
     - The relay counters (`relayWriteFailures`, `relayGateDrops`) become `std::atomic<uint64_t>`.
     - At session end, the remaining frames are written immediately, the thread is joined, and the
       packets are freed.
   - The STAT line gains `late=<n> holdMs=<N>`. If late frames exceed 1% of a window, print **one**
     line per window: `WARN: frames arriving late; lower the preset on the phone`.
4. Add `windows/relay_playout.h` to the boundary contract list (R2).

**Contract changes:** the boundary contract addition, and
`grep -q -- '--latency-ms' "$1"` in `tests/receiver_source_contract.sh`.

**AC:**
- AC1 [CI] unit test: the release-time spread is ≤ 2 ms under ±40 ms jitter.
- AC2 [CI, needs G1] with N = 0, the e2e output is identical to `main`. Without G1, report it as open.
- AC3 [review] no per-frame allocation or logging, and the queue is bounded.
- AC4 [device, DC-6] over 30 min on Wi-Fi, glass-to-glass stays within ±10 ms.

**Stop and report if:** the relay class can't be called from a second thread without changes to
its recovery logic. Report it rather than adding locks inside `ObsUdpRelay`.

---

### T5.9 Cinematic mode

| Branch | Model | Depends on | Gate | Est. |
|---|---|---|---|---|
| `feat/ios-cinematic-mode` | O | T5.4, DC-4 | G11 (APPROVED) | 1.5 days |

**Precondition:** DC-4 shows `cinematic=y` on a rear `builtInDualWideCamera` 1920x1080 or
3840x2160 line. If not, set the task to `SKIPPED` with the DC-4 evidence.

**Files:** `ios/CameraStreamer.swift`, `ios/CameraViewController.swift`, contracts listed below.

**Steps:**
1. Take the exact API names from the T5.1 SDK output. Expected names (WWDC25 session 319):
   - `AVCaptureDevice.Format.isCinematicVideoCaptureSupported`
   - `AVCaptureDeviceInput.isCinematicVideoCaptureEnabled`
   - `AVCaptureDeviceInput.simulatedAperture`, with the format's min/max/default aperture
   - `AVCaptureMetadataOutput.requiredMetadataObjectTypesForCinematicVideoCapture`
   - `AVCaptureDevice.setCinematicVideoFixedFocus(at:focusMode:)`
   - `AVCaptureDevice.setCinematicVideoTrackingFocus(detectedObjectID:focusMode:)`
   - `AVCaptureDevice.cinematicVideoCaptureSceneMonitoringStatuses`
   Where the SDK differs, use the SDK name and note it in your report.
2. Extend `StreamPreset` with `case cinematic1080 = "Cinematic 1080p30"` and
   `case cinematic2160 = "Cinematic 4K30"`:
   - `frameRate` → 30.
   - `title` → "Cine 1080" / "Cine 4K".
   - `bitRates` → the same as `.p1080` / `.p2160` (G8′).
   - Add `var isCinematic: Bool`.
   - The availability check (T5.4 step 8) includes a cinematic case only on iOS 26+ and only when
     a Dual Wide format reports support. The advisor (T5.7) ignores these presets.
3. In `setPreset`, when entering or leaving a Cinematic preset, inside one `beginConfiguration`/`commitConfiguration`:
   1. Call `switchCamera(to:)` (R5): `.builtInDualWideCamera` (back) when entering, `.builtInWideAngleCamera` (back) when leaving.
   2. Then `applyFormat`. For Cinematic, the filter also requires `isCinematicVideoCaptureSupported`.
   3. Then set `input.isCinematicVideoCaptureEnabled = true`, or false when leaving.
   4. Add an `AVCaptureMetadataOutput` with
      `metadataObjectTypes = requiredMetadataObjectTypesForCinematicVideoCapture` (remove it when
      leaving).
   Then the same tail as T5.4: `invalidateEncoder`, `resetForDiscontinuity`, telemetry.
4. UI, shown only in a Cinematic preset:
   - an aperture `UISlider` clamped to the format's min and max
   - tap on the preview → fixed focus at the converted point
   - tap on a detected face → tracking focus
   - an "Not enough light for Cinematic" note when the scene-monitoring status says so
   All of these go through `CameraStreamer` methods (R-ARCH-3).
5. Nothing changes on the receiver: it is PTS-driven, and T5.5 follows the size.

**Contract changes:** `tests/encoder_setup_source_contract.sh` add
`grep -q 'isCinematicVideoCaptureEnabled' "$source"` (`# T5.9`). The T5.4 assertions stay unchanged.

**AC:**
- AC1 [CI] the IPA builds.
- AC2 [review] 60 fps presets are unchanged, and entering or leaving Cinematic never calls `restartListening`.
- AC3 [device] the bokeh is visible in OBS, and the health line reads `VERIFIED Cinematic 1080p30`.
- AC4 [device] entering and leaving 5 times gives 0 reconnects.

---

### T5.10 Portrait effect

| Branch | Model | Depends on | Gate | Est. |
|---|---|---|---|---|
| `feat/ios-portrait-effect` | S | T5.4, DC-4 | G12 (APPROVED, Portrait only) | 1 day |

**Precondition:** DC-4 shows `portrait=y` on a 1920x1080 line of a rear **or** front camera. If
neither has it, set the task to `SKIPPED` with the DC-4 evidence. Don't build a custom blur.

**Files:** `ios/Info.plist`, `ios/CameraStreamer.swift`, `ios/CameraViewController.swift`,
`.github/workflows/build.yml`, `tests/camera_feedback_source_contract.sh`.

**Steps:**
1. `ios/Info.plist`: add `<key>NSCameraPortraitEffectEnabled</key><true/>`. Confirm the key's
   exact spelling in the T5.1 SDK output; use the SDK spelling if it differs.
2. Extend `StreamPreset` with `case portrait1080 = "Portrait 1080p"`:
   - `frameRate` → 30.
   - `title` → "Portrait".
   - `bitRates` → the same as `.p1080`.
   - Add `var isPortrait: Bool`.
3. Camera choice, decided once in `configureSession` and kept in a property:
   - The rear `.builtInWideAngleCamera`, if it has a 1920x1080 420v format with `isPortraitEffectSupported`.
   - Otherwise the front `.builtInTrueDepthCamera` with such a format. The segment title becomes
     "Portrait (front)".
   - Otherwise the preset is unavailable (T5.4 step 8 disables it).
4. In `setPreset`, when entering or leaving Portrait, use `switchCamera(to:)` (R5) and
   `applyFormat`. For Portrait, the format filter requires `isPortraitEffectSupported`, and the
   frame rate is `min(30, videoFrameRateRangeForPortraitEffect.maxFrameRate)`.
   - On the front camera, set `connection.automaticallyAdjustsVideoMirroring = false` and then
     `connection.isVideoMirrored = false` on the video output connection, so OBS sees the true
     image. Orientation uses the same `videoRotationAngle` code.
   - Then the same tail as T5.4.
5. Add a **Portrait** button, enabled only in this preset, that calls
   `AVCaptureDevice.showSystemUserInterface(.videoEffects)`. The user turns the effect on there;
   apps can't turn it on themselves.
6. Observe `isPortraitEffectActive` on the active device with KVO. While it is true, the health
   line shows `EFFECT Portrait • <fps> fps` (fps from `activeVideoMinFrameDuration`). The
   encoder's `ExpectedFrameRate` follows that fps, set live with `VTSessionSetProperty`
   (non-fatal).

**Contract changes:**
- `.github/workflows/build.yml`: in the step that runs
  `plutil -extract NSLocalNetworkUsageDescription raw "$GITHUB_WORKSPACE/ios/Info.plist"`, add the
  same line for `NSCameraPortraitEffectEnabled`. No local contract reads `Info.plist`, so CI is
  the check.
- `tests/camera_feedback_source_contract.sh`: add
  `grep -q 'showSystemUserInterface(.videoEffects)' "$streamer"` with a `# T5.10` comment line.
- The T5.4 assertions stay unchanged.

**AC:**
- AC1 [CI] the IPA builds.
- AC2 [review] never 4K: the preset is fixed at 1920x1080.
- AC3 [review] entering or leaving never calls `restartListening`.
- AC4 [device] with the effect on, OBS shows the blurred background, and the health line shows the real fps.
- AC5 [device] 0 reconnects over 5 enter/leave cycles, and the 60 fps presets are unchanged.

---

### T3.3 Bonjour discovery (amended)

Do T3.3 as written in the parent plan (write the mini-plan first). Additions:
- `Info.plist`: `NSBonjourServices` = `["_ipcamstream._tcp"]`.
- Advertise only while Wi-Fi mode is on.
- `receiver.exe --wifi` picks the first service found, unless `--host` is also given.
- With `--wifi`, the `--latency-ms` default is 80, as for `--host` (if T5.6 is merged).

---

### T5.11 Docs

| Branch | Model | Depends on | Gate | Est. |
|---|---|---|---|---|
| `docs/wifi-presets-effects` | H | T5.0–T5.10, T3.3 (merged or SKIPPED) | — | 3 h |

**Files:** `docs/QUICKSTART.md`, `docs/LATENCY.md`, `OBS-SETUP.md` (repo root), `CLAUDE.md`,
`docs/ENGINEERING_RULES.md`.

**Steps:**
- QUICKSTART:
  - Wi-Fi setup: 5 or 6 GHz; the PC on Ethernet to the same router is best; Personal Hotspot is an alternative.
  - Choosing a preset: for Twitch or YouTube at 1080p60, a 1080p60 source is enough. 4K helps only for cropping, zooming or 4K uploads.
  - Cinematic and Portrait run at 30 fps.
- LATENCY: a per-mode latency and mic-offset table, filled from the DC-5b and DC-6 numbers in parent section 10.
- OBS setup: put the Media Source in a **bounding-box transform** so a preset change doesn't move the scene; also the re-activate fallback from T5.5 if DC-5b needed it.
- CLAUDE.md module map: add the three new pure units. ENGINEERING_RULES: record G7, G11, G12 and G13.

**AC:** [review] every number in the docs comes from section 10 of the parent plan.

---

### DC-6 Owner: final pass

- 30 min of Wi-Fi at the advised preset: 0 unexpected reconnects; glass-to-glass at 30 min
  within ±10 ms of the value at 0 min.
- USB 4K60: no regression against the soak criteria in the parent plan.
- Cinematic and Portrait (if built): enter and leave 5 times each, with 0 reconnects.

---

## 6. Sources for the platform facts used above

- Apple, WWDC25 session 319, "Capture cinematic video in your app": bokeh baked into video data output frames; 1080p and 4K at 30 fps; Dual Wide or TrueDepth. https://developer.apple.com/videos/play/wwdc2025/319/
- Apple docs: `isPortraitEffectEnabled` iOS 15.0+, `isStudioLightEnabled` iOS 16.0+, `isBackgroundReplacementEnabled` and `videoFrameRateRangeForBackgroundReplacement` iOS 18.0+, `isCenterStageEnabled` iOS 14.5+ (read 2026-11-25).
- Apple Developer Forums 805786, Apple Media Engineer: video effects are a user decision and "only support video smaller than 1920 x 1440". https://developer.apple.com/forums/thread/805786
- Apple, iPhone models compatible with iOS 26 (includes iPhone 14 Pro). https://support.apple.com/guide/iphone/iphone-models-compatible-with-ios-26-iphe3fa5df43/26/ios/26
- Apple, iPhone 14 Pro technical specifications (Cinematic mode up to 4K HDR at 30 fps). https://support.apple.com/en-us/111849
- Apple, WWDC21 session 10047, "What's new in camera capture": Portrait effect opt-in, user-controlled. https://developer.apple.com/videos/play/wwdc2021/10047/
- SPS test vectors in T5.5: generated locally on 2026-11-25 with FFmpeg + libx265 and checked with an independent bit-level parser.
