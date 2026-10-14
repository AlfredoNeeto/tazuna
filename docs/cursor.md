# Tazuna with Cursor

Tazuna works with Cursor on a machine without Claude Code. Install it the same way:

```powershell
git clone https://github.com/AlfredoNeeto/tazuna.git "$HOME\tazuna"; & "$HOME\tazuna\bin\tazuna.cmd" setup
```

Open Cursor once before running `setup`, so `%USERPROFILE%\.cursor` exists: that directory is how
`setup`, `harness-toolkit` and `agent-skills` know Cursor is installed.

## What `setup` does for Cursor

| Piece | Where it lands |
|---|---|
| the Tech Leads Club skills: `tlc-*`, `harness-eval`, architecture, security and review | `~/.cursor/skills`, by `agent-skills -a cursor` |
| `ship`, `review-change` and `humanizer` skills, the `reviewer` agent | `~/.cursor/skills`, `~/.cursor/agents` |
| the engineering instructions (`user/CLAUDE.md`) | `~/.cursor/rules/tazuna.mdc`, a global rule applied in every project |
| the `harness-toolkit` hooks | `~/.cursor/hooks.json`, by `tlc harness install` |
| the user MCP servers (`context7`, `playwright`, `agent-skills`) | added to `~/.cursor/mcp.json`; servers already there are kept |

Claude Code steps (`~/.claude`, plugins, `claude mcp`) are skipped when `claude` is not on PATH.
With both installed, `setup` equips both.

## Projects

A project is set up as for Claude Code: `/harness-init` in Cursor, then
`tlc harness gate test-command <command>` and `tlc harness grind on` in a terminal. The toolkit
writes the project's `.cursor/hooks.json`, and its gate runs the test command when a turn that
changed code ends. A project Tazuna 1.x set up needs `tazuna init` first, which also takes
Tazuna's entries out of `.cursor/hooks.json` and removes the stack rules it wrote to
`.cursor/rules/`.

## Not available in Cursor

| Missing | Why |
|---|---|
| the `deny` and `ask` permission rules | Cursor has no settings-file permission model; the `harness-toolkit` shell floor still applies, and it stops `push --force` but not a plain `git push` |
| the `ponytail` plugin | a Claude Code plugin |
| `tazuna mcp add` | it writes `.mcp.json` for Claude Code; add a project server to `.cursor/mcp.json` by hand |
