# Changelog

## 1.3.0

### Changed

- The verification gate lists the project's files with `git ls-files`, so it no longer walks
  `node_modules`, `bin` or `obj`. On a 34,520-file checkout the fingerprint behind the Stop hook
  went from 11.6 s to 0.2 s. Outside git it walks the tree without entering those directories.
- `verify.ps1` reports the last pass instead of repeating it while the sources, the tests and the
  arguments are the same; `-Force` runs it again. The header, `git diff --check`, the recorded state
  and the banner moved into `Invoke-Verification` in `VerifyCommon.psm1`, so each `verify.ps1`
  holds only its own steps. `tazuna init` reports the new module as differing in an existing
  project; `tazuna init -Force` replaces it and keeps a backup of what it replaces.
- The .NET verifier finds solutions and projects in that same listing and lets `dotnet build`
  restore, instead of running `dotnet restore` first.
- The self-test runs its sections in four parallel processes: about 50 s instead of 250 s.

### Fixed

- `tazuna setup` pins the skills catalog at 0.17.8 through `SKILLS_CDN_REF`. The agent-skills
  CLI downloads the newest catalog otherwise, so the pinned CLI still installed whatever skills
  were current that day.
- The self-test no longer waits 120 s for its Azure DevOps stub server to stop.

## 1.2.0

### Changed

- `tazuna mcp add azure-devops` configures one project at a time. It asks for the project URL
  as the browser shows it (`http://server/Collection/Project`), splits it into collection and
  project, and checks both and the PAT against the server before anything is registered. The
  server is registered with `claude mcp add -s local`, so each project keeps its own URL and
  token, outside the repository. Running it again in the project replaces them.
- `azure-devops` is no longer written to `.mcp.json`. The `${ADO_COLLECTION_URL}` and `${ADO_PAT}`
  placeholders were expanded only from Claude Code's own process environment, which allowed one
  value per machine, and a missing variable reached the server as literal text.
- `ADO_COLLECTION_URL` and `ADO_PAT` are no longer written or read. Existing user variables are
  left in place and can be deleted.

## 1.1.1

### Changed

- The mascot is now Frenatus, a barded black Andalusian horse in tenebrist pixel art whose two
  reins leave the picture toward the harness that holds them. The seal on its chanfron lights on a
  passed verification and cracks on a failed one. It replaces Tameshi; see
  [docs/mascot.md](docs/mascot.md).
- The banner and the social preview name Claude Code and Cursor, and a lead line from the horse
  runs under the five steps.
- The README wears the mascot's palette: an epigraph opens each section, gilded dividers separate
  them, and the badges and diagrams take their colours from it.

## 1.1.0

### Added

- Cursor is supported as the agent, alongside or instead of Claude Code. `tazuna init` installs
  `.cursor/hooks.json` and turns the stack rules into `.cursor/rules/*.mdc`; the hooks take
  `-Agent cursor` and answer in Cursor's protocol, so the verification gate and the secret-commit
  block hold there too. `tazuna setup` and `tazuna doctor` work on a Cursor-only machine: skills,
  the reviewer agent, `rules/tazuna.mdc` and the user MCP servers go to the Cursor directory. See
  [docs/cursor.md](docs/cursor.md).

### Changed

- `tazuna setup` stops only when neither Claude Code nor Cursor is installed.

## 1.0.0

The first public release.

### Added

- `tazuna setup` installs or repairs a Windows machine in one command: the user-level
  instructions and permissions, [harness-toolkit](https://github.com/tech-leads-club/harness-toolkit)
  0.16.2 for the safety floor, the `tlc-*` and `harness-eval` skills from
  [agent-skills](https://github.com/tech-leads-club/agent-skills) 1.4.10, the `ponytail` plugin and
  the user MCP servers (`context7`, `playwright`, `agent-skills`), then runs `tazuna doctor`.
- `tazuna init` connects a project: `AGENTS.md`, `.claude/settings.json` with its permissions, the
  `SessionStart`, `PreToolUse` and `Stop` hooks, stack rules and `.claude/scripts/verify.ps1`, for
  a `dotnet` or a `generic` stack, and trusts the workspace in Claude Code.
- The verification gate: the `Stop` hook sends a turn that changed code back until the project's
  own `verify.ps1` passes on that code, and rejects a Verifier report that fails its validator.
- The `PreToolUse` hook blocks a `git commit` whose staged changes look like a secret.
- `tazuna mcp list` and `tazuna mcp add <name>` for project MCP servers: `azure-devops`, `serena`,
  `drawio`, `plantuml`, `mermaid`, with credentials only as `${VARIABLE}` placeholders.
- `/review-change`, independent reviewers for a completed change, one per lens.
- `tazuna doctor`, `tazuna update`, `tazuna test`, `tazuna help <command>` and `tazuna version`.
