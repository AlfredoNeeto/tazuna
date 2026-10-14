# Working on the harness

This repository is a Claude Code engineering harness: it sets up a Windows machine for Claude
Code and Cursor on top of harness-toolkit and the agent-skills catalog. Projects get their gate
from harness-toolkit, and so does this one.

## Verification

```powershell
.\scripts\test-harness.ps1
```

That is the self-test, also `tazuna test`. It prints `HARNESS SELF-TEST PASSED` or
`HARNESS SELF-TEST FAILED` and exits non-zero on failure. Run it after changing anything here.

The self-test is one file per area, `scripts\tests\<Area>.Tests.ps1`, all run at once, each in
its own process. A file dot-sources `TestKit.ps1` (helpers, shared fixtures) and ends with
`Complete-TestFile`; a new `*.Tests.ps1` needs no registration. `-Only <id>` runs the matching
cases in every file and fails when none ran.

The gate that runs it when a turn ends is harness-toolkit's grind. Only the owner sets it, from
a terminal outside the agent, because agents cannot write the toolkit's policy:

```powershell
tlc harness gate test-command powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/test-harness.ps1 -SkipSlow
tlc harness grind on
```

plus `"appendFiles": "never"` under `grind` in the project's toolkit config: appended file paths
would reach `test-harness.ps1` as arguments.

**A component is not implemented because a file with the right name exists.** Prove the
behaviour: run it, assert the exit code, and assert the failure case too. A test that only
checks "did not crash" passes while the thing it guards silently never fires.

## Where things go

| Content | Location | Loaded |
|---|---|---|
| Rules true for *most* projects | `user/` | every session, everywhere |
| Harness tooling | `scripts/` | on invocation |
| Shared helpers for that tooling, one module per reason to change | `scripts/lib/` | leaf modules: no `Import-Module` inside, no `Write-Host` outside `Console.psm1`; each script must import `lib\<Area>.psm1` itself for every function it calls |
| What setup installs, its pins, and what 1.x installed that 2.0 removes | `scripts/lib/Manifest.psm1` | by setup, doctor and init |

`tazuna.ps1` dispatches to a command in `scripts/`, the command orchestrates, and `scripts/lib/`
does the work. The self-test fails a script that imports a module it does not call, or calls one
it does not import.

Nothing project-specific belongs in `user/`. A rule about EF Core placed there is loaded into
every session about every project, forever. A project's own rules and gate come from
`/harness-init` and the project itself, not from this repository.

## Git

- **Never push.** Publishing is the maintainer's decision, never an agent's.
- At the end of a unit of work: run the self-test, inspect `git diff`, report what changed with
  the verification evidence, then **propose a commit message and wait** for approval.
- Never rewrite history, force-push, or discard uncommitted work.

## Writing PowerShell here

Windows PowerShell 5.1 is the target, and it is what users run. "It works in pwsh" proves
nothing: test with `powershell.exe`.

- No `[System.IO.Path]::GetRelativePath`, `-AsHashtable`, `Join-String`, `-AsByteStream`,
  `??`, `&&`, `||`, ternary, or `` `u{} `` escapes. The self-test scans for these.
- `?` is a single-character wildcard in `-like`. Use `.StartsWith()` to test a literal prefix.
- A mandatory `[string[]]` parameter rejects empty strings. Add `[AllowEmptyString()]` when the
  array may contain blank lines.
- Preference variables do not cross a module boundary: pass `-WhatIf:$WhatIfPreference`
  explicitly when calling a module function that supports it.
- Do not redirect a native command's stderr under `$ErrorActionPreference = 'Stop'`; it wraps
  each line in a `NativeCommandError` and can throw on an expected non-zero exit.
- Mutating scripts support `-WhatIf`, back up before overwriting, and are idempotent.

## Adding a mechanism

Before adding a hook, skill, agent or MCP server, answer in the commit message or the README:
what does this make deterministic that the model currently has to remember? If the answer is
"it is available", do not add it. Record rejections and their reasons so they are not
revisited without one.
