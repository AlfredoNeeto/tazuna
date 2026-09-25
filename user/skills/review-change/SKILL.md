---
name: review-change
description: Reviews a completed change with independent reviewer subagents, one per lens - correctness, security, architecture and scope, tests - then keeps only findings that survive a re-read of the code. Use before accepting work - after the tlc Verifier's report when the work had a spec.
---

# Review a change

Functional correctness against the checks is the tlc Verifier's job
(`.specs/features/<feature>/verification.md`). This looks for what checks do not:
regressions, security, scope drift, unnecessary abstractions, weak tests. The reviewers are
`reviewer` subagents, so none of them saw the change being written.

## Steps

1. **Size it.** `git diff --stat`, plus untracked files. Choose lenses by risk, not ritual:
   - small, low risk: one `reviewer` with all four lenses;
   - otherwise: one `reviewer` per lens, **launched in parallel** in a single message —
     `correctness`, `security`, `architecture`, `tests`. Drop a lens that cannot apply (no
     trust boundary touched → no security reviewer) and say you dropped it.

   Give each reviewer its lens, the diff range or "the working tree", and the paths of
   `.specs/features/<feature>/plan.md` and `checks.md` if they exist. Nothing else — not
   your reasoning about the change.

2. **Confirm each finding.** Re-read the cited code. Keep a finding only with evidence;
   dismiss one only with a stated reason, never because you wrote the code. A blocking finding
   that can be reproduced with a failing test is stronger for it.

3. **Report** the surviving findings, most severe first, then a verdict — **accept**,
   **accept with fixes**, or **reject** — in one line. Say which lenses ran.

Do not fix anything as part of the review. Fixing is the next step, and re-running
the Verifier after it when the work had a spec.

## The human's part

Point the user at what a human should still read: architectural direction, critical logic,
sensitive business rules, anything unexpected in the diff. The review narrows that reading; it
does not replace it.
