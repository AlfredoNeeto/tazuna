# Changelog

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
