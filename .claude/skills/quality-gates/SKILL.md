---
name: quality-gates
description: Run, interpret, and extend the deterministic quality gates of the iPhone→Windows OBS streaming repo (scripts/check.sh, CI workflow, source contracts, runtime tests, boundary/parity/registry contracts). Use when validating a change, when a check fails, or when adding or modifying a test or gate.
---

# Quality Gates

## Purpose
Prove a change with deterministic checks, and grow those checks so that rules are
machine-enforced instead of written down.

## Activate when
- Step 5 or 6 of `implement-change` (validate).
- A check fails locally or in CI.
- Adding or modifying a test, a contract, or a CI step.

## Gate inventory

| Gate | What it proves | Where it runs |
|---|---|---|
| `tests/architecture_boundary_contract.sh` | R-ARCH-1..7 dependency direction | check.sh, CI (Windows job) |
| `tests/protocol_parity_contract.sh` | C header ↔ Swift mirror ↔ port parity | check.sh, CI |
| `tests/test_registry_contract.sh` | Every test runs in CI **and** check.sh; shell hygiene (no bare `! grep`: `set -e` ignores it, so write "must not contain" checks with `forbid` or `if … then exit 1`); no `NDEBUG` | check.sh, CI |
| `tests/windows_ci_contract.sh` | CI composition; archived prototypes stay out of CI | check.sh, CI |
| `tests/*_source_contract.sh`, `*_contract.sh` | Platform-bound behavior pinned by identifiers | check.sh, CI |
| `tests/*_test.cpp` | Protocol, relay clock, recovery gate, HEVC join-point logic | CI; check.sh if g++/clang++ |
| `tests/*_test.swift` | Annex-B conversion, CMBlockBuffer, Swift header golden vector | CI (macOS); check.sh if Xcode |
| `tests/app_icon_contract.ps1` | 1024², opaque app icon | CI; check.sh on Windows with pwsh |
| `receiver.exe` link, `xcodebuild` | Full product builds | **CI only** |

## Workflow: validate
1. Run `sh scripts/check.sh`. The exit code is 0 only when nothing FAILed.
2. For each FAIL, rerun the printed command with `sh -x` to see the exact failing `grep`.
   Decide which side is wrong:
   - **The code broke the contract.** Fix the code.
   - **The contract pins an intentionally changed identifier.** Update the assertion to the new
     identifier in the same change, and state why. Do not delete it.
3. Record every SKIP. Each SKIP is a check that is **unverified** locally and that CI must
   confirm. Name them in the final report.
4. Never claim CI passed unless you saw the run result.

## Workflow: add a test or gate
1. Choose the form.
   - Extractable logic gets a **runtime test**, which is preferred. Extract it into an R-ARCH-4 unit first.
   - Logic bound to AVFoundation, VideoToolbox, Network, FFmpeg I/O, or Winsock gets a
     **source contract**, which greps for the identifiers and structure that encode the behavior.
     Add a comment saying *why* each non-obvious assertion exists, as the existing contracts do.
2. Follow R-ENG-TEST:
   - `#!/usr/bin/env sh` and `set -eu`
   - file paths as arguments with defaults
   - `tr -d '\r'` before parsing
   - `@main struct` for Swift tests
   - `assert` with no `NDEBUG` for C++
3. Wire the test into `.github/workflows/build.yml` (the correct job and step) **and**
   `scripts/check.sh` (in the matching section, with a literal `tests/<file>` path). Add C++
   tests for `windows/` code to CTest in `windows/CMakeLists.txt` too.
   `test_registry_contract.sh` fails until both are done.
4. Prove the gate can fail. Apply a deliberate violation in a scratch copy, not in the
   working tree, and confirm a FAIL with a clear message. Then confirm the clean tree passes.
5. A test for an archived prototype goes in the `archived` list of `test_registry_contract.sh`,
   with a reason, and never into CI.

## Constraints
- Never suppress, skip, or weaken a check to get green.
- Don't add linters, formatters, or toolchains without approval (R-ENG-DEPS, D9).
- Keep `check.sh` mirroring CI. It runs the same commands, never a weaker variant.

## Output
```
check.sh: P pass / F fail / S skip
FAIL: <gate> — cause — fix applied
SKIP (unverified locally, CI must confirm): <list>
Gates added/changed: <file> — proven to fail on: <mutation>
```
