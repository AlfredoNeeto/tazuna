# Engineering Instructions

These instructions apply across every software engineering project. They hold only what changes
behaviour; read each repository for its own conventions.

## Code

- Write the least code that solves the problem: does it need to exist, does the repository
  already do it, does the standard library or the platform do it. The ponytail plugin states
  this as an ordered ladder and is installed with this harness.
- Preserve existing behaviour unless the task requires changing it. No unrelated refactoring.

## Workflow

Scale the process to the change:

- **Small and obvious:** do it, then verify.
- **An idea not shaped yet** ("should we build this?"): `/tlc-discover`.
- **A feature:** `/tlc-spec-lean`. Stop for the user's review of the plan before any check or code;
  the independent Verifier runs after the last commit, without being asked.
- **Legacy, ambiguous requirements, or a long multi-session feature:** `/tlc-spec-driven`.
- **Work already decided elsewhere** (a work item, PRD, RFC): `/tlc-plan` cuts it into tasks,
  `/tlc-implement` builds one and has it verified.
- **Critical or high-risk** (security, money, data, public contracts): `/review-change` even
  when the change is small.
- **Uncertain shape:** plan before editing; investigate independent areas with `Explore`
  subagents so the findings come back summarized.

Your own belief that a change is correct is never the evidence: a deterministic check is, or
an independent verifier or reviewer.

## Verification

A task is not complete because code was written. It is complete when the strongest available
check passed and you observed it: build, tests, lint, type check. A change to a screen is
opened and exercised in the browser with the Playwright MCP before it is called done.
Inspect the diff for changes you did not intend. State exactly what remains unverified. Never
report a result you did not observe.

## Git Safety

- Never force-push, delete branches, or rewrite shared history unless explicitly requested.
- Never discard uncommitted user changes.
- Inspect repository state before potentially destructive Git operations.

## Security

- Never expose, print, commit, or persist secrets, credentials, tokens or private keys.
- Destructive infrastructure, database, deployment and production operations require explicit
  confirmation.

## Communication

- Respond in the language the user writes in. Keep code, identifiers, script output, commit messages, and file contents in English.
- Be concise and technical. Explain significant trade-offs.
- Distinguish verified facts from assumptions.
- Report blockers instead of silently working around important constraints.
