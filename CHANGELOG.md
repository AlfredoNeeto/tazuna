# Changelog

## 2.0.0

Tazuna now sets up the machine and leaves each project to harness-toolkit. Its own verification
gate and project templates are gone; a project's gate is harness-toolkit's `grind`, set up by
`/harness-init`.

### Removed

- The verification gate: the `Stop`, `SessionStart` and `PreToolUse` project hooks,
  `verify.ps1` with its stack detection, and `VerifyCommon.psm1`. `grind` runs the project's test
  command when a turn ends, keeps its result per session and retries up to a limit.
- The secret check before a commit and the project hook that refused `git push` behind a git
  global option. The `deny` rules still stop `git push`, but not `git -C . push`, and Cursor has
  no permission rules: there harness-toolkit stops only `push --force`.
- The `dotnet` and `generic` project templates, with their `AGENTS.md`, permissions and stack
  rules, and the workspace-trust step.
- The `fix-bug` skill. `user/CLAUDE.md` keeps its rule: a failing test first, then the root cause.

### Changed

- `tazuna init` moves a project set up by 1.x off the old gate, with a backup, then points to
  `/harness-init`. It removes `verify.ps1` and the stack rules only while they are what 1.x
  wrote; an edited `verify.ps1` is kept and its steps are printed as the gate command.
- Running the installer again updates the clone before setup, so it replaces the installed
  version. A clone with local changes or local commits is refused.
- `tazuna setup` records what it installs in `.tazuna-installed.json` and removes, on a later
  run, what a newer version no longer ships, keeping an edited copy with a warning. On a 1.x
  machine it removes `fix-bug`.
- `tazuna doctor` run inside a project warns about a 1.x gate left there and about a gate test
  command the toolkit cannot start (a `.cmd` or `.ps1`), and says whether `grind` is on.
- `harness-init` is no longer hidden. The `Edit` deny rules that guarded the old gate are gone;
  `Edit(./.claude/settings.json)` stays.
- Setup also installs modular-design-principles, evolutionary-modular-architecture,
  modular-decomposition, the-judge, coding-guidelines, security-best-practices,
  security-threat-model, create-adr and create-rfc. Pins: harness-toolkit 0.16.3, agent-skills
  1.5.0, skills catalog 0.17.9, agent-skills-mcp 0.1.7.
- `ship` verifies with the test command `tlc harness status` names for the project.
- The self-test keeps the documentation checks that guard behaviour and drops the ones that froze
  README prose and the mascot's look.

### Upgrading from 1.x

Run the installer again or `tazuna update`. In each project 1.x set up, run `tazuna init`, then
`/harness-init`, `tlc harness gate test-command <command>` and `tlc harness grind on`.

## 1.5.0

### Changed

- One `verify.ps1`, shipped from `templates/_shared`, serves every project. It finds every .NET,
  .NET Framework, Flutter, Dart, Node, Python, Go, Rust, Maven, Gradle and Make project in the
  repository, at the root or below it, and runs each one's build, analysis and tests from its own
  directory: `flutter analyze` and `flutter test`, the `typecheck`, `lint`, `build` and `test`
  scripts with npm, pnpm, yarn or bun by lockfile, MSBuild and `vstest.console` for .NET Framework.
  A workspace member and the `android/` build of a Flutter or React Native app are not verified twice.
- A step whose tool is not installed is skipped by name instead of failing the run; a run that
  skipped every step fails with `Nothing to verify`. A step that runs and fails still fails.
- Detection and the step runner moved into `VerifyCommon.psm1`, which `tazuna init` keeps up to
  date. A `verify.ps1` installed by an earlier version is the project's and is kept: delete it and
  run `tazuna init` to switch to the new one. `-Target`, `-Configuration` and `-SkipRestore` now work
  in every project and default to `Debug`, as the `dotnet` template always did.

## 1.4.0

### Added

- `scripts\build-installer.ps1` builds `tazuna-setup.exe` with the `csc.exe` of .NET Framework 4.
  It runs the embedded `install.ps1` in its own console, returns its exit code and, when
  double-clicked, waits for Enter before closing. It carries the mascot as its icon and asks for no
  administrator rights. It is not signed, so SmartScreen names an unknown publisher. CI builds it
  and keeps it as the `tazuna-setup` artifact.
- In Windows Terminal, `tazuna setup` opens with the mascot beside its title, shows a progress bar
  in each step header and ends on a summary panel. Plain output keeps its text.

## 1.3.0

### Added

- Two skills complete the kit: `/fix-bug` reproduces a bug with a failing test, fixes its root
  cause and shows the test failing before and passing after; `/ship` verifies, reads the diff,
  writes the commit message and the pull request text, and never pushes. `tazuna doctor` requires
  every skill under `user/skills`.
- A GitHub Actions workflow runs the self-test with Windows PowerShell on `windows-latest` for
  every push and pull request.

### Changed

- The verification gate lists the project's files with `git ls-files`, so it no longer walks
  `node_modules`, `bin` or `obj`. On a 34,520-file checkout the fingerprint behind the Stop hook
  went from 11.6 s to 0.2 s. A tracked file counts wherever it lives, a `build/` directory
  included; only the harness's own state is left out. Outside git it walks the tree without
  entering those directories.
- `verify.ps1` reports the last pass instead of repeating it while the sources, the tests and the
  arguments are the same; `-Force` runs it again. The header, `git diff --check`, the recorded state
  and the banner moved into `Invoke-Verification` in `VerifyCommon.psm1`, so each `verify.ps1`
  holds only its own steps.
- `tazuna init` brings Tazuna's own files, `.claude/hooks/*` and `.claude/scripts/VerifyCommon.psm1`,
  up to date in an existing project, with a backup, and without `-Force`; files the project owns
  are kept as before. It ends with exit 1 when the project's `settings.json` leaves the gate
  unwired.
- The .NET verifier finds solutions and projects in that same listing and lets `dotnet build`
  restore, instead of running `dotnet restore` first.
- The git hook starts only for a command that mentions commit, push or a git global option,
  through the Claude Code hook `if` filter; a build or a test run no longer pays ~250 ms for it.
  Claude Code 2.1.296 or later is required, the version the filter was proven on.
- `tazuna setup` merges `~/.claude/settings.json` instead of replacing it: the keys Tazuna ships
  win, the toolkit's hooks and your other keys stay, and an unchanged file is not backed up. It
  skips the toolkit install when the pinned version is already there, installs the skills for
  every agent in one call, and pins `@playwright/mcp` 0.0.83 and the Azure DevOps server 0.1.49.
- The self-test is one file per area under `scripts/tests`, each in its own process: about 30 s
  instead of 250 s.

### Fixed

- `tazuna setup` pins the skills catalog at 0.17.8 through `SKILLS_CDN_REF`. The agent-skills
  CLI downloads the newest catalog otherwise, so the pinned CLI still installed whatever skills
  were current that day.
- The self-test no longer waits 120 s for its Azure DevOps stub server to stop.
- `git -C . push` went through the rule that denies `git push`, and `git -C . commit` skipped the
  one that asks. The project hook now refuses `git push` however git is called (`GIT`, `git.exe`,
  a full path), and behind any git global option it refuses a push or a denied destructive command
  in that call, and asks for a commit. It reads the command text, so it guards against
  mistakes, not against deliberate obfuscation such as aliases or variables.
- The secret check ran before `git add . && git commit` had staged anything, so it saw nothing.
  It now reads the working tree too when the same command stages it.
- After the agent changed directory, the Stop gate looked for `verify.ps1` there and let the turn
  end. The hooks now judge the session's project, `CLAUDE_PROJECT_DIR`.
- A plugin that failed to install no longer lets `tazuna setup` end as done.

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
