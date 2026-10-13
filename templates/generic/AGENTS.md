# Project Guide

Only what the code does not already show. Conventions the repository demonstrates are not
repeated here: read the code.

## Verification

```powershell
.\.claude\scripts\verify.ps1
```

Finds every buildable part of the repository, wherever its manifest sits - .NET and .NET
Framework, Flutter and Dart, Node (npm, pnpm, yarn or bun), Python, Go, Rust, Maven, Gradle,
Make - runs its build, analysis and tests from its own directory, and checks the diff for
whitespace damage. A step whose tool is not installed is skipped by name; a run that skipped
everything fails. Prints `VERIFICATION PASSED` or `VERIFICATION FAILED` and exits non-zero on
failure. On sources that already passed it reports that pass at once; `-Force` runs it again.

A task is not complete while it fails. If it fails for reasons unrelated to your change, name
the failures rather than working around them. Never weaken a test, suppress a warning, or
narrow the verification to make it pass.

> If it reports `Nothing to verify`, or detects the wrong commands, populate `$VerificationSteps`
> in `.claude\scripts\verify.ps1` with the real build and test commands; an explicit list
> replaces detection.

## tlc-spec-lean

profile: standard
budget: 150k

## tlc-implement

profile: standard

## Project rules

<!-- Domain rules, non-obvious architecture, the testing strategy, security constraints:
     only what an agent could not infer from the code. Delete this section if there are none. -->
