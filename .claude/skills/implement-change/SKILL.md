---
name: implement-change
description: The mandatory end-to-end workflow for any change to product code, tests, CI, or build files in the iPhone→Windows OBS streaming repo. Orchestrates repo-exploration, acceptance-criteria, architecture-alignment, quality-gates, and change-review, and lists the repo's file touch-points (Xcode project, CMake, CI, check.sh, docs).
---

# Implement Change

## Purpose
Deliver the smallest complete, verified change. Every step below is required. Steps scale
with the size of the task, but none is skipped.

## Activate when
Any modification to `ios/`, `shared/`, `protocol/`, `windows/`, `tests/`, `scripts/`,
`.github/`, or the Xcode/CMake files. For docs-only edits, follow R-ENG-DOCS and skip to step 7.

## Workflow
**Before implementation**
1. **Explore.** Run `repo-exploration` to get the owner, callers, the pattern to reuse, and what pins the code.
2. **Specify.** Run `acceptance-criteria`. Ask the user about material ambiguity. Record your assumptions.
3. **Align.** Run `architecture-alignment` (before). If the result is BLOCKED, stop and ask.

**During implementation**
4. **Implement.**
   - Copy the shape of the pattern found in step 1. Follow R-ENG-STYLE, R-ENG-ERR, and R-ENG-CONC.
   - Change only what the criteria require. No drive-by refactors, renames, reformatting,
     speculative options, or abstractions with a single user.
   - Update every **touch-point** the change requires (table below), in the same change.
   - If the approach changes, re-run `architecture-alignment` (before) on the new approach.
5. **Test.** Add or extend tests per R-ENG-TEST, using `quality-gates` for how. A behavior
   change without a test or contract assertion is incomplete.

**Before completion**
6. **Validate and review.**
   - Run `sh scripts/check.sh` (`quality-gates`).
   - Run `change-review` on the full diff (`git diff` plus untracked files).
   - Run `architecture-alignment` (after).
   - Fix every new violation, then re-run `check.sh`.
7. **Report** (format below). Verify each criterion. List every SKIPped or unexecuted check.

## Touch-points

| Change | Also update |
|---|---|
| New Swift file in the app | `ios/iPhoneCameraStream.xcodeproj/project.pbxproj`, in 4 places: `PBXBuildFile`, `PBXFileReference`, the `PBXGroup` children, and `PBXSourcesBuildPhase`. Follow the `LengthPrefixedHEVC.swift` entries, with the next unused `2A…`/`3A…` IDs |
| New `.cpp` in `receiver.exe` | the `receiver` target in `windows/CMakeLists.txt`, the `g++` line in `build.yml` (Windows job), and `scripts/build_windows.sh` |
| New test file | `build.yml` **and** `scripts/check.sh`. For C++ tests under `windows/`, also CTest in `windows/CMakeLists.txt` |
| Renamed or removed identifier or log string | every contract that greps it (`Grep '<text>' tests/`) |
| Wire-format change (approved) | `protocol/stream_protocol.h`, `shared/StreamHeader.swift`, both golden vectors, `protocol_parity_contract.sh`, sender + receiver, `docs/architecture.md` table |
| CLI flag, port, OBS setting, or setup step | `README.md`, `docs/QUICKSTART.md`, `OBS-SETUP.md`, `docs/BACKDOOR.md` as applicable |
| New rule or boundary | `docs/ENGINEERING_RULES.md`, plus an assertion in `architecture_boundary_contract.sh` when it can be checked |

## Constraints
- Never weaken, delete, or `!`-invert a contract assertion to get green (R-ENG-TEST).
- Never edit `third_party/` or archived code, and never add dependencies, without approval.
- Never commit or push unless the user asks.

## Output: final report
```
Change: <one line>                    Files: <list>
Criteria: AC1 ✅ (evidence) · AC2 ⚠ device verification required · …
Checks: check.sh N pass / 0 fail / K skip (list skips) · CI-only: <what CI must confirm>
Review: <change-review verdict; open findings>   Alignment: <after verdict>
Risks / follow-ups: …
```
