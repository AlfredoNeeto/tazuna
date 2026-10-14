---
name: fix-bug
description: Fixes a reported bug at its root cause, with evidence - reproduces it with a failing test first, traces every caller of what it changes, fixes it once, shows the same test failing before and passing after, and runs the project's verification. Use when the user reports a bug, a regression, a failing test or wrong behaviour ("fix", "it breaks when", "bug", "regression"). Do NOT use for new features or refactors.
---

# Fix a bug

A report names a symptom. The bug is fixed when a test that reproduced the symptom passes and
the project's verification passes, not when the code looks right.

## Steps

1. **Reproduce.** Write the smallest test that fails the way the report says, where the
   project keeps its tests. Run it and keep the failing output. If it does not fail, the bug
   is not understood yet: narrow it down or ask for the missing input. Do not fix blind.
   Where no test can reach that layer, reproduce with a command or script, keep its output,
   and say so.
2. **Find the root cause.** Trace from the failing assertion back to the first wrong value.
   Before editing a function, list every caller of it. A guard in the shared function fixes
   all of them; a guard in one caller leaves the others broken.
3. **Fix it once**, where every caller routes through, with the smallest change that makes the
   test pass. No refactoring the fix does not need.
4. **Prove it.** Run the reproducing test again, now passing, and the project's verification
   (`.\.claude\scripts\verify.ps1` where Tazuna is installed). Never weaken, skip or delete a
   test to make it pass.
5. **Report** the symptom, the root cause at `path:line`, the fix, the test, its output before
   and after, and the verification result. Say what you could not verify.

When the fix touches security, money, data or a public contract, run `/review-change` after it.
