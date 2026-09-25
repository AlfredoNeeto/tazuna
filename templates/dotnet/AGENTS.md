# Project Guide

Only what the code does not already show. Conventions the repository demonstrates are not
repeated here: read the code.

## Verification

```powershell
.\.claude\scripts\verify.ps1
.\.claude\scripts\verify.ps1 -Configuration Release
.\.claude\scripts\verify.ps1 -Target .\src\MyApi\MyApi.csproj
.\.claude\scripts\verify.ps1 -SkipTests      # only for a deliberately build-only change
```

Discovers the solution or project, restores, builds, runs the tests, and checks the diff for
whitespace damage. Prints `VERIFICATION PASSED` or `VERIFICATION FAILED` and exits non-zero on
failure.

It picks its own toolchain: the dotnet CLI for SDK-style projects, and Visual Studio's MSBuild
with `vstest.console` when the repository contains a .NET Framework project, which the dotnet
CLI cannot restore, build or test. The Framework path needs Visual Studio or the Build Tools;
the script says so by name when they are missing.

A task is not complete while it fails. If it fails for reasons unrelated to your change, name
the failures rather than working around them. Never weaken a test, suppress a warning, or
narrow the verification to make it pass.

## tlc-spec-lean

profile: standard
budget: 150k

## tlc-implement

profile: standard

## Project rules

<!-- Domain rules, non-obvious architecture, the testing strategy, security constraints:
     only what an agent could not infer from the code. Delete this section if there are none. -->
