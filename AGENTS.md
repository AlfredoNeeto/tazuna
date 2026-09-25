# Working on the harness

This repository is a Claude Code engineering harness. It is also installed into itself, so the
rules below are enforced by the same mechanisms it ships to other projects.

## Verification

```powershell
.\.claude\scripts\verify.ps1
```

This runs `scripts\test-harness.ps1`, the self-test. It prints `VERIFICATION PASSED` or
`VERIFICATION FAILED` and exits non-zero on failure.

Run it after changing anything here. A `Stop` hook refuses to end a turn that changed code
without a passing run, so this is not a reminder — it is a gate.

**A component is not implemented because a file with the right name exists.** Prove the
behaviour: run it, assert the exit code, and assert the failure case too. A test that only
checks "did not crash" would have passed the verification gate while it silently never fired.

## Where things go

| Content | Location | Loaded |
|---|---|---|
| Rules true for *most* projects | `user/` | every session, everywhere |
| Rules for one language or framework | `templates/<type>/.claude/rules/` | only when a matching file is read |
| Content every project gets | `templates/_shared/` | installed into every project |
| Harness tooling | `scripts/` | on invocation |
| Shared helpers for that tooling, one module per reason to change | `scripts/lib/` | leaf modules: no `Import-Module` inside, no `Write-Host` outside `Console.psm1`; each script must import `lib\<Area>.psm1` itself for every function it calls |

`tazuna.ps1` dispatches to a command in `scripts/`, the command orchestrates, and `scripts/lib/`
does the work. The self-test fails a script that imports a module it does not call, or calls one
it does not import.

Nothing project-specific belongs in `user/`. A rule about EF Core placed there is loaded into
every session about every project, forever.

If a file would be identical in two templates, it belongs in `templates/_shared/`. The
self-test fails if two templates ship a byte-identical file.

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
