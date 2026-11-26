# Execution Plan: stable USB, lower and stable latency, Wi-Fi, real tests

| | |
|---|---|
| Status | ACTIVE |
| Created | 2026-11-25 |
| Baseline | commit `f657cdd` plus the uncommitted AI-tooling files (see T0.0) |
| Owner | repo owner (human). Approves gates, merges branches, runs device checks |
| Executors | AI agents (Haiku/Sonnet class). One task per session, one branch per task |

This file is the single source of truth for this body of work. It lives on `main`
and travels with every task branch. Executors update only the **Status tracker**
(section 9) and the **Device test log** (section 10). Only the owner changes the
other sections.

---

## 0. Rules for the executing agent (read first, every time)

1. You execute **exactly one task** (a `T` number) per session. Read `CLAUDE.md`,
   then this section, section 2, and **your task section only**. Do not read or do
   other tasks. Phase 5 tasks (T5.x) and the amendments to T3.1 and T3.3 are in
   [`STREAMER_FEATURES_PLAN.md`](STREAMER_FEATURES_PLAN.md): read its section 0 and
   your task there as well.
2. Open section 9. Every task in your task's **Depends on** list must be `DONE`
   (merged to `main`); `SKIPPED` also counts as satisfied. If your task has a **Gate**, that gate must be `APPROVED`
   in section 4. If either is not true, **stop** and tell the user which one.
3. Create your branch from the latest `main`:
   `git checkout main` then `git checkout -b <branch named in the task>`.
   If the working tree is dirty, stop and ask.
4. Follow the CLAUDE.md **Mandatory workflow**. The task's **Acceptance criteria**
   are your acceptance-criteria output. You may add criteria. Never drop one.
5. Do **only** the task's Steps. If a step can't be done as written (an identifier
   doesn't exist, an API behaves differently, a contract fails that the task didn't
   list), **stop and report**. Don't invent a different design.
6. Change only the contract assertions the task lists under **Contract changes**.
   If any other contract fails, your code is wrong. Fix the code, not the test
   (R-ENG-TEST).
7. Validate with `sh scripts/check.sh`: 0 FAIL. List every SKIP. Tests that run
   only in CI (Swift, `xcodebuild`, the receiver link, Windows e2e) are
   **unverified** until CI is green. Say so.
8. As the last change on your branch, update your row in section 9:
   Status `DONE-PENDING-MERGE`, the date, and a short note. If you were blocked,
   use `BLOCKED` and give the reason.
9. Commit on your task branch only. Use the message `T<id>: <summary>` and end it
   with the attribution line from your harness. **Never push, merge, rebase
   `main`, or force anything** unless the user says so in this session.
10. Finish with the report format from the `implement-change` skill.
11. Merge only after CI is green on the branch. The workflow does not run on
    branch pushes, so trigger it: `gh workflow run build.yml --ref <branch>`, wait
    for success, then merge with `--no-ff` and confirm the `main` run is green.
    Local `check.sh` SKIPs (C++, Swift, link, xcodebuild) are unverified until then.

Line numbers in this plan refer to commit `f657cdd`, and they drift. Always
`grep` for the quoted code. Don't trust a line number alone.

---

## 1. Review results

### 1.1 Architecture verdict

**The overall shape is right; the lifecycle and timing details are not.**

What is correct and should be kept:
- The video stays compressed end to end. The phone encodes HEVC, `receiver.exe`
  only re-muxes it to MPEG-TS, and OBS does the hardware decode. There's no PC
  decode or copy on the hot path. For 4K60, this is the right design.
- There is one wire format, owned by `protocol/stream_protocol.h` with a Swift
  mirror and parity checks.
- Pure logic lives in small units with runtime tests (`relay_recovery.h`,
  `relay_timestamp.h`, `hevc_access_unit.h`, `LengthPrefixedHEVC.swift`).
- Join-point gating (VPS+SPS+PPS+IDR) runs on both sides, the receiver never
  exits, and headers are validated before any allocation.

What is wrong (details in 1.2):
1. **Media recovery and transport are coupled.** Every camera or encoder recovery,
   and every time the app becomes active again, *tears down the PC connection*. A
   media discontinuity only needs a keyframe gate. It doesn't need a new socket.
2. **The send path has no "drop means wait for IDR" rule.** A queue overflow drops
   one frame and keeps sending the deltas that depend on it, so the picture breaks
   until the next scheduled IDR (up to 2 s).
3. **Timing is never measured.** No stage reports its latency, so the A/V delay
   can't be tuned or held stable.
4. **The tests can't catch any of this.** Most checks are grep contracts (D6).
   There are no socket-level or end-to-end tests, and locally 9 of 24 checks are
   SKIPped.
5. **Transport choice is hard-wired to USB.** The receiver refuses any host that
   isn't on the Apple USB adapter or loopback. The phone, meanwhile, already
   listens on *every* interface, including Wi-Fi, without authentication (D4).

This is a personal app, so the plan fixes these with small, local changes. It adds
no new frameworks, services, or runtime dependencies, and doesn't rewrite the big
files.

### 1.2 Findings

Severity: **H** = causes the reported symptoms or data corruption; **M** = real
defect or risk; **L** = minor.

| ID | Sev | Finding | Evidence (at `f657cdd`) | Fixed by |
|---|---|---|---|---|
| F1 | H | Camera recovery drops the PC connection. `recoverSession` calls `sender.restartListening(...)`, and it runs on **every** `didBecomeActive` and `InterruptionEnded`. Pulling down Control Center or Notification Center, Siri, the app switcher, and the **"Trust This Computer" alert shown when you plug into the PC** all make the app inactive and then active again, so each one causes a reconnect. It also fires once at launch | `ios/CameraStreamer.swift:110-114`, `:125-129`, `:1097-1104`, `:1218` | T1.3, T1.5 |
| F2 | H | Rebinding the listener likely fails with "address in use". `restartListening` cancels the live connection, which is a server-side close and leaves port 12345 in TIME_WAIT (about 30 s on Darwin). It then immediately creates a new `NWListener` with `NWParameters.tcp`, which doesn't set `allowLocalEndpointReuse`. A failed listener retries after 1, 2, 4, 8, then 16 s, so **USB video can be gone for about 30 s**, which looks like "it halts until I reconnect manually". Likely, not proven: T1.2 adds a test that proves or disproves it | `ios/StreamSender.swift:80-86`, `:113-116`, `:213` | T1.2 |
| F3 | H | The path monitor restarts the USB listener on any global network change. Its signature includes `path.status`, which reflects Wi-Fi and cellular, so a Wi-Fi or cellular blip drops a healthy USB/usbmux stream. The listener uses the wildcard address and doesn't need a rebind | `ios/StreamSender.swift:90-108` | T1.4 |
| F4 | H | A queue overflow corrupts video for up to 2 s. When 8 packets are queued, the next frame is dropped, but later delta frames are still sent, and they reference the missing frame. OBS shows a frozen or garbled image until the next IDR (`MaxKeyFrameInterval` 120 = 2 s at 60 fps). This matches "again after one or two seconds" | `ios/StreamSender.swift:242-245`; `ios/CameraStreamer.swift:379` | T1.6 |
| F5 | H | Clicking the receiver console pauses the receiver. With Windows QuickEdit, a click selects text, and Windows then blocks the process's next console write. The receiver prints a STAT line every 120 frames (every 2 s), so the receive loop stops, OBS freezes, and the phone queue overflows until someone presses Esc or Enter | `windows/receiver.cpp:631-647` (printf on the receive thread) | T1.9 |
| F6 | M | There's a fixed 1 s pause after every session end, even when the phone is ready to reconnect at once | `windows/receiver.cpp:674` | T1.8 |
| F7 | M | The OBS playout timeline comes from the **phone clock**. OBS paces Media Source frames by PTS deltas. Phone/PC clock skew, and any startup or probe backlog, can turn into delay that never drains. This is unmeasured today | `windows/receiver.cpp:127`; `windows/relay_timestamp.h` | T2.1 (measure), T2.5 (gated fix) |
| F8 | M | Loopback UDP to OBS can lose packets in bursts. A 4K IDR (about 1–2 MB) goes out as roughly 1,000 back-to-back 1316-byte datagrams. If the OBS socket buffer is too small, packets are lost and the picture breaks until the next IDR | `windows/receiver.cpp:55`, `:81-84` | T0.6 (measure), T2.3 (OBS setting), T2.6 (optional) |
| F9 | M | The encoder runs at 4K60/40 Mbps even when no PC is connected, which heats the phone. Thermal and system-pressure throttling then interrupt the camera during long sessions | `ios/CameraStreamer.swift:418-445` | T2.7 |
| F10 | M | Exposure (D4): the listener accepts on every interface, including Wi-Fi, without authentication, and the newest connection replaces the current one. Anyone on the same Wi-Fi can view the camera or kick off the PC | `ios/StreamSender.swift:113-116`, `:157-160` | T3.1 (USB-only by default) |
| F11 | L | D5: the sender allows frames up to `UInt32.max`, but the receiver drops the session above 16 MiB | `ios/StreamSender.swift:223` | T1.7 |
| F12 | L | The receiver takes the *first* usbmux USB device. With two Apple devices plugged in, it can pick the wrong one | `windows/receiver.cpp:374-379` | not planned (note only) |
| F13 | L | The relay always declares 3840x2160, even in portrait. OBS behavior after an orientation switch needs a device check | `windows/receiver.cpp:77-78` | DC-1 item 8 (observe only) |
| F14 | L | `relayDrop` counts intentional recovery-gate drops as write failures, so the STAT line is misleading | `windows/receiver.cpp:607-611` | T2.1 |
| F15 | L | Hot-path waste: `containsIDR` copies each access unit into `[UInt8]`, and `send()` builds a packet copy even with no PC connected | `ios/LengthPrefixedHEVC.swift:155`; `ios/StreamSender.swift:234-236` | T2.7 (partly) |
| F16 | L | Docs drift: QUICKSTART says the app "shows nothing (no UI by design)" and treats Personal Hotspot as required. usbmux through Apple Devices is the preferred path | `docs/QUICKSTART.md` | T1.10 |
| F17 | Info | No end-to-end or socket tests; only grep contracts (D6). Locally, C++ tests are SKIPped because there's no compiler, and Swift tests because there's no Xcode | `scripts/check.sh` output: 15 pass / 0 fail / 9 skip | T0.2–T0.7 |
| F18 | Info | CI runs only on pushes to `main`, so task branches never get Swift, iOS, or receiver-link verification | `.github/workflows/build.yml:8-11` | T0.1 |

### 1.3 What most likely explains the owner's symptoms

**"The connection gets interrupted, halts, I must reconnect, and it happens again
after one or two seconds."** These are the likely causes, in order. They can
happen together:
1. **F1 + F2**: any inactive-to-active transition, including the USB "Trust"
   alert, drops the connection. The listener rebind can then fail for up to about
   30 s.
2. **F5**: a click in the receiver window pauses the receiver within 2 s.
3. **F4**: a dropped frame corrupts video until the next IDR, at most 2 s later.
4. **F3**: Wi-Fi or cellular changes on the phone restart the USB listener.
5. Environment: Windows USB selective suspend, hubs, or a poor cable (T1.10 adds
   these to troubleshooting).

T1.1 adds an on-screen "last disconnect reason" so DC-1 can confirm which cause
the owner actually hits.

**"My separate mic is ahead of the video."** A 4K60 HEVC path can never have zero
delay. Capture, encode, transfer, and OBS decode take time. The goal is to make
video latency **small and stable**, then delay the mic by that amount in OBS
(**Advanced Audio Properties → Sync Offset**). A fixed offset only works if the
latency doesn't grow during a session. F7 (phone-clock playout, startup backlog)
and F4/F8 (stalls and bursts) can make it grow. Phase 2 measures first, then fixes
what the measurements show.

---

## 2. Global rules for this plan

- **Wire format is frozen.** No task changes the 21-byte header, magic, codecs, or
  port 12345. Wi-Fi uses the same protocol.
- **No new runtime dependencies.** Test tooling uses only the Python 3 standard
  library plus the `ffmpeg`/`ffprobe` command-line tools (gate G1). Docker is local
  build tooling (gate G2).
- **Every CLAUDE.md invariant holds**: join-point gating on both sides, the
  receiver never exits, untrusted input is validated first, no per-frame logging
  or disk I/O, and bounded queues only.
- **Keep it small.** About 200 changed product lines per task at most, tests
  excluded. If a task grows past that, stop and report.
- **Concurrency (iOS):** `StreamSender` state is confined to its `queue`.
  `CameraStreamer` state stays on `sessionQueue` or behind its existing locks.
  Callbacks capture `[weak self]` (R-ENG-CONC).
- **Contracts:** when a task intentionally changes a behavior that a contract
  pins, the task lists the exact assertion edit. Update it in the same commit and
  add a comment line in the contract that explains why.

---

## 3. Target architecture (after this plan)

```
iPhone                                                    Windows
Capture ─► HEVC encoder ─► StreamSender ════ TCP :12345 ════► receiver.exe ─► relay ─► OBS
            ▲   (forced IDR)     │  (one wire protocol)          │                (loopback only)
            └── onKeyFrameNeeded ┘  transports:                  │  --host <ip> = direct TCP (Wi-Fi / tests)
                                    • usbmux (primary)           │  default    = usbmux → USB hotspot
                                    • USB hotspot (fallback)     │  STAT: arrival jitter / extra delay / skew
                                    • Wi-Fi (opt-in switch)      │
```

Principles the tasks implement:
- **P1. A media discontinuity is not a transport reset.** Camera or encoder
  recovery calls `sender.resetForDiscontinuity`: clear the queue, wait for an IDR,
  and keep the socket. Only transport failures close the socket.
- **P2. Every drop closes the GOP.** Any dropped frame re-arms the keyframe gate
  and asks the encoder for an IDR.
- **P3. One protocol, several transports.** The receiver chooses the transport.
  The phone listens on USB by default, and on Wi-Fi only when the owner turns it on.
- **P4. Measure, then tune.** Each stage reports its latency, and latency must
  stay stable so a fixed OBS audio offset stays correct.
- **P5. Test pyramid.** Pure unit tests, then socket tests (`StreamSender` on
  macOS CI, receiver end-to-end with a fake phone on Windows), then a manual
  device checklist (section 7).

---

## 4. Decisions for the owner (gates)

Set each **Status** to `APPROVED` or `REJECTED`. Tasks with a gate don't start
while it is `PENDING`.

| Gate | Decision | Recommendation | Blocks | Status |
|---|---|---|---|---|
| G1 | Allow test-only tooling: Python 3 (stdlib only) plus the `ffmpeg`/`ffprobe` CLIs, locally and in CI | Approve. It's the only practical way to get end-to-end tests without an iPhone | T0.5, T0.6 | APPROVED (2026-11-26) |
| G2 | Add Docker for local checks (and optionally a receiver cross-build). Needs Docker Desktop with WSL2 on this PC | Approve for checks. The cross-build (T0.8) is optional | T0.2, T0.8 | PENDING |
| G3 | Keyframe interval 2 s → 1 s (`MaxKeyFrameInterval` 120 → 60) | Approve. Halves the worst-case recovery and OBS join time for a small quality cost | T2.4 | APPROVED (2026-11-26) |
| G4 | Pause HEVC encoding while no PC is connected (preview stays live) | Approve. Less heat, fewer thermal interruptions | T2.7 | APPROVED (2026-11-26) |
| G5 | Relay PTS taken from PC arrival time instead of the phone clock | Approve **only if** DC-2 shows delay growing over a session | T2.5 | APPROVED (2026-11-26) |
| G6 | Relay to OBS over loopback TCP instead of UDP (lossless, joins OBS at an IDR) | Decide after DC-2/T0.6 data. Biggest change in the plan | T2.6 | PENDING |
| G7 | Wi-Fi exposure model. **A:** opt-in switch, off by default; when off, the phone refuses Wi-Fi and cellular connections; no authentication. **B:** A plus a pairing PIN (needs a protocol change, D3) | **A** now; B later if ever needed | T3.1, T3.3 | APPROVED (2026-11-26, option A) |
| G8 | Wi-Fi bitrate 25 Mbps (USB stays 40 Mbps) | Superseded by G8′ ([STREAMER_FEATURES_PLAN.md](STREAMER_FEATURES_PLAN.md) section 4) | T3.2 | SUPERSEDED |
| G9 | Retire `--gpu-ring` diagnostics (removes the D3D11 decode path, D1, and D10) | Approve (optional cleanup) | T4.1 | PENDING |
| G8′ | Per-preset bitrates for 720p60 / 1080p60 / 2160p60, USB and Wi-Fi (table in STREAMER_FEATURES_PLAN.md §4) | Approve | T5.4 | APPROVED (2026-11-26) |
| G10 | 1440p60 preset scaled from 4K | Reject for now | — | PENDING |
| G11 | Cinematic as an explicit **30 fps** exception (Apple limit: 1080p/4K at 30 fps) | Owner approved (iPhone 14 Pro) | T5.9 | APPROVED (2026-11-25) |
| G12 | **Portrait** effect only, at the format's capped fps; rear camera, or front-camera fallback; never 4K | Owner approved, conditional on DC-4 showing support | T5.10 | APPROVED (2026-11-25) |
| G13 | Fixed-latency playout in the receiver (USB 0 ms, Wi-Fi 80 ms default, `--latency-ms`) | Approve if DC-5b Wi-Fi jitter p99 > 17 ms | T5.6 | PENDING |
| G14 | Automatic bitrate adaptation within a preset (floor 50%); resolution never auto-switched | Approve | T5.8 | APPROVED (2026-11-26) |

---

## 5. Phases and branch map

Execute in this order. Each line is one branch. Merge it to `main` before you
start any task that depends on it.

```
Phase 0  Foundation (CI, local builds, tests)
  T0.0 owner: commit baseline ─┬─ T0.1 ci/run-on-pull-requests
                               ├─ T0.2 chore/docker-check-gate          [G2]
                               ├─ T0.3 chore/msys2-local-build
                               ├─ T0.4 feat/receiver-host-flag
                               │     └─ T0.5 test/receiver-e2e-harness  [G1] (needs T0.3, T0.4)
                               │           └─ T0.6 test/receiver-e2e-faults [G1]
                               ├─ T0.7 test/ios-sender-socket-test
                               └─ T0.8 chore/docker-receiver-cross-build [G2, optional]
Phase 1  Stop the disconnects and halts
  T1.1 diag/ios-disconnect-reasons
  T1.2 fix/ios-listener-reuse           (needs T0.7)
  T1.3 fix/ios-recovery-keeps-connection (needs T1.2)
  T1.4 fix/ios-path-monitor-guard        (needs T1.2)
  T1.5 fix/ios-light-foreground-resume   (needs T1.3)
  T1.6 fix/ios-drop-to-keyframe          (needs T1.3)
  T1.7 fix/ios-max-frame-guard           (needs T1.6)
  T1.8 fix/receiver-fast-reconnect       (needs T0.6)
  T1.9 fix/receiver-console-quickedit
  T1.10 docs/usb-troubleshooting
  ── DC-1 device checkpoint (owner) ──
Phase 2  Latency: measure, then fix
  T2.1 diag/receiver-timing-stats
  T2.2 diag/ios-latency-telemetry
  T2.3 docs/obs-latency-and-av-sync
  ── DC-2 latency baseline (owner) → decide G3, G5, G6 ──
  T2.4 perf/ios-encoder-latency          [G3]
  T2.5 fix/relay-arrival-timeline        [G5] (needs T2.1, T0.6)
  T2.6 feat/relay-tcp-output             [G6, optional, write a mini-plan first]
  T2.7 perf/ios-idle-encoder-pause       [G4]
Phase 3  Wi-Fi
  T3.1 feat/ios-wifi-mode                [G7] (needs T1.4, T0.4)
  T3.2 feat/ios-wifi-bitrate             [G8] (needs T3.1)
  T3.3 feat/wifi-discovery               [G7, optional, write a mini-plan first]
  ── DC-3 Wi-Fi checkpoint (owner) ──
Phase 4  Cleanup and sign-off
  T4.1 chore/retire-gpu-ring             [G9, optional]
  T4.2 docs/soak-signoff                 (after the soak test)
Phase 5  Streamer features (task details: STREAMER_FEATURES_PLAN.md; T3.2 superseded)
  T5.0 diag/ios-nwerror-detail
  T5.1 ci/xcode-26-sdk
  T5.2 diag/ios-capability-probe         (needs T5.1)
  T5.5 feat/receiver-resolution-follow   (no deps; can start any time)
  ── DC-4 capability report (owner) → decide G10, G11, G12 ──
  ── DC-5a USB vs Wi-Fi A/B (owner; needs T5.0, T3.1) ──
  T5.4 feat/ios-quality-presets          [G8′] (needs T3.1, T5.5)
  T5.8 feat/ios-adaptive-bitrate         [G14] (needs T5.4)
  T5.7 feat/ios-quality-advisor          (needs T5.8)
  ── DC-5b Wi-Fi presets and timing (owner) → decide G13 ──
  T5.6 feat/receiver-constant-latency    [G13] (needs T5.5)
  T5.9 feat/ios-cinematic-mode           [G11] (needs T5.4)
  T5.10 feat/ios-portrait-effect         [G12] (needs T5.4)
  T5.11 docs/wifi-presets-effects        (after T5.0–T5.10 and T3.3, each DONE or SKIPPED)
  ── DC-6 final pass (owner) ──
```

Model tier per task: **H** = Haiku is fine; **S** = use Sonnet; **O** = use Opus
or a careful Sonnet.

---

## 6. Tasks

Each task lists: Branch · Model · Depends on · Gate · Why · Steps · Contract
changes · Tests · Docs · Acceptance criteria (AC).

### T0.0 Commit the baseline (owner, or an agent with explicit permission)

`main` has uncommitted files (`CLAUDE.md`, `AGENTS.md`, `.claude/`,
`docs/ENGINEERING_RULES.md`, `scripts/check.sh`, new contracts, and this plan).
Branches copy only committed files, so commit them first, on `main`:
1. `sh scripts/check.sh` → expect `15 passed, 0 failed, 9 skipped`.
2. `git add -A && git commit -m "Add agent tooling, engineering rules, and execution plan"`.
3. In section 9, set T0.0 to `DONE`.

### T0.1 CI runs on pull requests · `ci/run-on-pull-requests` · H · deps T0.0

**Why:** F18. Task branches currently get no CI verification.
**Steps:**
1. In `.github/workflows/build.yml`, under `on:`, keep `push: branches: [main]`
   and `workflow_dispatch:`, and add `pull_request:` with no filters.
2. Add a top-level block after `on:`:
   ```yaml
   concurrency:
     group: ${{ github.workflow }}-${{ github.ref }}
     cancel-in-progress: true
   ```
3. Add one line to `README.md` under the contributors note: "CI runs on every
   pull request. To test a branch without a PR, use Actions → Run workflow and
   pick the branch."

**Contract changes:** none. **Tests:** `sh tests/windows_ci_contract.sh .github/workflows/build.yml` passes.
**AC:** AC1: the workflow triggers on `pull_request`. AC2: check.sh shows 0 FAIL.
AC3: existing jobs are unchanged (review the diff).

### T0.2 Docker check gate · `chore/docker-check-gate` · H · deps T0.0 · Gate G2

**Why:** F17. Locally there's no C++ compiler, so 4 runtime tests SKIP. Docker
gives a reproducible Linux gate. iOS can't be built in Docker, because it needs
macOS. Say that in the docs.
**Steps:**
1. Create `docker/check.Dockerfile`:
   ```dockerfile
   FROM ubuntu:24.04
   RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       g++ make python3 ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*
   COPY docker/run_check_in_container.sh /usr/local/bin/run-check
   RUN sed -i 's/\r$//' /usr/local/bin/run-check && chmod +x /usr/local/bin/run-check
   WORKDIR /work
   ENTRYPOINT ["/usr/local/bin/run-check"]
   ```
2. Create `docker/run_check_in_container.sh`. It copies the read-only mount and
   converts CRLF to LF, because Windows checkouts are CRLF (`core.autocrlf=true`)
   and Linux `sh` and `awk` break on `\r`:
   ```sh
   #!/usr/bin/env sh
   set -eu
   rm -rf /work/repo && mkdir -p /work/repo
   cp -a /src/. /work/repo/
   cd /work/repo
   find . -path ./.git -prune -o -type f \( -name '*.sh' -o -name '*.swift' -o -name '*.cpp' \
     -o -name '*.h' -o -name '*.yml' -o -name '*.md' -o -name '*.plist' -o -name '*.pbxproj' \
     -o -name '*.py' -o -name '*.json' -o -name '*.txt' \) -exec sed -i 's/\r$//' {} +
   exec sh scripts/check.sh
   ```
3. Create `scripts/docker_check.sh`:
   ```sh
   #!/usr/bin/env sh
   # Runs scripts/check.sh inside Linux (adds the C++ runtime tests).
   set -eu
   cd "$(dirname "$0")/.."
   docker build -f docker/check.Dockerfile -t ipcam-check .
   src=$(pwd -W 2>/dev/null || pwd)   # Git Bash gives a Windows path with -W
   MSYS_NO_PATHCONV=1 docker run --rm -v "$src:/src:ro" ipcam-check
   ```
4. Create `.dockerignore` so the build context is tiny:
   ```
   *
   !docker/
   ```
5. Docs: in `docs/QUICKSTART.md`, add a short section "Local checks with Docker":
   install Docker Desktop (WSL2), run `sh scripts/docker_check.sh`, and note that
   Swift, iOS, and the receiver link still run only in CI. In `CLAUDE.md` under
   **Commands**, add `sh scripts/docker_check.sh  # same gate in Linux; runs the C++ tests`.

**Contract changes:** none. `docker/` isn't under `tests/`, so the registry is
unaffected.
**AC:** AC1: `sh scripts/docker_check.sh` runs check.sh in the container and the 4
C++ tests PASS. If Docker isn't installed, report UNVERIFIED and the owner runs it.
AC2: host `sh scripts/check.sh` still shows 0 FAIL.

### T0.3 Native MSYS2 build like CI · `chore/msys2-local-build` · H · deps T0.0

**Why:** The receiver can only be built in CI today, and `scripts/build_windows.sh`
uses placeholder paths (D7). The e2e tests need a local `receiver.exe`.
**Steps:**
1. Create `scripts/build_receiver_msys2.sh`. It must:
   - exit with a message unless `"$MSYSTEM" = UCRT64`;
   - `cd` to the repo root and `mkdir -p build/windows-binaries`;
   - compile and run the 4 C++ tests with the **exact** `g++` lines from
     `build.yml`, outputting to `build/`;
   - build `receiver.exe` with the **exact** `g++ … receiver.cpp gpu_frame_publisher.cpp …`
     line from `build.yml` (same flags and libraries), outputting to
     `build/windows-binaries/receiver.exe`;
   - copy DLLs the same way CI does:
     `ldd … | awk '/\/mingw64\/bin\// { print $3 }' | sort -u | xargs -r -I{} cp "{}" build/windows-binaries/`.
2. In `docs/QUICKSTART.md` Part B, add "Option 1 (recommended): build exactly like
   CI with MSYS2". Steps: install MSYS2 from msys2.org, open the **MSYS2 UCRT64**
   shell, run `pacman -S --needed mingw-w64-ucrt-x86_64-toolchain mingw-w64-ucrt-x86_64-ffmpeg
   mingw-w64-ucrt-x86_64-libusbmuxd mingw-w64-ucrt-x86_64-python mingw-w64-ucrt-x86_64-pkgconf git`,
   then `sh scripts/build_receiver_msys2.sh`. Label the existing Visual Studio and
   vcpkg steps "Option 2".
3. In `docs/ENGINEERING_RULES.md`, change D7's "Smallest correction" to "Use
   `scripts/build_receiver_msys2.sh` (mirrors CI)".

**Contract changes:** none.
**AC:** AC1: the script's compile lines match `build.yml` character for character,
except output paths (diff review). AC2: if MSYS2 isn't installed, report
UNVERIFIED and the owner runs it once.

### T0.4 Receiver `--host` (direct TCP) · `feat/receiver-host-flag` · S · deps T0.0

**Why:** The e2e tests and Wi-Fi need a direct TCP connection that skips usbmux
(which would grab a plugged-in iPhone during tests) and skips the Apple-adapter
bind. Today `connect_tcp` refuses any non-loopback host that isn't on the Apple
adapter (`receiver.cpp:307-313`).
**Behavior:**
- `receiver.exe --host <address>` connects straight to `<address>:12345` and
  never calls usbmuxd or binds to the Apple adapter. It retries forever like today.
- The positional host argument and `IPHONE_CAMERA_HOST` keep today's meaning: the
  USB-network fallback host.
- `--host` without a value prints the usage text and exits with code 2.

**Steps:**
1. `static SOCKET connect_tcp(const char* host)` becomes
   `static SOCKET connect_tcp(const char* host, bool requireUsbInterface)`.
   Change the bind condition to
   `if (requireUsbInterface && !loopbackForward && (item->ai_family != AF_INET || !bind_iphone_usb_interface(candidate, host)))`.
   Logging on success: when `requireUsbInterface` is true, keep the existing
   "connected to iPhone USB network" line. Otherwise print
   `INFO: connected to iPhone at %s:%u (direct TCP)`.
2. `static SOCKET connect_to_device(const char* usbNetworkHost)` becomes
   `static SOCKET connect_to_device(const char* host, bool directTcp)`. Its first
   statement:
   ```cpp
   if (directTcp) {
       const SOCKET direct = connect_tcp(host, false);
       if (direct == INVALID_SOCKET) {
           fprintf(stderr, "WARN: direct TCP connect to %s:%u failed\n", host, DEVICE_PORT);
       }
       return direct;
   }
   ```
   The existing fallback call becomes `connect_tcp(host, true)`.
3. `run_receiver(bool obsUdpRelay, const std::string& usbNetworkHost)` gains a
   `bool directTcp` parameter, and the call becomes
   `const SOCKET fd = connect_to_device(usbNetworkHost.c_str(), directTcp);`.
4. In `main()`, add a branch to the argument loop before the positional case:
   ```cpp
   } else if (std::strcmp(argv[index], "--host") == 0) {
       if (index + 1 >= argc) { /* print usage */ return 2; }
       directHost = argv[++index];
   ```
   If `directHost` is set, use it as the host with `directTcp = true` and print
   `INFO: iPhone Camera receiver started; direct TCP host=%s port=%u`. Update the
   usage text to
   `Usage: receiver.exe [--obs-udp|--gpu-ring] [--host <iPhone address>] [iPhone USB host]`.

**Contract changes** (`tests/receiver_source_contract.sh`, additions only):
`grep -q -- '--host' "$receiver"`, `grep -q 'requireUsbInterface' "$receiver"`,
`grep -q 'direct TCP' "$receiver"`. Confirm that these existing pins still match:
`static SOCKET connect_tcp`, `static SOCKET connect_to_device`, `loopbackForward`,
`const SOCKET fd = connect_to_device`, and `IPHONE_CAMERA_HOST`.
**Docs:** a QUICKSTART troubleshooting row: "Connect to a specific phone address
(Wi-Fi or tests): `receiver.exe --host <ip>`". In `docs/architecture.md`, a
**Receiver CLI** line.
**AC:** AC1: with `--host`, no `usbmuxd_*` call is reachable (code review). AC2:
without `--host`, behavior is byte-for-byte the same path as before (review).
AC3: a missing value exits 2. AC4: check.sh shows 0 FAIL. AC5: the CI receiver
link passes (CI must confirm).

### T0.5 Receiver end-to-end harness · `test/receiver-e2e-harness` · S · deps T0.3, T0.4 · Gate G1

**Why:** F17. This proves the real `receiver.exe` relays a real HEVC stream
correctly with no iPhone, and it's the base for the fault and latency tests.
**Files:** `tests/e2e/ipcam_e2e.py`, `tests/e2e/fixtures/testsrc_360p60_k60.h265`
(committed, under 1 MB), `tests/e2e/README.md`, `tests/receiver_e2e_test.sh`,
`tests/test_registry_contract.sh`, `scripts/check.sh`,
`.github/workflows/build.yml`, `docs/ENGINEERING_RULES.md`.
**Steps:**
1. **Fixture.** Generate it once and commit it. Put this exact command in
   `tests/e2e/README.md`:
   `ffmpeg -f lavfi -i testsrc2=size=640x360:rate=60 -t 4 -pix_fmt yuv420p -c:v libx265 -preset fast -x265-params "keyint=60:min-keyint=60:bframes=0:scenecut=0:repeat-headers=1:aud=1:log-level=error" -f hevc tests/e2e/fixtures/testsrc_360p60_k60.h265`
   This gives 240 frames with an IDR every 60, and every IDR access unit carries
   VPS+SPS+PPS, like the phone's.
2. **`ipcam_e2e.py`**: Python 3.8+ standard library only. One process with
   threads, so all timestamps use one clock (`time.monotonic_ns()`).
   - *AU source:* split the Annex-B file on start codes. NAL type is
     `(byte >> 1) & 0x3f`. Start a new access unit at each AUD (type 35), then
     strip the AUD NALs. Mark an AU as a join point when it contains types 32, 33,
     34, and either 19 or 20.
   - *FakePhone:* a TCP server on `127.0.0.1:12345` with `SO_REUSEADDR`. For each
     accepted connection, send `struct.pack('<IIQBI', 0x4950434D, frame_no, ts_us, 0, len(au)) + au`
     at 60 fps, where `ts_us = time.monotonic_ns() // 1000`. Loop the fixture.
     Record `(au_index, is_join, send_done_ns)` after each `sendall`. Expose hooks
     for the scenarios added in T0.6.
   - *UdpSink:* bind `127.0.0.1:12346` with `SO_RCVBUF` = 16 MiB, record
     `(arrival_ns, datagram)`, and write `capture.ts` to the work directory.
   - *Analyzer:* parse 188-byte TS packets (sync byte 0x47). Find the video PID
     from PAT and then PMT (stream_type 0x24). Count continuity-counter errors per
     PID, ignoring a PID's first packet and packets with the adaptation-field
     discontinuity_indicator set. Assemble PES packets on
     payload_unit_start_indicator, and for each one record its PTS (33-bit), the
     arrival time of its first datagram, and the NAL types in its payload.
   - *Receiver:* `subprocess.Popen([receiver, "--host", "127.0.0.1"])`, with
     stdout and stderr going to `receiver.log` in the work directory. Start the
     sink first, then the fake phone, then the receiver. At the end, assert
     `poll() is None` (the receiver didn't exit), then terminate it.
   - *Scenario `steady`* (6 s) asserts:
     A1: the receiver stayed alive.
     A2: the first PES contains VPS, SPS, PPS, and IDR.
     A3: the relayed PES count ≥ the AUs sent since the first join point minus 2,
     and is ≤ that number.
     A4: CC errors = 0.
     A5: PTS is strictly increasing.
     A6: if `ffmpeg` is on PATH, `ffmpeg -v error -i capture.ts -f null -` prints
     nothing.
     A7: relay latency (first-datagram arrival minus AU `send_done_ns`) has
     p95 < 50 ms.
   - Print one line, `E2E_SUMMARY {json}`, with the counts and latency
     p50/p95/max. Exit 0 on pass, or 1 with a clear message naming the failed
     assertion.
   - CLI: `--receiver PATH --scenario NAME [--workdir DIR]`. The default work
     directory is a temporary directory, which the script prints.
3. **`tests/receiver_e2e_test.sh`**:
   ```sh
   #!/usr/bin/env sh
   set -eu
   receiver="${1:-build/windows-binaries/receiver.exe}"
   scenarios="${2:-steady}"
   py=""
   for c in python3 python; do
     if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
       py="$c"; break
     fi
   done
   [ -n "$py" ] || { echo "receiver e2e: python 3.8+ not found" >&2; exit 1; }
   [ -f "$receiver" ] || { echo "receiver e2e: $receiver not found" >&2; exit 1; }
   for s in $scenarios; do
     "$py" "$(dirname "$0")/e2e/ipcam_e2e.py" --receiver "$receiver" --scenario "$s"
   done
   ```
   (`python3` on Windows can be the Store stub, which is why the loop probes each
   candidate.)
4. **`tests/test_registry_contract.sh`**: as the first line inside
   `for path in "$tests_dir"/*; do`, add
   `[ -d "$path" ] && continue  # helper dirs (tests/e2e) are driven by a top-level runner`.
   After the loop, add
   `if [ -d "$tests_dir/e2e" ]; then grep -q 'e2e/ipcam_e2e.py' "$tests_dir/receiver_e2e_test.sh" || fail "tests/e2e is not driven by tests/receiver_e2e_test.sh"; fi`.
5. **`scripts/check.sh`**: add a section `echo "== End-to-end (receiver.exe)"`.
   On `MINGW*|MSYS*|CYGWIN*`, if `${RECEIVER_EXE:-build/windows-binaries/receiver.exe}`
   exists, run `run "receiver e2e" sh tests/receiver_e2e_test.sh "$exe" "steady"`.
   Otherwise `skip "tests/receiver_e2e_test.sh" "receiver.exe not built (sh scripts/build_receiver_msys2.sh)"`.
   On other systems, skip with "needs Windows (CI windows job runs it)".
6. **CI (windows job)**: add `mingw-w64-ucrt-x86_64-python` to the msys2 `install:`
   list. After the step that fills `windows-binaries/`, add:
   ```yaml
   - name: Receiver end-to-end tests (fake iPhone -> receiver.exe -> UDP sink)
     run: |
       cd "${{ github.workspace }}"
       sh tests/receiver_e2e_test.sh "$PWD/windows-binaries/receiver.exe" "steady"
   ```
7. **Rules:** in `docs/ENGINEERING_RULES.md`, R-ENG-TEST gets the bullet
   "End-to-end: `tests/receiver_e2e_test.sh` drives `tests/e2e/` (Python 3 stdlib
   + ffmpeg CLI only; approved gate G1)". R-ENG-DEPS gets "Test-only tooling:
   Python 3 stdlib and ffmpeg/ffprobe CLIs (G1)".

**Contract changes:** the registry edit in step 4 (it allows a directory, and
removes nothing).
**AC:** AC1: `steady` passes locally once T0.3's `receiver.exe` exists (owner) and
in CI. AC2: check.sh shows 0 FAIL, and SKIP when there's no `receiver.exe`. AC3:
the registry contract still flags a top-level test file that isn't wired in (try a
dummy file locally, then delete it).

### T0.6 Receiver fault scenarios · `test/receiver-e2e-faults` · S · deps T0.5 · Gate G1

**Steps:** in `ipcam_e2e.py`, add these scenarios. Each one restarts the sink,
fake phone, and receiver.

| Scenario | Fake phone does | Assertions |
|---|---|---|
| `midgop` | Starts each connection at AU index 10 (a delta) | No PES before the first join AU; the first PES has VPS/SPS/PPS/IDR |
| `disconnect` | Closes the socket after 2 s, accepts again, resumes from an IDR | Receiver alive; gap from the close to the first relayed AU of session 2 is < 3.0 s (T1.8 tightens this to 1.5 s); no CC errors other than at the discontinuity |
| `stall` | Pauses 3 s mid-stream on the same socket | No reconnect (`receiver.log` has no `stream ended`); relaying resumes |
| `stall_timeout` | Pauses 7 s | Receiver logs a timeout, reconnects, and relays again within 10 s of the pause start |
| `garbage` | Sends 21 bytes with a bad magic | Log shows `invalid stream header`; receiver alive; next session relays |
| `oversize` | Sends a valid header with `frame_size = 16*1024*1024 + 1` | Session dropped without reading the payload; receiver alive; next session relays |
| `burst` | Pauses 300 ms, then sends 18 AUs back to back | All relayed, CC errors = 0. Print `pts_minus_arrival_ms` (min/max/last) as information for G5 |
| `loss4k` (optional) | Only if `ffmpeg` with libx265 is available: generates a 1 s 3840x2160 fixture at runtime with the same x265 params, and sends its IDR through a sink with `SO_RCVBUF` 2 MiB and then 256 KiB | **Report only** the CC-error count per buffer size, as data for G6 and T2.3. Never fail on it |

Update the CI step and the check.sh scenario list to
`"steady midgop disconnect stall stall_timeout garbage oversize burst"`.
`loss4k` runs only when requested by hand.
**AC:** all listed scenarios pass in CI. A scenario that fails on current `main`
code is a **real receiver bug**: report it, and don't loosen the assertion.

### T0.7 `StreamSender` socket test on macOS · `test/ios-sender-socket-test` · S · deps T0.1

**Why:** P5. `StreamSender.swift` imports only Foundation and Network, so it
compiles on macOS and can be tested with real sockets. It's the base for T1.2,
T1.3, and T1.6.
**Steps:**
1. Create `tests/stream_sender_test.swift`, compiled with `ios/StreamSender.swift`
   and `shared/StreamHeader.swift`. Helpers:
   - `check(_ ok: Bool, _ msg: String)`: prints `FAIL: msg` and calls `exit(1)`.
     Don't use `assert`.
   - `waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool`: spins
     `RunLoop.main.run(until: Date().addingTimeInterval(0.01))`.
   - A BSD-socket client: `connect` to 127.0.0.1:12345, retrying until a deadline;
     `readExact(n, timeout)` using `SO_RCVTIMEO`; and decoding of the 21-byte
     little-endian header.
   - Payloads: the first byte is `K` for a keyframe or `D` for a delta, and the
     second byte is the sequence number.
2. Test cases:
   - **C1:** `sender.start()`. A client connects within 3 s, and `onClientConnected`
     fires within 3 s.
   - **C2:** a delta sent before any keyframe arrives at the client within 300 ms.
     A keyframe then arrives with magic `0x4950434D`, the right size, and payload
     `K`. A following delta arrives in order.
   - **C3:** the header's `frameNumber`, `timestampUs`, and `codec` round-trip.
   - **C4:** the client closes. A new client connects, `onClientConnected` fires
     again, and the gate is re-armed (a delta isn't delivered before a keyframe).
   - **C5:** `sender.stop()`. Within 3 s, connections are refused.
3. Wiring: in `scripts/check.sh`, add
   `swift_test tests/stream_sender_test.swift ios/StreamSender.swift shared/StreamHeader.swift`
   (the extra argument is passed to `swiftc`). In the CI ios job, add a step
   before **Build unsigned app**:
   ```yaml
   - name: Test StreamSender over real sockets
     run: |
       xcrun swiftc -swift-version 5 ios/StreamSender.swift shared/StreamHeader.swift \
         tests/stream_sender_test.swift -o /tmp/stream_sender_test
       /tmp/stream_sender_test
   ```
4. In `tests/windows_ci_contract.sh`, add `stream_sender_test` to the
   `for runtime_test in …` list.

**AC:** AC1: passes in CI (macOS). Locally it's SKIP, so state "CI must confirm".
AC2: registry and check.sh show 0 FAIL.

### T0.8 Docker cross-build of `receiver.exe` · `chore/docker-receiver-cross-build` · O · deps T0.2 · Gate G2 · OPTIONAL

**Why:** builds `receiver.exe` without MSYS2. Skip this if T0.3 is enough for the
owner.
**Outline (pin every version):** `docker/receiver-mingw.Dockerfile` on
`ubuntu:24.04` with `mingw-w64`, autotools, `pkg-config`, `nasm`, and `git`.
Cross-build with `--host=x86_64-w64-mingw32`: libplist `2.6.0`
(`--without-cython`), libimobiledevice-glue `1.3.1`, and libusbmuxd `2.1.0`. Build
FFmpeg `n7.1` as a minimal shared build (`--enable-cross-compile
--target-os=mingw32 --arch=x86_64 --cross-prefix=x86_64-w64-mingw32-
--disable-everything --enable-network --enable-protocol=udp,file
--enable-muxer=mpegts --enable-decoder=hevc --enable-parser=hevc --enable-d3d11va
--enable-hwaccel=hevc_d3d11va --enable-shared --disable-static --disable-programs`).
Then link `receiver.exe` with `x86_64-w64-mingw32-g++-posix` using the CI flags
plus `-static-libgcc -static-libstdc++`, and collect the DLLs into
`build/docker-windows-binaries/`. Add `scripts/docker_build_receiver.sh`.
**Stop rule:** if `gpu_frame_publisher.cpp` doesn't compile with the mingw headers
(`d3d11_4.h`, `wrl/client.h`), stop and report. G9/T4.1 removes that file.
**AC:** the produced `receiver.exe` passes `sh tests/receiver_e2e_test.sh build/docker-windows-binaries/receiver.exe`
on the Windows host.

---

### T1.1 Disconnect reasons on the phone · `diag/ios-disconnect-reasons` · S · deps T0.0

**Why:** confirm on the device which of F1–F5 the owner actually hits.
**Behavior:** the diagnostics label gets a 4th line:
`LINK reconnects <n> • last: <reason> <HH:mm:ss>`.
**Steps:**
1. In `StreamSender`, add `var onDisconnect: ((String) -> Void)?` and
   `private func noteDisconnect(_ reason: String)`. It asserts
   `dispatchPrecondition(condition: .onQueue(queue))` and calls `onDisconnect?(reason)`.
   Call it wherever a **live** connection ends, once per event, and only if
   `connection != nil` at that point:
   - `restartListening` → `"listener restart: \(reason)"`
   - `newConnectionHandler` replacing an existing connection → `"replaced by new PC connection"`
   - connection `.failed(let error)` → `"connection failed: \(error.localizedDescription)"`
   - connection `.cancelled` → `"PC connection closed"`
   - `pumpSend` error → `"send error: \(error.localizedDescription)"`
   - listener `.failed` while a connection exists → `"listener failed: \(error.localizedDescription)"`
2. In `CameraStreamer`, add `linkDropCount: UInt64` and `lastLinkDropReason: String`,
   guarded by `telemetryLock`. In `configureSession`, next to the other `sender.on…`
   assignments, set `sender.onDisconnect` to record them with the time
   (`DateFormatter` `HH:mm:ss`, created once) and call `publishDiagnostics()`.
3. In `publishDiagnostics`, append
   `\nLINK reconnects %llu • last: %@` (`"none"` when the count is 0).

**Contract changes** (additions): in `camera_feedback_source_contract.sh`,
`grep -q 'var onDisconnect' "$sender"` and `grep -q 'LINK reconnects' "$streamer"`.
**AC:** AC1: every code path that drops a live connection calls `noteDisconnect`
exactly once (review list). AC2: existing contracts pass. AC3: the Swift build
passes (CI).

### T1.2 Listener address reuse and fast retry · `fix/ios-listener-reuse` · S · deps T0.7

**Why:** F2, plus no Nagle delay on frame tails.
**Steps:**
1. In `startOnQueue`, replace `let params = NWParameters.tcp` with:
   ```swift
   let tcpOptions = NWProtocolTCP.Options()
   // Push each frame out immediately; Nagle would hold back a frame's tail.
   tcpOptions.noDelay = true
   let params = NWParameters(tls: nil, tcp: tcpOptions)
   // restartListening closes the PC connection server-side, leaving port
   // 12345 in TIME_WAIT. Without reuse the rebind fails and backs off ~30 s.
   params.allowLocalEndpointReuse = true
   ```
2. In `scheduleRestart`, change the delay to
   `let delay = min(2.0, 0.25 * pow(2.0, Double(listenerRetryAttempt)))`. A
   personal app should retry quickly, forever.
3. Extend `tests/stream_sender_test.swift` with **C6:** while a client is
   connected and frames are flowing, call `sender.restartListening(reason: "test")`.
   The client sees EOF. A new client connects within 3 s and receives a keyframe
   sent after it connects. Repeat 5 times in a row.

**Contract changes** (additions, in `stream_sender_source_contract.sh`):
`grep -q 'allowLocalEndpointReuse = true'`, `grep -q 'noDelay = true'`,
`grep -q 'min(2.0, 0.25 \* pow(2.0'`.
**AC:** AC1: C6 passes in CI. AC2: all contracts pass. If C6 also passes without
the step-1 fix, keep the fix (it's harmless) and record that fact in your status
row, because it means F2 is less likely.

### T1.3 Recovery keeps the connection · `fix/ios-recovery-keeps-connection` · S · deps T1.2

**Why:** F1, principle P1.
**Steps:**
1. In `StreamSender`, add:
   ```swift
   /// Media discontinuity (camera or encoder rebuilt) without a transport fault.
   /// Keep the PC connection; drop queued deltas and wait for a fresh IDR.
   func resetForDiscontinuity(reason: String) {
       queue.async { [weak self] in
           guard let self else { return }
           self.pendingPackets.removeAll(keepingCapacity: true)
           self.waitingForKeyFrame = true
           self.sendGeneration &+= 1
           self.report(reason)
       }
   }
   ```
   A packet already handed to Network.framework is always a *whole* packet, so
   the byte stream stays frame-aligned.
2. In `CameraStreamer.recoverSession`, replace
   `sender.restartListening(reason: "USB listener rebound after camera recovery")`
   with `sender.resetForDiscontinuity(reason: "Camera recovered • waiting for keyframe")`.
   The `requestKeyFrame()` call that follows stays.
3. Don't change `setOutputOrientation`. Its reconnect is intentional.
4. Extend the test with **C7:** while connected, call `resetForDiscontinuity`. The
   client gets no EOF within 1 s, deltas sent afterwards aren't delivered, then a
   keyframe is delivered.

**Contract changes:**
- `encoder_setup_source_contract.sh`: keep `grep -q 'sender.restartListening'`
  (still used by orientation). Add an awk check: inside
  `private func recoverSession(` up to `private func scheduleRecovery(reason:`
  there is `resetForDiscontinuity` and no `restartListening`.
- `stream_sender_source_contract.sh`: add `grep -q 'func resetForDiscontinuity'`,
  plus an awk check that its body contains `waitingForKeyFrame = true` and
  `pendingPackets.removeAll`, and does **not** contain `cancel()`.
- `docs/ENGINEERING_RULES.md` R-ENG-RECOVER: add "Sender:
  `resetForDiscontinuity` for media-only discontinuities".

**AC:** AC1: camera recovery no longer closes the socket (review + C7). AC2:
R-ENG-RECOVER still holds, because the sender gate is re-armed and an IDR is
forced.

### T1.4 Path monitor only rebuilds a dead listener · `fix/ios-path-monitor-guard` · S · deps T1.2

**Why:** F3.
**Steps:**
1. Add `private var listenerReady = false` (confined to `queue`). Set it to `true`
   in the listener `.ready` case, after the identity guard. Set it to `false` in
   `.failed` and `.cancelled` (after their identity guards), in `restartListening`,
   in `stop()`, and when `startOnQueue` creates a new listener.
2. In `handlePathUpdate`, after the existing `guard let previous …` line, add:
   ```swift
   // A ready listener is bound to the wildcard address and keeps accepting on
   // interfaces that appear later. Never drop a working PC connection because
   // Wi-Fi or cellular changed; only rebuild a listener that is not ready.
   guard !listenerReady else {
       print("SENDER: network path changed; listener still ready")
       return
   }
   ```
   Keep the existing `restartListening(reason: "USB network path changed • rebinding listener")`.

**Contract changes** (addition): `grep -q 'guard !listenerReady else'`.
**AC:** AC1: a path change while the listener is ready doesn't call
`restartListening` (review). AC2: DC-1 item 3 passes.

### T1.5 Light foreground resume · `fix/ios-light-foreground-resume` · S · deps T1.3

**Why:** F1. Inactive/active transitions don't stop capture.
**Steps:** replace the body of `resumeAfterForeground` with:
```swift
sessionQueue.async { [weak self] in
    guard let self else { return }
    self.appIsActive = true
    self.recoveryAttempt = 0
    // Control Center, notifications, Siri and the USB "Trust" alert make the
    // app inactive without stopping capture. Keep a healthy pipeline as is.
    if self.isConfigured, !self.stopped,
       self.session.isRunning, !self.session.isInterrupted,
       !self.isEncoderSetupFailed() {
        self.startLivenessWatchdog()
        if self.activeEncoder() == nil {
            // Rebuilt lazily on the next frame with a forced IDR.
            self.sender.resetForDiscontinuity(reason: "Camera resumed • waiting for keyframe")
            self.requestKeyFrame()
        }
        return
    }
    self.recoverSession(reason: "Camera resumed • waiting for encoder")
}
```
**Contract changes** (addition, in `encoder_setup_source_contract.sh`):
`grep -q 'session.isInterrupted' "$source"`. Existing pins (`resumeAfterForeground`,
the `recoverSession` backoff awk) must still pass.
**AC:** AC1: with a running, uninterrupted session, `recoverSession` isn't called
(review). AC2: real backgrounding (the session is interrupted or stopped) still
runs full recovery. AC3: DC-1 item 2 gives 0 reconnects.

### T1.6 Drop means wait for keyframe · `fix/ios-drop-to-keyframe` · S · deps T1.3

**Why:** F4, principle P2.
**Steps:**
1. In `StreamSender`, add `var onKeyFrameNeeded: (() -> Void)?`. In `send()`,
   replace the overflow guard body:
   ```swift
   guard self.pendingPackets.count < self.maxQueuedPackets else {
       self.droppedFrameCount &+= 1
       // A dropped frame breaks the reference chain. Stop admitting deltas
       // and ask for an IDR instead of streaming corrupt video for up to 2 s.
       self.waitingForKeyFrame = true
       self.onKeyFrameNeeded?()
       return
   }
   ```
2. In `CameraStreamer.configureSession`, next to the other callbacks, add
   `sender.onKeyFrameNeeded = { [weak self] in self?.requestKeyFrame() }`.
   (`requestKeyFrame` is lock-protected and idempotent.)
3. Add test **C8:** a client connects but doesn't read. Send 200 frames of 256 KB
   each (a keyframe first, then deltas) as fast as possible. `onKeyFrameNeeded`
   must fire at least once. Then send a keyframe and 5 deltas, and start reading.
   For every gap in `frameNumber`, the packet after the gap must be a keyframe
   (payload byte 0 is `K`).

**Contract changes** (additions): in `stream_sender_source_contract.sh`,
`grep -q 'onKeyFrameNeeded'`, plus an awk check that the block after
`guard self.pendingPackets.count < self.maxQueuedPackets else` contains
`waitingForKeyFrame = true` before its `return`. In `hevc_join_source_contract.sh`,
`grep -q 'onKeyFrameNeeded' "$camera"`. R-ENG-RECOVER: add "queue overflow" to the
list of discontinuities.
**AC:** AC1: C8 passes in CI. AC2: `maxQueuedPackets = 8` is unchanged (the
contract pins it).

### T1.7 Max frame-size guard (D5) · `fix/ios-max-frame-guard` · H · deps T1.6

**Steps:**
1. In `shared/StreamHeader.swift`, add
   `static let maxFrameSize = 16 * 1024 * 1024 // STREAM_MAX_FRAME_SIZE in stream_protocol.h`.
2. In `StreamSender.send`, replace the `UInt32.max` guard with:
   ```swift
   guard frame.count <= StreamHeader.maxFrameSize else {
       print("ERROR: encoded frame \(frame.count) bytes exceeds protocol limit")
       queue.async { [weak self] in
           self?.waitingForKeyFrame = true
           self?.onKeyFrameNeeded?()
       }
       return
   }
   ```
3. Read `tests/protocol_parity_contract.sh` and add an assertion **in its existing
   style** that the C value `16U * 1024U * 1024U` and the Swift value
   `16 * 1024 * 1024` both exist. In `tests/stream_header_test.swift`, check
   `StreamHeader.maxFrameSize == 16_777_216`.
4. In `docs/ENGINEERING_RULES.md`, remove the D5 row, or mark it fixed, citing T1.7.

**AC:** the parity contract passes, and the Swift test passes in CI.

### T1.8 Fast reconnect · `fix/receiver-fast-reconnect` · H · deps T0.6

**Steps:** in `run_receiver`, after `receive_session` plus `closesocket(fd)`,
print `WARN: stream ended; reconnecting in 250 ms` and sleep
`std::chrono::milliseconds(250)`. The no-device branch keeps its 1 s sleep (move
each sleep into its own branch). First run `grep -rn "retrying in 1 second" tests/`;
if a contract pins the old message, list it in your report and update it.
In `ipcam_e2e.py` `disconnect`, tighten the gap threshold to **< 1.5 s**.
**AC:** e2e `disconnect` passes with the new threshold (locally if `receiver.exe`
is built, and in CI).

### T1.9 Disable console QuickEdit · `fix/receiver-console-quickedit` · H · deps T0.0

**Why:** F5.
**Steps:** add to `receiver.cpp` and call it in `main()` right after `WSAStartup`
succeeds:
```cpp
// Clicking the console enables QuickEdit selection, which suspends any thread
// that writes to the console. The relay must never stall on a log line.
static void disable_console_quick_edit() {
    HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
    DWORD mode = 0;
    if (input == nullptr || input == INVALID_HANDLE_VALUE || !GetConsoleMode(input, &mode)) return;
    mode &= ~static_cast<DWORD>(ENABLE_QUICK_EDIT_MODE);
    mode |= ENABLE_EXTENDED_FLAGS;
    SetConsoleMode(input, mode);
}
```
**Contract changes** (addition): `grep -q 'ENABLE_QUICK_EDIT_MODE' "$receiver"`.
**Docs:** a QUICKSTART troubleshooting row: "Video froze after clicking the
receiver window: fixed in this receiver build. On old builds, press Esc."
**AC:** the CI link passes. DC-1 item 7 passes.

### T1.10 USB troubleshooting and doc drift · `docs/usb-troubleshooting` · H · deps T0.0

**Steps (docs only):**
- `docs/QUICKSTART.md`:
  - Remove "The app shows nothing (no UI by design)". The app shows a preview,
    status lines, and an orientation switch.
  - State that Apple Devices (usbmux) is the preferred USB path, and Personal
    Hotspot is only a fallback.
  - Add troubleshooting rows:
    - Windows USB selective suspend: Control Panel → Power Options → Change plan
      settings → Advanced → USB settings → USB selective suspend → Disabled.
    - Use a direct motherboard port (no hub) and a data-capable cable.
    - Keep the app in the foreground; the screen stays awake by design.
    - Answer the "Trust This Computer" prompt once.
    - If iOS shows "Allow accessory to connect?", allow it.
- `README.md` roadmap step 2: "USB send via usbmux (Personal Hotspot fallback)".

**AC:** the facts match the code (cite `receiver.cpp` `connect_to_device` order).

---

### T2.1 Receiver timing stats · `diag/receiver-timing-stats` · S · deps T0.0

**Why:** F7 and F14. Makes delay growth visible.
**Steps:**
1. Create the new pure header `windows/stream_timing.h` (C++ standard headers
   only), with `class StreamTimingStats final`:
   - `void BeginSession()`
   - `void OnFrame(uint64_t sourceUs, uint64_t arrivalUs)`. It computes
     `offset = static_cast<int64_t>(arrivalUs) - static_cast<int64_t>(sourceUs)`
     (signed, so there's no unsigned underflow; R-ENG-TIME) and tracks:
     the session-minimum offset; `extraDelayUs = offset - minOffset` (current and
     window max); `skewUs = offset - firstOffset` (a slow trend means the two
     clocks drift, or delay is building up); `maxArrivalGapUs`; and
     `burstFrames` (frames arriving < 2 ms after the previous one).
   - `void ResetWindow()`, plus getters for each value.
2. In `receiver.cpp`, after the frame payload is read, compute `arrivalUs` from
   `std::chrono::steady_clock` and call `stats.OnFrame(h.timestamp_us, arrivalUs)`.
   Call `BeginSession()` at session start. Extend the STAT line with
   `extraDelayMs=%.1f maxExtraMs=%.1f maxGapMs=%.1f burst=%u skewMs=%.1f`, then
   call `ResetWindow()`.
3. F14: count relay drops (`RelayRecoveryAction::Drop`) separately from write
   failures. Make `ObsUdpRelay::Write` report which happened (for example, return
   an enum or set an out-parameter). Print `relayGateDrop=%llu` next to
   `relayDrop`. Keep the `relayWriteFailures` identifier, which a contract pins.
4. Test `tests/stream_timing_test.cpp` (asserts, no `NDEBUG`):
   - 60 fps steady: extra delay ≈ 0 and burst = 0.
   - A 100 ms stall followed by a burst: max gap ≈ 116 ms, burst > 0, and extra
     delay spikes and then returns to ≈ 0.
   - A source timestamp going backwards: no crash and no huge values.
   - A simulated 100 ppm drift over 10 minutes: skew ≈ 60 ms.
5. Wire the test in everywhere: the `g++` lines in the `build.yml` windows job,
   a `cpp_test` line in `check.sh`, `windows/CMakeLists.txt` CTest, and the
   `for test_name in …` list in `tests/windows_ci_contract.sh`. Add
   `windows/stream_timing.h` to the R-ARCH-4 header loop in
   `tests/architecture_boundary_contract.sh`, to the CLAUDE.md module table row
   for pure relay logic, and to the R-ARCH-4 list in `ENGINEERING_RULES.md`.

**AC:** the test passes (in Docker via T0.2, or in CI). STAT shows the new fields,
and e2e `burst` shows a nonzero burst count in `receiver.log`.

### T2.2 Phone latency telemetry · `diag/ios-latency-telemetry` · S · deps T1.6

**Steps:**
1. Encode latency: in the VideoToolbox output callback (success path), compute
   `now − capture PTS`. Use `CMClockGetTime(session.synchronizationClock ?? CMClockGetHostTimeClock())`
   for now, and `CMSampleBufferGetPresentationTimeStamp(sb)` for the capture
   time. Both are host-clock times. Keep the window max in telemetry, under
   `telemetryLock`.
2. Queue latency: store the enqueue time with each pending packet. Change
   `pendingPackets: [Data]` to `[(data: Data, enqueuedAt: TimeInterval)]` and
   update every use. On a successful completion, record `now − enqueuedAt`, keep
   the window max, and report it with the existing `onFrameRate` cadence through
   a new callback `onQueueLatency: ((Double) -> Void)?`.
3. Diagnostics line: `LATENCY encode %.0f ms • queue %.0f ms (max per 1 s)`.

**Contract changes** (addition): `grep -q 'LATENCY encode' ios/CameraStreamer.swift`
in `encoder_setup_source_contract.sh`. Existing `pendingPackets.removeAll` pins
must still match.
**AC:** the Swift build passes in CI, and the C2–C8 sender tests still pass.

### T2.3 OBS latency settings and A/V sync · `docs/obs-latency-and-av-sync` · H · deps T2.1, T2.2

**Docs only.** Rewrite `OBS-SETUP.md` and create `docs/LATENCY.md`:
- **Media Source settings:**
  - Local File off; input `udp://127.0.0.1:12346`; format `mpegts`.
  - Hardware decoding on.
  - **Restart playback when source becomes active: off.**
  - **Close file when inactive: off.**
  - **Network Buffering: 4 MB.** In current OBS versions this sets FFmpeg's UDP
    receive buffer (`buffer_size`). A bigger buffer prevents lost keyframe bursts
    and doesn't add delay. Verify with T0.6 `loss4k` if in doubt.
  - If your OBS has an **FFmpeg Options** field, try
    `fflags=nobuffer probesize=1000000 analyzeduration=0`. It shrinks the startup
    backlog that otherwise becomes permanent delay. Keep it only if glass-to-glass
    improves and video still starts.
  - If delay seems to have grown: right-click the source → **Restart**.
- **Glass-to-glass measurement:**
  1. Show a millisecond stopwatch on the PC monitor.
  2. Point the iPhone at it.
  3. Take a screenshot showing both the real stopwatch and OBS's preview of it.
     Latency = real − shown.
  4. Take 5 samples at t=0, 10 min, and 30 min, and record them in section 10.
- **Mic sync:** OBS → Edit → Advanced Audio Properties → your mic → **Sync
  Offset** = the measured median (ms). Fine-tune with a clap test in a local
  recording: step frame by frame and adjust until the clap sound and image align.
  Re-check after 30 min. If it drifted, report STAT `skewMs` (this triggers G5).
- **Reading the numbers:** the phone shows `LATENCY encode/queue`, and the
  receiver STAT shows `extraDelayMs`/`skewMs`. Explain each in one sentence.

**AC:** every setting and number is consistent with the code and with T0.6
results.

### T2.4 Encoder latency tuning · `perf/ios-encoder-latency` · S · deps DC-2 · Gate G3

**Steps:**
1. `MaxKeyFrameInterval` 120 → 60. In the same property list, add
   `("keyframe duration", VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 1)))`.
2. After the fatal property list, add a **non-fatal** call
   `VTSessionSetProperty(enc, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)`.
   On failure, only `print` (encoder setup must not fail because of this optional
   property).
3. Only if DC-2 recorded a queue latency with a sustained p95 above 50 ms: change
   `maxQueuedPackets` 8 → 4 and update the contract pin. Otherwise leave it at 8.

**Contract changes:** in `encoder_setup_source_contract.sh`, change
`'MaxKeyFrameInterval, value: NSNumber(value: 120)'` to `… 60)` with the comment
`# G3: 1 s keyframe interval halves recovery/OBS join time`. Add
`grep -q 'PrioritizeEncodingSpeedOverQuality'`.
**AC:** contracts pass; CI build passes. DC-2 repeat: glass-to-glass isn't worse.

### T2.5 Relay timeline from PC arrival time · `fix/relay-arrival-timeline` · S · deps T2.1, T0.6 · Gate G5

**Why:** F7. OBS paces playout by PTS. If PTS comes from the PC's own clock at
arrival, clock skew can't build up, and a burst plays out immediately instead of
staying late.
**Steps:**
1. In `windows/relay_timestamp.h`, add `class ArrivalTimestampClock final` with
   `uint64_t Stamp(uint64_t arrivalUs)`:
   - The first call returns 0 and stores the origin.
   - Later calls return `arrivalUs - origin` if `arrivalUs > origin`, or else
     `last + 1`.
   - The result is clamped to be at least `last + 1`, so it's strictly increasing.
   - The origin is **never** reset between phone sessions (arrival time is
     continuous).
   Keep `RelayTimestampClock` and its test.
2. `ObsUdpRelay::Write` takes a new `uint64_t arrivalUs` parameter. Replace
   `timestamp_clock_.Rebase(timestampUs)` with `arrival_clock_.Stamp(arrivalUs)`.
   Remove the `timestamp_clock_` member and the `BeginSession` call chain only if
   nothing else uses it. Keep `std::max(candidatePts, last_mux_pts_ + 1)`.
3. In `receive_session`, pass the `arrivalUs` computed in T2.1.
4. Extend `tests/relay_timestamp_clock_test.cpp`:
   - strictly increasing output;
   - identical arrivals give +1 µs each;
   - gaps are preserved;
   - the first value is 0;
   - values near `UINT64_MAX / 2` don't overflow.
5. Add an assertion to e2e `burst`: after a 300 ms stall and burst,
   `pts_ms − arrival_ms` returns to within ±5 ms of its value before the stall.

**Contract changes:** in `obs_udp_relay_contract.sh`,
`camera_orientation_timestamp_contract.sh`, and `receiver_source_contract.sh`,
replace every `timestamp_clock_.Rebase(timestampUs)` pin with
`arrival_clock_.Stamp(arrivalUs)`, and the `RelayTimestampClock` receiver pin with
`ArrivalTimestampClock`. Add the comment `# G5: relay timeline follows PC arrival time`.
Keep every `! grep 'timestampUs - first_timestamp_us_'` and `std::max(candidatePts…`
pin. Update R-ENG-TIME in `ENGINEERING_RULES.md`.
**AC:** tests and e2e pass. DC-2 repeat: `skewMs` growth no longer shows up as
growing glass-to-glass delay over 30 min.

### T2.6 Loopback TCP output to OBS · `feat/relay-tcp-output` · O · Gate G6 · OPTIONAL

Do not code this directly. First write `docs/plan/T2.6-relay-tcp.md` as a
mini-plan of 3–4 sub-branches for owner review. The design to evaluate:
- A new `--obs-tcp` mode. The receiver listens on `127.0.0.1:12346` (loopback
  only, R-ENG-SEC) and accepts one OBS client without blocking.
- It writes MPEG-TS through a custom `AVIOContext` (write callback) into a bounded
  ring of about 8 MB that drains with non-blocking `send`.
- On overflow or client loss: drop the client, reset the muxer, and gate to the
  next join AU.
- A new client gets fresh PAT/PMT and starts at the next IDR. That's lossless and
  removes the OBS startup backlog.
- OBS input becomes `tcp://127.0.0.1:12346`. UDP stays the default until DC
  validation.
- Pure parts (the ring and the client state machine) go in a new
  `windows/*.h` with runtime tests. e2e gets a TCP sink.

### T2.7 Pause encoding with no PC · `perf/ios-idle-encoder-pause` · S · Gate G4 · deps T1.6

**Steps:**
1. In `CameraStreamer`, add `private var receiverWantsVideo = false`, guarded by
   `encoderStateLock`. In the existing `sender.onConnectionState` closure, set it
   **before** the `sessionQueue` hop: `.connected` and `.sending` → `true`;
   `.waiting`, `.disconnected`, `.failed` → `false`.
2. In `captureOutput`, right after `recordSensorFrame(pts)`, add
   `guard receiverWantsVideoNow() else { return }` (a lock-protected getter). The
   preview layer is independent, so it stays live.
3. Health line: when idle, `"HEVC paused • waiting for PC"`. A forced IDR on
   connect already exists (`onClientConnected` → `requestKeyFrame`).

**Contract changes** (addition): `grep -q 'receiverWantsVideo'` in
`encoder_setup_source_contract.sh`.
**AC:** CI build passes. DC: with no PC, the HEVC fps shows 0. Connecting starts
video within 1 s.

---

### T3.1 Wi-Fi mode (opt-in) · `feat/ios-wifi-mode` · S · Gate G7 (option A) · deps T1.4, T0.4

**Behavior:**
- A **Wi-Fi** switch on the phone, off by default and persisted.
- When off, the listener refuses Wi-Fi and cellular (it fixes D4 for USB use).
- When on, the phone shows `WI-FI <ip>:12345 • visible to this network`.
- The PC runs `receiver.exe --host <ip>`.

**Steps:**
1. In `StreamSender`:
   - Add `private var wifiEnabled = false` (confined to `queue`).
   - Add `func setWiFiEnabled(_ enabled: Bool)`. It does `queue.async`; if the
     value changed, it stores it, then calls `restartListening(reason: enabled ? "Wi-Fi streaming enabled" : "Wi-Fi streaming disabled")`.
   - In `startOnQueue`, after creating `params`:
     `if !wifiEnabled { params.prohibitedInterfaceTypes = [.wifi, .cellular] }`.
   - Add `var onWiFiAddress: ((String?) -> Void)?`. Publish it on listener
     `.ready` and on path updates. Use `getifaddrs` to find interface `en0`,
     `AF_INET`, converted with `inet_ntop`. Send `nil` when Wi-Fi mode is off or
     there's no address.
2. In `CameraStreamer`:
   - Add a stored preference `stream.wifiEnabled` (UserDefaults), defaulting to
     `false`.
   - Add `func setWiFiEnabled(_:)`, which persists the value and forwards it to
     the sender.
   - In `configureSession`, call `sender.setWiFiEnabled(stored)` **before**
     `sender.start()`.
   - Wire `onWiFiAddress` to a health line: `"WI-FI off (USB only)"` or
     `"WI-FI <ip>:12345 • visible to this network"`.
   - Add a static `isWiFiEnabledStored` for the UI.
3. In `CameraViewController`, add a `UISwitch` labeled "Wi-Fi" at the top right
   that calls `streamer.setWiFiEnabled`. It must not reference `StreamSender`
   (R-ARCH-3).
4. `ios/Info.plist`: extend `NSLocalNetworkUsageDescription` to mention optional
   Wi-Fi streaming.
5. Docs:
   - Add a QUICKSTART section "Wi-Fi mode": same network; turn on the switch;
     run `receiver.exe --host <ip>`; expect more latency and jitter than USB; the
     stream is visible to devices on that network.
   - `ENGINEERING_RULES.md` R-ENG-SEC: record the approved exception (G7-A).
   - Update the D4 row: "USB-only by default; Wi-Fi opt-in, unauthenticated".

**Contract changes** (additions): in `stream_sender_source_contract.sh`,
`grep -q 'prohibitedInterfaceTypes'` and `grep -q 'func setWiFiEnabled'`.
`architecture_boundary_contract.sh` must still pass (the UI doesn't reference the
transport).
**AC:** AC1: by default, a connection over Wi-Fi is refused (DC-3). AC2: USB via
usbmux still works with the switch off **and** on (DC-3). AC3: CI build passes.

### T3.2 Wi-Fi bitrate · `feat/ios-wifi-bitrate` · S · Gate G8 · deps T3.1

**Steps:**
1. In `StreamSender`, in connection `.ready`, compute
   `let overWiFi = conn.currentPath?.usesInterfaceType(.wifi) ?? false` and call a
   new `onClientTransport: ((Bool) -> Void)?` **before** `onClientConnected`.
2. In `CameraStreamer`:
   - Add `private static let usbBitRate = 40_000_000` and
     `private static let wifiBitRate = 25_000_000`, plus a current target guarded
     by `encoderStateLock`.
   - In `createEncoder`, use the current target for `AverageBitRate`, and
     `target / 4` bytes per second for `DataRateLimits` (40M → 10,000,000, the
     same as today).
   - On a transport change, apply both properties to the live encoder with
     `VTSessionSetProperty` (non-fatal), then call `requestKeyFrame()`.

**Contract changes:** in `encoder_setup_source_contract.sh`, replace
`'AverageBitRate, value: NSNumber(value: 40_000_000)'` with
`grep -q 'usbBitRate = 40_000_000'` and `grep -q 'wifiBitRate = 25_000_000'`.
Replace the rate-limit literal pin with a grep for the `DataRateLimits` call (add
the comment `# G8`).
**AC:** USB still encodes at 40 Mbps (review). On Wi-Fi the phone shows the lower
rate in DC-3.

### T3.3 Wi-Fi discovery (Bonjour) · `feat/wifi-discovery` · O · Gate G7 · OPTIONAL

Write a mini-plan first (`docs/plan/T3.3-wifi-discovery.md`). The design to
evaluate:
- When Wi-Fi mode is on, `NWListener.service = .init(name: nil, type: "_ipcamstream._tcp")`.
- `Info.plist` `NSBonjourServices`.
- `receiver.exe --wifi` browses with the Windows DNS-SD API (`DnsServiceBrowse`,
  `windns.h`/`dnsapi`, Windows 10 1709+). It's a system library, so no new
  dependency, but first confirm that the mingw headers declare it.

---

### T4.1 Retire `--gpu-ring` · `chore/retire-gpu-ring` · S · Gate G9 · OPTIONAL

Remove from the product: the decoder path (`init_decoder`, `drain_decoder`,
`select_d3d11_format`, `DecodeTelemetry`), `--gpu-ring`, and the
`gpu_frame_publisher.*` build. Move `gpu_frame_publisher.*` to the archived list
(D1 and D10 close). In CI, `CMakeLists.txt`, and `build_receiver_msys2.sh`, drop
`gpu_frame_publisher.cpp` and `-ld3d11 -ldxgi -lmfplat`. The contract edits must
be listed one by one in the PR: in `receiver_source_contract.sh`, remove
`select_d3d11_format`, `AV_PIX_FMT_D3D11`, `verified GPU decode`, `drain_decoder`,
and `--gpu-ring`; in R-ARCH-5 of the boundary contract, update the source list.
Update docs (CLAUDE.md module table, ENGINEERING_RULES, OBS-SETUP).
**AC:** e2e passes in CI, and `receiver.exe` gets smaller.

### T4.2 Soak sign-off · `docs/soak-signoff` · H · after the soak test in section 7

Record the results in section 10. Mark `README.md` roadmap step 5 done, with the
date and the numbers.

---

## 7. Device checkpoints (owner, manual)

Install the IPA and `windows-binaries` from the CI artifacts of `main` after the
listed tasks are merged. Record every run in section 10.

**DC-1 (after T1.1–T1.10):** the target is 0 `LINK reconnects` unless a step says
otherwise.
1. USB streaming to OBS for 10 min: no freezes, 0 reconnects.
2. Open and close Control Center and Notification Center 10 times: 0 reconnects.
3. Toggle phone Wi-Fi, then Airplane Mode, 3 times each, during USB streaming:
   0 reconnects.
4. Quit and restart `receiver.exe`: video back in OBS within 3 s.
5. Unplug and replug USB: video back within 5 s after the device is enumerated.
6. Lock the phone, then unlock it: video back within 5 s after unlock. (A
   reconnect is expected here.)
7. Click inside the receiver console for 10 s: no freeze.
8. Switch the orientation to portrait and back: note OBS behavior (F13).

**DC-2 (after T2.1–T2.3), latency baseline:** use the OBS settings from T2.3.
Take glass-to-glass medians at 0, 10, and 30 min, plus the phone `LATENCY` line
and receiver STAT `extraDelayMs`/`skewMs` at each time. Then the owner decides:
- **G3** if recovery or joins feel slow;
- **G5** if the delay at 30 min minus the delay at 0 is more than 30 ms, or
  `skewMs` trends steadily;
- **G6** if T0.6 `loss4k` or OBS shows keyframe breakage.

**DC-3 (after T3.x), Wi-Fi:**
1. Wi-Fi switch off: `receiver.exe --host <phone-wifi-ip>` keeps failing, and USB
   works.
2. Switch on: Wi-Fi connects, 10 min steady, and glass-to-glass is recorded.
3. Switch on: USB still works (unplug Wi-Fi from the PC side).
4. Walk away until the signal is weak: the stream recovers (keyframe gate) and
   the receiver reconnects with no manual action.

**Soak:** 30 min of 4K60 over USB, including two Control Center pulls. Pass means:
0 unexpected reconnects; glass-to-glass at 30 min within ±20 ms of the value at
0 min; and thermal state no worse than `fair`.

---

## 8. Plan maintenance

- Only the owner edits sections 1–7. If an executor finds that the plan is wrong
  (a wrong identifier, an impossible step), it reports this and sets its row to
  `BLOCKED`. The owner fixes the plan on `main` and records it in section 11.
- If two task branches are in flight at once and both edit section 9, resolve
  the merge conflict by keeping both rows' updates.

---

## 9. Status tracker

Status values: `TODO`, `IN-PROGRESS`, `DONE-PENDING-MERGE`, `DONE` (merged),
`BLOCKED`, `SKIPPED` (gate rejected).

| Task | Branch | Model | Depends on | Gate | Status | Date | Notes |
|---|---|---|---|---|---|---|---|
| T0.0 | main (owner) | — | — | — | DONE | 2026-11-25 | committed on main locally (not pushed) |
| T0.1 | ci/run-on-pull-requests | H | T0.0 | — | DONE | 2026-11-25 | Merged to main locally; first PR run confirms trigger |
| T0.2 | chore/docker-check-gate | H | T0.0 | G2 | TODO | | |
| T0.3 | chore/msys2-local-build | H | T0.0 | — | DONE | 2026-11-25 | Merged to main; script UNVERIFIED (no MSYS2 g++ on this PC), owner runs it once |
| T0.4 | feat/receiver-host-flag | S | T0.0 | — | DONE | 2026-11-25 | Merged to main; receiver link unverified locally, CI must confirm |
| T0.5 | test/receiver-e2e-harness | S | T0.3, T0.4 | G1 | DONE-PENDING-MERGE | 2026-11-26 | Branch test/receiver-e2e-harness (stacked on fix/review-findings-2, not pushed: owner said local only). All scenarios pass locally against receiver.exe (MSYS2 MINGW64). Fixture needs open-gop=0 (the plan command gave CRA, not IDR). Receiver stdout made unbuffered. CI not run |
| T0.6 | test/receiver-e2e-faults | S | T0.5 | G1 | DONE-PENDING-MERGE | 2026-11-26 | Same branch as T0.5. stall_timeout stalls mid-frame (a between-frame 7 s stall is under the 15 s header timeout). Added soak (memory + handles). All pass locally; CI not run |
| T0.7 | test/ios-sender-socket-test | S | T0.1 | — | DONE | 2026-11-25 | Swift test unverified locally; CI macOS must confirm |
| T0.8 | chore/docker-receiver-cross-build | O | T0.2 | G2 | TODO | | optional |
| T1.1 | diag/ios-disconnect-reasons | S | T0.0 | — | DONE | 2026-11-25 | Merged to main; Swift build unverified locally, CI macOS must confirm |
| T1.2 | fix/ios-listener-reuse | S | T0.7 | — | DONE | 2026-11-25 | C6 unverified locally (CI macOS); stacked on T0.7 branch |
| T1.3 | fix/ios-recovery-keeps-connection | S | T1.2 | — | DONE | 2026-11-25 | C7 unverified locally; stacked on T1.2 |
| T1.4 | fix/ios-path-monitor-guard | S | T1.2 | — | DONE | 2026-11-25 | stacked on T1.3 |
| T1.5 | fix/ios-light-foreground-resume | S | T1.3 | — | DONE | 2026-11-25 | also fixes a mis-encoded bullet in the T1.3 string; stacked |
| T1.6 | fix/ios-drop-to-keyframe | S | T1.3 | — | DONE | 2026-11-25 | C8 unverified locally; stacked |
| T1.7 | fix/ios-max-frame-guard | H | T1.6 | — | DONE | 2026-11-25 | Guard on StreamHeader.maxFrameSize; parity + Swift test; CI must run Swift tests |
| T1.8 | fix/receiver-fast-reconnect | H | T0.6 | — | DONE-PENDING-MERGE | 2026-11-26 | Stacked on test/receiver-e2e-harness; not pushed. e2e disconnect gap 1.118 s -> 0.336 s locally (limit 1.5 s); no contract pinned the old message. CI not run |
| T1.9 | fix/receiver-console-quickedit | H | T0.0 | — | DONE | 2026-11-25 | receiver link unverified locally; CI must confirm |
| T1.10 | docs/usb-troubleshooting | H | T0.0 | — | DONE | 2026-11-25 | Docs only; facts checked against connect_to_device order |
| DC-1 | (owner) | — | T1.1–T1.10 | — | TODO | | |
| T2.1 | diag/receiver-timing-stats | S | T0.0 | — | DONE | 2026-11-25 | Merged only after branch CI green (C++ tests + link verified in CI) |
| T2.2 | diag/ios-latency-telemetry | S | T1.6 | — | DONE | 2026-11-25 | Merged only after branch CI green (Swift build + sender tests verified in CI) |
| T2.3 | docs/obs-latency-and-av-sync | H | T2.1, T2.2 | — | DONE | 2026-11-25 | Docs only; no measured numbers yet (needs a device) |
| DC-2 | (owner) | — | T2.1–T2.3 | — | TODO | | decides G3/G5/G6 |
| T2.4 | perf/ios-encoder-latency | S | DC-2 | G3 | TODO | | |
| T2.5 | fix/relay-arrival-timeline | S | T2.1, T0.6 | G5 | DONE-PENDING-MERGE | 2026-11-26 | Stacked on fix/receiver-fast-reconnect; not pushed. New e2e drift (phone clock 1% fast): PTS vs arrival moved 179.6 ms before, 0.04 ms after; burst min offset -299 ms -> 0 ms. BeginSession removed (contract pin changed with reason). CI not run; DC-2 30-min repeat open |
| T2.6 | feat/relay-tcp-output | O | DC-2 | G6 | TODO | | optional; mini-plan first |
| T2.7 | perf/ios-idle-encoder-pause | S | T1.6 | G4 | TODO | | |
| T3.1 | feat/ios-wifi-mode | S | T1.4, T0.4 | G7 | DONE | 2026-11-26 | Merged locally, CI not run (owner instruction). Later verified: main CI green at 77cd013 (app built, Swift tests passed). Unverified: usbmux still reaches the listener with Wi-Fi off, and the Personal Hotspot USB fallback (DC-3); AC3 CI |
| T3.2 | feat/ios-wifi-bitrate | S | T3.1 | G8 | SKIPPED | 2026-11-25 | superseded by T5.4 + T5.8 |
| T3.3 | feat/wifi-discovery | O | T3.1 | G7 | DONE | 2026-11-26 | Merged locally, CI not run (owner instruction). Mini-plan: docs/plan/T3.3-wifi-discovery.md. receiver links locally (MSYS2 g++), wifi_discovery_test passes; Bonjour browse verified against a local mDNS registration. UNVERIFIED: address resolve (this PC does not answer queries for its own registration) and the Swift change; AC4 CI, AC5 device |
| DC-3 | (owner) | — | T3.1 | — | TODO | | T3.2 SKIPPED |
| T4.1 | chore/retire-gpu-ring | S | T0.6 | G9 | TODO | | optional |
| T4.2 | docs/soak-signoff | H | soak | — | TODO | | |
| T5.0 | diag/ios-nwerror-detail | H | — | — | DONE | 2026-11-26 | Merged without CI (owner instruction). Swift build + stream_sender_test unverified; CI macOS must confirm |
| T5.1 | ci/xcode-26-sdk | H | — | — | DONE | 2026-11-26 | Merged without CI (owner instruction). Unverified: runner SDK is 26 on macos-15 (else switch to macos-26); API-name step output still to be copied for T5.9/T5.10 |
| T5.2 | diag/ios-capability-probe | S | T5.1 | — | DONE | 2026-11-26 | Swift not compiled locally; CI not run. Unverified: AVFoundation property names (esp. isCinematicVideoCaptureSupported, iOS 26 SDK); AC3 = DC-4 on device |
| DC-4 | (owner) | — | T5.2 | — | TODO | | decides G10/G11/G12 |
| DC-5a | (owner) | — | T5.0, T3.1 | — | TODO | | USB vs Wi-Fi A/B |
| T5.4 | feat/ios-quality-presets | S | T3.1, T5.5 | G8′ | DONE | 2026-11-26 | Merged locally, CI not run (owner instruction). Later verified: main CI green at 77cd013. 183 code lines. AC2 CI; AC5-AC7 device (DC-5a/DC-5b) |
| T5.5 | feat/receiver-resolution-follow | S | — | — | DONE | 2026-11-26 | hevc_sps_test + receiver link verified locally (MSYS2 g++); Merged without CI (owner instruction). AC3 (e2e 1080p->720p, needs G1) and AC4 (DC-5b device) open |
| T5.8 | feat/ios-adaptive-bitrate | S | T5.4 | G14 | DONE | 2026-11-26 | Merged locally, CI not run (owner instruction). Later verified: main CI green at 77cd013 (quality_advisor_test passed). Review fix (fix/review-findings-2): drops and queue wait now come from the sender's 2 s timer, so a stalled link is seen. Plan fix: property is retransmittedTransportByteCount. AC3/AC4 device (DC-5b) |
| T5.7 | feat/ios-quality-advisor | S | T5.8 | — | DONE | 2026-11-26 | Merged locally, CI not run (owner instruction). Later verified: main CI green at 77cd013. AC2 device (DC-5b) |
| DC-5b | (owner) | — | T5.4, T5.5, T5.7, T5.8 | — | TODO | | decides G13 |
| T5.6 | feat/receiver-constant-latency | O | T5.5, DC-5b | G13 | TODO | | |
| T5.9 | feat/ios-cinematic-mode | O | T5.4, DC-4 | G11 | TODO | | 30 fps only |
| T5.10 | feat/ios-portrait-effect | S | T5.4, DC-4 | G12 | TODO | | Portrait only; never 4K |
| T5.11 | docs/wifi-presets-effects | H | T5.0–T5.10, T3.3 | — | TODO | | deps may be SKIPPED |
| DC-6 | (owner) | — | T5.11 | — | TODO | | |

---

## 10. Device test log

| Date | Checkpoint | App build (CI run) | Receiver build | Result | Numbers (latency ms, reconnects, thermal) | Notes |
|---|---|---|---|---|---|---|
| | | | | | | |

---

## 11. Plan change log

| Date | Change | By |
|---|---|---|
| 2026-11-25 | Initial plan from code review of `f657cdd` | Claude (Opus) |
| 2026-11-25 | Added Phase 5 (STREAMER_FEATURES_PLAN.md): Wi-Fi presets, advisor, constant latency, Cinematic, effects. G8 → G8′; T3.2 superseded; new gates G10–G14 | Claude (Opus), at owner's request |
| 2026-11-25 | Owner device is iPhone 14 Pro. G11 (Cinematic 30 fps) and G12 (Portrait only, front-camera fallback) approved; T5.10 renamed `feat/ios-portrait-effect` | Claude (Opus), owner decision |
| 2026-11-25 | STREAMER_FEATURES_PLAN.md reviewed for executor clarity: identifiers verified at `2e7086b`; added executor quick start (§0), exact code shapes, contract lines and stop conditions; T5.4 now needs T5.5; T5.2 probes front cameras; SPS golden vectors embedded; rule 0.2 says SKIPPED satisfies a dependency | Claude (Opus), at owner's request |
