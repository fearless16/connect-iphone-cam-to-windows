---
name: architecture-alignment
description: Evidence-based check that a planned or completed change in the iPhone→Windows OBS streaming repo respects module ownership, dependency direction (R-ARCH rules), contracts, and recovery semantics. Mandatory before and after any non-trivial change, new file, moved code, or new dependency.
---

# Architecture Alignment

## Purpose
Keep every change inside the established architecture: `CLAUDE.md` module map plus the
R-ARCH and R-ENG rules in `docs/ENGINEERING_RULES.md`. Detect drift, and separate new
violations from existing debt (D1–D10).

## Activate when
- **Before:** step 3 of `implement-change`, once you know the owner and the criteria.
- **After:** step 6, on the actual diff.
- Again, whenever the implementation approach changes mid-task.

## Workflow: before
Answer each question with **evidence** (a `file:line`, a rule ID, or contract output). Never answer from intuition alone.

1. **Does this belong here?** Compare against the module map and "Where new functionality
   belongs". Pure logic → a standalone unit (R-ARCH-4). UI → never touches the transport (R-ARCH-3).
2. **Do dependencies flow correctly?** List every new `import` or `#include`. Each must be in the
   owner's "May depend on" column. Nothing supported may import archived code (R-ARCH-5/6).
3. **Are boundaries and contracts preserved?** Check the wire format (R-ARCH-2), the
   keyframe/join semantics on **both** sides (R-ENG-RECOVER), header validation (R-ENG-INPUT),
   the timestamp clock (R-ENG-TIME), and the contracts that pin the touched code.
4. **Is there unnecessary coupling, duplication, or complexity?** Look for:
   - a new cross-module callback
   - a second copy of protocol constants
   - logic duplicated across Swift and C++ when one side should own it
   - new state without a confining queue or lock (R-ENG-CONC)
   - per-frame cost (R-ENG-PERF)
5. **Is it consistent with existing patterns?** Name the existing example being followed.

If any answer is "no", propose the **smallest** correction before implementing. If the
correction is a human-judgment item, stop and ask.

## Workflow: after
1. Run `sh tests/architecture_boundary_contract.sh` and `sh tests/protocol_parity_contract.sh`.
2. Inspect new dependencies in the diff:
   `git diff -U0 | grep -E '^\+\s*(#\s*include|import )'`
   For new files, use `git status --short`. Each new file must sit where the module map says.
3. Re-answer questions 1–5 against the **diff**, not the plan.
4. Classify every finding:
   - **New violation**, introduced by this change. Must be fixed before completion.
   - **Existing debt**, already listed as D1–D10 or present before the change. Report it; don't
     fix it unless that is the task.
   - **New debt worth recording.** Propose a row for the debt table in `docs/ENGINEERING_RULES.md`.
5. If a rule should be machine-enforced and is not, propose an assertion in
   `architecture_boundary_contract.sh` (see `quality-gates`).

## Constraints
- "Aligned" requires evidence: boundary contract output plus `file:line` references.
- Don't refactor existing debt opportunistically. Minimal correction only.
- Don't invent new layers or abstractions to satisfy this checklist.

## Output
```
Architecture alignment (before|after): ALIGNED | DRIFT | BLOCKED (needs human decision)
Q1 placement     …  evidence: …
Q2 dependencies  …  evidence: …
Q3 contracts     …  evidence: …
Q4 coupling      …  evidence: …
Q5 consistency   …  evidence: …
New violations: … | none     Existing debt touched: D… | none     Correction: …
```
