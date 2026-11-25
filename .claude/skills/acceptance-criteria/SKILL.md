---
name: acceptance-criteria
description: Turn a feature request or bug report for the iPhone→Windows OBS streaming repo into specific, verifiable acceptance criteria: behavior, preserved behavior, edge and failure cases, and a definition of done mapped to checks. Use before implementing, or when a requirement is ambiguous.
---

# Acceptance Criteria

## Purpose
Make "done" checkable before any code is written, and map every criterion to the check
that will prove it.

## Activate when
- Step 2 of `implement-change`, for any feature, fix, or behavior change.
- A request is vague ("make it more stable", "support 1080p", "fix the lag").

## Workflow
1. **Restate the goal** in one sentence, with scope: iOS, receiver, CI, docs, or both sides.
2. **Resolve ambiguity.**
   - **Ask the user** if the request touches a human-judgment item (`docs/ENGINEERING_RULES.md`,
     last section), or if two reasonable readings would produce different behavior.
   - Otherwise, choose the reading most consistent with existing behavior and record it as an
     **Assumption**.
3. **Write the criteria** using the template below. Every line must be observable.
4. **List what must be preserved.** Pick the invariants this change could affect (see
   `CLAUDE.md` → Invariants), plus the contracts found by `repo-exploration`.
5. **Walk the edge and failure checklist** and keep only the items that apply:
   - iPhone app backgrounded or locked, then foregrounded; USB unplugged or replugged mid-stream
   - receiver started before the app, or the app restarted while the receiver runs
   - OBS not started or closed (relay write failures → `relayDrop`, no exit)
   - corrupt or oversized header, unsupported codec, truncated frame
   - encoder rebuild, non-4K or non-60fps format fallback, thermal or system-pressure state change
   - orientation switch (landscape ↔ portrait dimensions)
   - timestamp regression or restart across sessions
   - Windows CRLF checkout (shell contracts)
6. **Map each criterion to a verification**: a runtime test, a contract assertion,
   `check.sh`/CI, or **device verification required**. An agent cannot run the phone or OBS.
   Say so; never imply otherwise.

## Template
```
Goal: …                         Scope: ios | windows | protocol | ci | docs
Assumptions: …
Behavior:
  AC1 Given … when … then …                         → verify: tests/…  | contract | device
Preserve:
  P1 <invariant / existing behavior>  (R-…)           → verify: …
Edge/failure:
  E1 …                                                → verify: …
Out of scope: …
Done when: all AC/P/E verified or explicitly marked unverified; check.sh has no FAIL;
           docs updated if R-ENG-DOCS applies; change-review shows no open Critical/High.
```

## Constraints
- No criterion like "works correctly". Each one names an input, an action, and an observable result.
- Keep it proportional: a one-line fix gets 1–3 criteria, not the whole template.
- Don't expand scope. Record extra ideas under "Out of scope".

## Output
The filled template. It is the checklist that `change-review` and the final report verify.
