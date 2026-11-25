---
name: repo-exploration
description: Locate the owning module, callers, existing patterns, and the tests/contracts that pin a piece of code in this iPhone→Windows OBS streaming repo, without scanning everything. Use before changing code, when asked "where does X live / what uses X", or before renaming any identifier.
---

# Repository Exploration

## Purpose
Gather just enough context to change code safely. That means four things: the owning module,
its callers, the pattern to reuse, and every test or contract that pins it.

## Activate when
- Starting any code change (step 1 of `implement-change`).
- You need to find a symbol, a flow, or the impact of a change.
- **Before renaming or removing any identifier or log string.** Source contracts grep for them.

## Workflow
1. **Map first.** Use the `CLAUDE.md` module map and "Where new functionality belongs" to name
   the candidate owning file. Don't list directories you already know.
2. **Locate the symbol.** Use bounded searches scoped to one side:
   - Swift definitions: Grep `func <name>|var <name>|class <Name>` in `ios/` or `shared/`.
   - C++ definitions: Grep `<name>\(|class <Name>` in `windows/` or `protocol/`.
   - Outline a large file: Grep `^\s{4}(private )?func ` in `ios/CameraStreamer.swift`, or
     `^static |^class ` in `windows/receiver.cpp`. Then Read with `offset`/`limit`.
3. **Trace dependencies one hop at a time.**
   - Swift: callers of the symbol across `ios/` and `shared/`. Callbacks are wired through
     `onStatus`, `onClientConnected`, `onConnectionState`, and `onFrameRate`.
   - C++: `#include "` lines in the file and the reverse, Grep `#include "<header>"`.
4. **Find what pins it.** This step is mandatory.
   - `Grep '<identifier or log text>' tests/` shows every contract or test that will break.
   - `Grep 'tests/<file>' .github/workflows/build.yml scripts/check.sh` shows where a test runs.
5. **Check cross-side impact.** The iPhone and Windows sides share state through these channels:
   - Header fields, magic, size, codec, and port: `protocol/` + `shared/` + both senders and receivers
   - Timestamps: `CameraStreamer.nextProtocolTimestampUs` ↔ `RelayTimestampClock`
   - Keyframe/join semantics: `StreamSender.waitingForKeyFrame` ↔ `waitingForRandomAccess` /
     `RelayRecoveryGate`
   - Orientation/dimensions: `camera_orientation_timestamp_contract.sh` reads both sides
6. **Find the pattern to reuse.** Locate the closest existing example, such as a pure unit plus
   its test, a recovery path, or a contract. New code copies its shape.
7. **Stop** when you can answer all four items in Purpose. More reading is waste.

## Constraints
- Skip `third_party/`, `assets/`, `*.xcassets`, archived code (R-ARCH-6), and binary files.
- Never read `CameraStreamer.swift` or `receiver.cpp` whole. Outline them, then read ranges.
- Prefer Grep/Glob over shell `find`/`cat`. Use `head_limit` on broad searches.
- Don't re-read content already in context.

## Output
A short context note that later steps reuse:
```
Owner: <file> (<module>)          Pattern to reuse: <file:line>
Callers/deps: <file:line, …>      Cross-side impact: none | <channel>
Pinned by: <tests/…sh:line, tests/…_test.*>   Runs in: CI <job>, check.sh
```
