---
name: change-review
description: Critical, severity-ranked review of a diff in the iPhone→Windows OBS streaming repo, covering correctness against acceptance criteria, recovery and concurrency semantics, untrusted-input handling, 4K60 hot-path cost, architecture, tests, and unintended changes. Use before declaring any change complete, or when asked to review a diff or PR.
---

# Change Review

## Purpose
Find real defects before the user does. The default stance is skeptical: nothing is approved
without evidence. This skill covers the repository-specific checklist. For a generic deep bug
hunt, the built-in `/code-review` may be used in addition.

## Activate when
- Step 6 of `implement-change`.
- The user asks for a review of local changes, a branch, or a PR.

## Workflow
1. **Collect the full change.** Run `git status --short` and `git diff`, and read untracked files.
   Every hunk must trace to an acceptance criterion or a required touch-point. Anything else is
   an **unintended change**.
2. **Review each hunk against this checklist** and skip items that don't apply.
   - **Correctness:** Does it meet each AC? Check off-by-one, unsigned underflow, integer
     narrowing (`UInt32(frame.count)`, `static_cast<int>(frame_size)`), and endianness.
   - **Recovery (R-ENG-RECOVER):** After every new discontinuity path, are delta frames gated
     until the join point, on **both** sides? Are generation counters bumped so stale completions are dropped?
   - **Concurrency (R-ENG-CONC):** Is new mutable state confined to its queue or lock? Are there
     `[weak self]` captures, UI work on main, lock-order or re-entrancy hazards, or `NSLock` held
     across a callback?
   - **Untrusted input (R-ENG-INPUT):** Are headers validated before allocation? Is every length
     bounded? Is a packed struct ever cast from the wire?
   - **Errors (R-ENG-ERR):** Is every failure logged with a prefix and handled? Can the receiver
     exit or hang (blocking call without a timeout) on a stream or OBS failure? Are FFmpeg and Win32
     resources freed on every path?
   - **Performance (R-ENG-PERF):** Is there new per-frame allocation, copying, logging, disk I/O,
     or unbounded growth on the 4K60 path?
   - **Security (R-ENG-SEC):** Are there new listeners, non-loopback outputs, or secrets in code or CI?
   - **Architecture:** Defer to `architecture-alignment` (after) and include its verdict.
   - **Tests (R-ENG-TEST):** Is new behavior covered? Did any contract assertion get weakened or removed,
     and if so, is that justified? Is the test wired into CI and `check.sh`?
   - **Maintainability:** Is the change minimal? Are there speculative abstractions, dead code, or
     duplicated constants? Do names and style match (R-ENG-STYLE)?
   - **Docs (R-ENG-DOCS):** Are user-visible flag, port, or setup changes reflected in the docs?
3. **Verify every finding** before reporting it. Re-read the exact lines and construct the
   concrete failing scenario. Drop anything you cannot substantiate.
4. **Rank** the findings:
   - **Critical:** data loss, crash or exit of the receiver, security exposure, broken wire compatibility.
   - **High:** an AC not met, a recovery or concurrency bug, a new architecture violation, a missing test for new behavior.
   - **Medium:** an edge case, a resource leak on a rare path, a hot-path cost.
   - **Low:** style, naming, docs.
   Mark issues that predate the change as **pre-existing**. They don't block, but report them.

## Constraints
- Never approve because the checks pass. Checks and review are independent.
- Never approve with an open Critical or High finding.
- Device-only behavior is "unverified", never "works".
- Report, don't fix, unless this review runs inside `implement-change`, which owns the fixes.

## Output
```
Verdict: APPROVE | CHANGES REQUIRED | BLOCKED (needs human decision)
[Critical|High|Medium|Low] file:line — defect — failing scenario — suggested fix
…
Unintended changes: none | …     Pre-existing issues noticed: …
AC coverage: AC1 ✅ … AC2 ⚠ unverified (device) …
```
