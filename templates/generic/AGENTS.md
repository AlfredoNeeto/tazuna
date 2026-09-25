# Project Guide

Only what the code does not already show. Conventions the repository demonstrates are not
repeated here: read the code.

## Verification

```powershell
.\.claude\scripts\verify.ps1
```

Runs this project's build and test steps and checks the diff for whitespace damage. Prints
`VERIFICATION PASSED` or `VERIFICATION FAILED` and exits non-zero on failure.

A task is not complete while it fails. If it fails for reasons unrelated to your change, name
the failures rather than working around them. Never weaken a test, suppress a warning, or
narrow the verification to make it pass.

> If it reports that no verification steps are defined, populate `$VerificationSteps` in
> `.claude\scripts\verify.ps1` with the real build and test commands before relying on it.

## tlc-spec-lean

profile: standard
budget: 150k

## tlc-implement

profile: standard

## Project rules

<!-- Domain rules, non-obvious architecture, the testing strategy, security constraints:
     only what an agent could not infer from the code. Delete this section if there are none. -->
